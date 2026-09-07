module ArrowFiles

using Arrow, Tables, IteratorInterfaceExtensions, TableTraits, TableTraitsUtils,
    DataValues, FileIO, TableShowUtils
import IterableTables

export load, save, File, @format_str

include("missing-conversion.jl")

struct ArrowFile
    filename::String
end

function Base.show(io::IO, source::ArrowFile)
    TableShowUtils.printtable(io, getiterator(source), "Arrow file")
end

function Base.show(io::IO, ::MIME"text/html", source::ArrowFile)
    TableShowUtils.printHTMLtable(io, getiterator(source))
end

Base.showable(::MIME"text/html", source::ArrowFile) = true

function Base.show(io::IO, ::MIME"application/vnd.dataresource+json", source::ArrowFile)
    TableShowUtils.printdataresource(io, getiterator(source))
end

Base.showable(::MIME"application/vnd.dataresource+json", source::ArrowFile) = true

function fileio_load(f::FileIO.File{FileIO.format"Arrow"})
    return ArrowFile(f.filename)
end

IteratorInterfaceExtensions.isiterable(x::ArrowFile) = true
TableTraits.isiterabletable(x::ArrowFile) = true
TableTraits.supports_get_columns_copy_using_missing(x::ArrowFile) = true
TableTraits.supports_get_columns_view(x::ArrowFile) = true

# Tables.jl interface, delegated to Arrow.Table. Its columns are views into the
# memory-mapped file, so `Tables.columns` is O(1) and never copies; `Tables.rows` then
# comes from Tables.jl's RowIterator over those columns, and `Tables.partitions` yields
# one table per record batch. Arrow.jl wraps the result in `Tables.CopiedColumns`, so
# sinks like DataFrames take the (immutable) columns as-is; pass `copycols=true` there
# to materialize mutable Vectors.
Tables.istable(::Type{ArrowFile}) = true
Tables.columnaccess(::Type{ArrowFile}) = true
Tables.columns(file::ArrowFile) = Tables.columns(Arrow.Table(file.filename))
Tables.schema(file::ArrowFile) = Tables.schema(Arrow.Table(file.filename))
Tables.partitions(file::ArrowFile) = Tables.partitions(Arrow.Table(file.filename))

# Arrow.jl already hands back columns whose eltype is `Union{T,Missing}`, so unlike the
# Feather V1 path there is nothing to wrap on the way in.
function _readcolumns(filename::AbstractString)
    t = Arrow.Table(filename)
    names = collect(Symbol, Tables.columnnames(t))
    columns = Any[Tables.getcolumn(t, n) for n in names]
    return columns, names
end

# The TableTraits view trait: the same Arrow-backed columns, not copied. Callers must
# treat them as read-only; they alias the mapped file.
function TableTraits.get_columns_view(file::ArrowFile)
    columns, names = _readcolumns(file.filename)
    return NamedTuple{(names...,)}((columns...,))
end

function IteratorInterfaceExtensions.getiterator(file::ArrowFile)
    columns, names = _readcolumns(file.filename)
    return create_tableiterator(columns, names)
end

function TableTraits.get_columns_copy_using_missing(file::ArrowFile)
    columns, names = _readcolumns(file.filename)
    return NamedTuple{(names...,)}(((convert(Vector{eltype(c)}, c) for c in columns)...,))
end

function fileio_save(f::FileIO.File{FileIO.format"Arrow"}, data)
    isiterabletable(data) || error("Can't write this data to an Arrow file.")

    columns, colnames = create_columns_from_iterabletable(data)

    columns = Any[c for c in columns]

    # Sources that came through Query.jl hand us DataValue columns; Arrow.jl speaks
    # Missing, so unwrap them the same way FeatherFiles does.
    for i in 1:length(columns)
        if eltype(columns[i]) <: DataValue
            T = MissingDataValueVector{eltype(eltype(columns[i])),typeof(columns[i])}
            columns[i] = T(columns[i])
        end
    end

    Arrow.write(f.filename, NamedTuple{(Symbol.(colnames)...,)}((columns...,)))
end

end # module
