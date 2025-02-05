#################### TYPES ####################

using LinearAlgebra

wraps(AT) = [
    :( Diagonal{T,$AT} ),
    :( Transpose{T,$AT} ),
    # :( Adjoint{<:Any,$AT} ),
    :( PermutedDimsArray{T,<:Any,<:Any,<:Any,$AT} ),

    # :( TransmutedDimsArray{T,<:Any,<:Any,<:Any,$AT} ),

    # :( Stacked{T,<:Any,$AT} ),
    # :( Stacked{T,<:Any,<:AbstractArray{$AT}} ),
]

@eval NamedUnion{T} = Union{NamedDimsArray{<:Any,T}, $(wraps(:(<:NamedDimsArray))...),}

#################### RECURSIVE UNWRAPPING ####################

using LinearAlgebra
using TransmuteDims: TransmutedDimsArray

names_doc = """
    names(A::NamedDimsArray) -> Tuple
    names(A, d) -> Symbol

`Base.names` acts as the accessor function.

    hasnames(A)
    getnames(A)
    getnames(A, d)

These work recursively through wrappers.

For any wrapper type which changes the order / number of dimensions,
you will need to define `NamedPlus.outmap(x, names) = outernames`.
"""

# @doc names_doc
# Base.names(x::NamedUnion) = getnames(x)
# Base.names(x::NamedUnion, d::Int) = getnames(x, d)

@doc names_doc
hasnames(x::NamedDimsArray) = true
hasnames(x::AbstractArray) = x === parent(x) ? false : hasnames(parent(x))

@doc names_doc
getnames(x::AbstractArray) = x === parent(x) ? default_names(x) : outmap(x, getnames(parent(x)), :_)
getnames(x::NamedDimsArray{names}) where {names} = names
getnames(x, d::Int) = d <= ndims(x) ? getnames(x)[d] : :_

default_names(x::AbstractArray) = ntuple(_ -> :_, ndims(x))

"""
    outmap(A, tuple, default)

Maps the names/ranges tuple from `parent(A)` to that for `A`.
"""
outmap(A, tup, z) = tup

outmap(::Transpose, x::Tuple{Any}, z) = (z, x...)
outmap(::Transpose, x::Tuple{Any,Any}, z) = reverse(x)

outmap(::Adjoint, x::Tuple{Any}, z) = (z, x...)
outmap(::Adjoint, x::Tuple{Any,Any}, z) = reverse(x)

outmap(::Diagonal, x::Tuple{Any}, z) = (x..., x...)

outmap(::PermutedDimsArray{T,N,P,Q}, x::Tuple, z) where {T,N,P,Q} =
    ntuple(d -> x[P[d]], N)

outmap(::TransmutedDimsArray{T,N,P,Q}, x::Tuple, z) where {T,N,P,Q} =
    ntuple(d -> P[d]==0 ? z : x[P[d]], N)

outmap(::SubArray, x) = (@warn "outmap may behave badly with views!"; x)

"""
    nameless(x)

An attempt at a recursive `unname()` function.
Needs `Base.parent` and `NamedPlus.rewraplike` to work on each wrapper.
"""
nameless(x::NamedDimsArray) = parent(x)
nameless(x) = x
function nameless(x::AbstractArray)
    hasnames(x) || return x
    x === parent(x) ? x : rewraplike(x, parent(x), nameless(parent(x)))
end


"""
    rewraplike(x, y, z)
    rewraplike(x, parent(x), nameless(parent(x)))

This looks at the type of `x`, replaces the type of `y` with that of `z`,
and then uses that to act on `z`. Hopefully that's the right constructor!
For troublesome wrapper types you may need to overload this.

In fact this won't work at all for any type not visible from inside this module.
Damn. Is there a way around that? `@nameless`?
"""
@generated function rewraplike(x::AT, y::PT, z::UT) where {AT <: AbstractArray{T,N}, PT, UT} where {T,N}
    FT = Meta.parse(replace(string(AT), string(PT) => string(UT)))
    :( $FT(z) )
end

rewraplike(x::SubArray, y, z) = SubArray(z, x.indices, x.offset1, x.stride1) # untested!

####################
