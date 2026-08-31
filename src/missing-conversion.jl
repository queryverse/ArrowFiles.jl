struct MissingDataValueVector{J,T<:AbstractVector{DataValue{J}}} <: AbstractVector{Union{J,Missing}}
    data::T
end

Base.size(A::MissingDataValueVector) = size(A.data)

@inline function Base.getindex(A::MissingDataValueVector, i)
    @inbounds o = isna(A.data[i]) ? missing : get(A.data[i])
    o
end

Base.IndexStyle(::Type{<:MissingDataValueVector}) = IndexLinear()

Base.eltype(::Type{MissingDataValueVector{J,T}}) where {J,T} = Union{J,Missing}
