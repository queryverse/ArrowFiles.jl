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

@testitem "Missing Conversion" begin
    using DataValues

    v = ArrowFiles.MissingDataValueVector([DataValue{Int64}(), DataValue{Int64}(18), DataValue{Int64}(54)])
    @test getindex(v, 2) == 18
    @test getindex(v, 1) === missing
    @test size(v) == size(v.data)
    @test IndexStyle(v) == IndexLinear()
    @test eltype(v) == Union{Int64,Missing}
end
