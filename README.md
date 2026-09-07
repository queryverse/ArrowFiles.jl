# ArrowFiles

## Overview

This package provides load and save support for [Arrow IPC files](https://arrow.apache.org/docs/format/Columnar.html#ipc-file-format) under the [FileIO.jl](https://github.com/JuliaIO/FileIO.jl) package, built on [Arrow.jl](https://github.com/apache/arrow-julia).

The Arrow IPC file format is also known as **Feather V2**. The two names describe exactly the same bytes — Apache's own documentation says V2 "is exactly represented as the Arrow IPC file format on disk" — so this package reads and writes files with either a `.arrow` or a `.feather` extension, as long as their contents are V2. Files carry `ARROW1` magic bytes, so FileIO identifies them by content rather than by name.

The older **Feather V1** format (`FEA1` magic) is a different, pre-Arrow format that this package does not handle. Apache deprecated reading and writing V1 as of Arrow 25.0.0 and plans to remove it. Use [FeatherFiles.jl](https://github.com/queryverse/FeatherFiles.jl) for V1 archives.

## Usage

### Load an Arrow file

```julia
using ArrowFiles, DataFrames

df = DataFrame(load("data.arrow"))
```

`load` returns a struct that implements the [Tables.jl](https://github.com/JuliaData/Tables.jl) interface and is also an [IterableTable](https://github.com/queryverse/IterableTables.jl), so it can be passed to any Tables.jl or IterableTables sink.

The Tables.jl path is zero-copy: `Tables.columns`, `Tables.rows`, `Tables.schema` and `Tables.partitions` (one per record batch) delegate to `Arrow.Table`, whose columns are views into the memory-mapped file. Those columns are immutable, and sinks like DataFrames take them as they are, exactly as `DataFrame(Arrow.Table("data.arrow"))` does. To get ordinary mutable `Vector` columns, ask the sink for a copy:

```julia
df = DataFrame(load("data.arrow"); copycols=true)
```

### Save an Arrow file

```julia
using ArrowFiles, DataFrames

df = DataFrame(Name=["John", "Sally"], Age=[34., 54.])
save("data.arrow", df)
```

Any iterable table can be saved this way.

## Status

Not registered. FileIO's built-in registry currently maps `format"Arrow"` to Arrow.jl, which ships no FileIO hooks, so `load`/`save` on an Arrow file fail out of the box. Until that registry entry is repointed at this package, register it yourself:

```julia
using FileIO, UUIDs
const ARROWFILES = :ArrowFiles => UUID("9fdbc45d-1104-46a9-9fdf-bf01235b14c1")
FileIO.add_loader(format"Arrow", ARROWFILES)
FileIO.add_saver(format"Arrow", ARROWFILES)
```

Note that `add_loader` appends, so FileIO tries Arrow.jl first and logs `neither load nor fileio_load is defined ... Will try next loader` before reaching this package. That warning is expected and goes away once the registry is updated.
