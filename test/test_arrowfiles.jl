# FileIO's built-in registry maps format"Arrow" to Arrow.jl, which ships no FileIO
# hooks, so `load`/`save` on an Arrow file fail out of the box. Until the registry
# entry is repointed at ArrowFiles upstream, register ourselves at runtime. Note that
# add_loader appends, so FileIO tries Arrow.jl first and logs "neither load nor
# fileio_load is defined ... Will try next loader" before reaching us; that warning is
# expected here and is exactly the gap the registry change closes.
@testsnippet RegisterWithFileIO begin
    using FileIO, UUIDs
    let af = :ArrowFiles => UUID("9fdbc45d-1104-46a9-9fdf-bf01235b14c1")
        FileIO.add_loader(format"Arrow", af)
        FileIO.add_saver(format"Arrow", af)
    end
end

@testitem "ArrowFiles" setup=[RegisterWithFileIO] begin
    using DataValues
    using IteratorInterfaceExtensions
    using TableTraits
    using QueryTables
    using FileIO

    source = [(Name="John", Age=34., Children=2),
        (Name="Sally", Age=54., Children=1),
        (Name="Jim", Age=34., Children=0)]

    output_filename = tempname() * ".arrow"
    save(output_filename, source)

    af = load(output_filename)

    @test af isa ArrowFiles.ArrowFile
    @test IteratorInterfaceExtensions.isiterable(af) == true
    @test TableTraits.isiterabletable(af) == true

    it = IteratorInterfaceExtensions.getiterator(af)
    @test collect(it) == source

    cols = TableTraits.get_columns_copy_using_missing(af)
    @test cols.Name == ["John", "Sally", "Jim"]
    @test cols.Age == [34., 54., 34.]
    @test cols.Children == [2, 1, 0]

    df = DataTable(af)
    @test length(df) == 3
    @test df.Name == ["John", "Sally", "Jim"]
    @test df.Children == [2, 1, 0]
end

@testitem "Missing values" setup=[RegisterWithFileIO] begin
    using DataValues
    using FileIO
    using IteratorInterfaceExtensions

    # Every field of a column has to be a DataValue for TableTraitsUtils to build a
    # nullable column out of the row iterator.
    source = [(a=DataValue(1), b=DataValue("x")),
        (a=DataValue(2), b=DataValue{String}()),
        (a=DataValue{Int}(), b=DataValue("z"))]

    output_filename = tempname() * ".arrow"
    save(output_filename, source)

    # Arrow.jl reads nulls back as `missing`, but create_tableiterator re-wraps
    # nullable columns as DataValue, which is the Queryverse convention and what
    # FeatherFiles and CSVFiles also yield. So the round-trip is exact.
    rt = collect(IteratorInterfaceExtensions.getiterator(load(output_filename)))

    @test length(rt) == 3
    @test rt == source
end

@testitem "Format detection" setup=[RegisterWithFileIO] begin
    using FileIO
    using Arrow
    using IteratorInterfaceExtensions

    # A V2 file named .feather is still the Arrow IPC file format, and FileIO
    # identifies it by its ARROW1 magic rather than by its extension.
    for ext in (".arrow", ".feather")
        f = tempname() * ext
        Arrow.write(f, (a=[1, 2, 3], b=["x", "y", "z"]))
        @test read(open(f), 6) == Vector{UInt8}("ARROW1")
        @test FileIO.query(f) isa FileIO.File{FileIO.format"Arrow"}

        tbl = load(f)
        @test tbl isa ArrowFiles.ArrowFile
        rows = collect(IteratorInterfaceExtensions.getiterator(tbl))
        @test [r.a for r in rows] == [1, 2, 3]
        @test [r.b for r in rows] == ["x", "y", "z"]
    end
end

@testitem "Display" setup=[RegisterWithFileIO] begin
    using DataValues
    using FileIO

    source = [(a=DataValue(1), b=DataValue(3)),
        (a=DataValue(2), b=DataValue(4)),
        (a=DataValue{Int}(), b=DataValue(5))]

    filename = tempname() * ".arrow"
    save(filename, source)
    af = load(filename)

    @test sprint(show, af) == "3x2 Arrow file
a   │ b
────┼──
1   │ 3
2   │ 4
#NA │ 5"

    @test showable(MIME"text/html"(), af)
    @test occursin("<table>", sprint(io -> show(io, MIME"text/html"(), af)))

    @test showable(MIME"application/vnd.dataresource+json"(), af)
    @test occursin("\"schema\"", sprint(io -> show(io, MIME"application/vnd.dataresource+json"(), af)))
end

@testitem "Tables.jl interface" setup=[RegisterWithFileIO] begin
    using Arrow
    using Tables
    using TableTraits
    using FileIO

    t1 = (a=[1, 2, 3], b=["x", "y", "z"], c=[1.5, missing, 3.5])
    t2 = (a=[4, 5], b=["u", "v"], c=[missing, 5.5])

    # One file with a single record batch, one with two.
    single = tempname() * ".arrow"
    Arrow.write(single, t1)
    multi = tempname() * ".arrow"
    Arrow.write(multi, Tables.partitioner((t1, t2)))

    @test Tables.istable(ArrowFiles.ArrowFile)
    @test Tables.columnaccess(ArrowFiles.ArrowFile)

    af = load(single)
    @test Tables.istable(af)

    # Columns are Arrow's own views into the mapped file, not copies.
    cols = Tables.columns(af)
    @test cols isa Tables.CopiedColumns
    @test collect(Tables.columnnames(cols)) == [:a, :b, :c]
    for n in Tables.columnnames(cols)
        @test Tables.getcolumn(cols, n) isa Arrow.ArrowVector
    end
    @test Tables.getcolumn(cols, :a) == [1, 2, 3]
    @test isequal(Tables.getcolumn(cols, :c), [1.5, missing, 3.5])

    sch = Tables.schema(af)
    @test collect(sch.names) == [:a, :b, :c]
    @test collect(sch.types) == [Int64, String, Union{Missing,Float64}]

    # Rows come from Tables.jl's RowIterator over the Arrow columns: no DataValue.
    rows = Tables.rows(af)
    @test eltype(rows) <: Tables.ColumnsRow
    r = collect(rows)
    @test length(r) == 3
    @test [x.a for x in r] == [1, 2, 3]
    @test [x.b for x in r] == ["x", "y", "z"]
    @test r[1].c == 1.5
    @test r[2].c === missing

    ct = Tables.columntable(af)
    @test ct.a == [1, 2, 3]
    @test ct.a isa Arrow.ArrowVector

    # Arrow.TablePartitions iterates but defines neither length nor IteratorSize,
    # so gather partitions by iteration rather than collect.
    gatherpartitions(x) = (ps = Any[]; for p in Tables.partitions(x); push!(ps, p); end; ps)
    @test length(gatherpartitions(af)) == 1

    # The TableTraits view trait hands out the same uncopied columns.
    @test TableTraits.supports_get_columns_view(af)
    v = TableTraits.get_columns_view(af)
    @test v isa NamedTuple
    @test keys(v) == (:a, :b, :c)
    @test v.a isa Arrow.ArrowVector
    @test eltype(v.c) == Union{Missing,Float64}

    # The copy trait still materializes owned Vectors for Queryverse sinks.
    cp = TableTraits.get_columns_copy_using_missing(af)
    @test cp.a isa Vector{Int64}
    @test cp.c isa Vector{Union{Missing,Float64}}

    # Multiple record batches show up as Tables.jl partitions.
    mf = load(multi)
    parts = gatherpartitions(mf)
    @test length(parts) == 2
    @test parts[1].a == [1, 2, 3]
    @test parts[2].a == [4, 5]
    @test Tables.columntable(mf).a == [1, 2, 3, 4, 5]
    @test [x.b for x in Tables.rows(mf)] == ["x", "y", "z", "u", "v"]
end

@testitem "Missing Conversion" begin
    using DataValues

    v = ArrowFiles.MissingDataValueVector([DataValue{Int64}(), DataValue{Int64}(18), DataValue{Int64}(54)])
    @test getindex(v, 2) == 18
    @test getindex(v, 1) === missing
    @test size(v) == size(v.data)
    @test IndexStyle(v) == IndexLinear()
    @test eltype(v) == Union{Int64,Missing}
end
