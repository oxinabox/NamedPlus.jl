
#################### VEC ####################

function Base.vec(A::NamedUnion)
    ndims(A) == 1 && return A
    ndims(A) >= 3 && return vec(nameless(A))
    NamedDimsArray(vec(nameless(A)), _join(getnames(A)...))
end

Base.reshape(A::NamedDimsArray, ::Colon) = vec(A)

#################### KRON ####################

function Base.kron(A::NamedUnion, B::NamedUnion)
    data = kron(nameless(A), nameless(B))
    newL = map(_join, getnames(A), getnames(B))
    NamedDimsArray(data, newL)
end

#################### DROPDIMS ####################

"""
    dropdims(A) = dropdims(A; dims = :_)

If no `dims` are specified, dropdims will drop all dimensions with name `:_`,
and will give an error if any of these are not of length 1.
If there are no dimensions of this name, it will do nothing.

```
julia> A = align(ones(b=2, d=4), (:a, :b, :c, :d));

julia> names(A)
(:_, :b, :_, :d)

julia> size(A)
(1, 2, 1, 4)

julia> names(dropdims(A))
(:b, :d)

julia> size(dropdims(A))
(2, 4)

julia> dropdims(dropdims(A)) === dropdims(A)
true
```
"""
Base.dropdims

for N=1:10
    # More specific than the defn in NamedDims
    @eval Base.dropdims(A::NamedDimsArray{L,T,$N}; dims = :_) where {L,T} =
        named_dropdims(A, dims)
end

function named_dropdims(A, dims)
    if dims === :_ || dims === (:_,)
        L = getnames(A)
        maybe = ntuple(d -> L[d] === :_ ? d : nothing, ndims(A))
        named_dropdims(A, filter(d -> d isa Int, maybe))
    else
        num_dims = NamedDims.dim(A, dims)
        named_dropdims(A, num_dims)
    end
end

named_dropdims(A, ::Tuple{}) = A # since filter may give empty set

function named_dropdims(A, dims::Tuple{Vararg{Int}})
    data = dropdims(nameless(A); dims=dims)
    newL = NamedDims.remaining_dimnames_after_dropping(getnames(A), dims)
    NamedDimsArray(data, newL)
end

# function Base.dropdims(nda::NamedDimsArray; dims)
#     numerical_dims = dim(nda, dims)
#     data = dropdims(parent(nda); dims=numerical_dims)
#     L = remaining_dimnames_after_dropping(names(nda), numerical_dims)
#     return NamedDimsArray{L}(data)
# end

#=
# dropdims is slow!

using NamedDims
nda = NamedDimsArray(zeros(Float32, 4,1,4), (:a, :_, :c))
@btime (() -> dropdims($(parent(nda)), dims=2))() # 523.921 ns (9 allocations: 224 bytes)

@btime NamedDims.remaining_dimnames_after_dropping((:a, :b, :c), 2) # 1.420 ns

@btime (() -> dropdims($(nda), dims=2))() # 7.441 μs (18 allocations: 672 bytes)
@btime (() -> dropdims($(nda), dims=:_))() # 7.469 μs (18 allocations: 672 bytes)

@code_warntype (x -> dropdims(x, dims=:_))(nda)

using NamedPlus
@btime (() -> dropdims($(nda), dims=2))() # 7.518 μs (18 allocations: 672 bytes)
@btime (() -> dropdims($(nda)))()         # 7.902 μs (20 allocations: 704 bytes)

@code_warntype (x -> NamedPlus.named_dropdims(x, (:_,)))(nda)

# selectdim is not:

@btime (() -> selectdim(nda, 1, 2))()  #  248.238 ns (5 allocations: 144 bytes)
@btime (() -> selectdim(nda, :a, 2))() #  244.107 ns (5 allocations: 144 bytes)
=#

function Base._dropdims(A::Transpose{<:Number, <:AbstractVector}, dims::Tuple{Int})
    dims[1] === 1 && return parent(A)
    invoke(Base._dropdims, Tuple{AbstractArray, Tuple{Vararg{Int64}}}, A, dims)
end

function Base._dropdims(A::Adjoint{<:Real, <:AbstractVector}, dims::Tuple{Int})
    dims[1] === 1 && return parent(A)
    invoke(Base._dropdims, Tuple{AbstractArray, Tuple{Vararg{Int64}}}, A, dims)
end

#################### SPLIT / COMBINE ####################

"""
    join(A, (:i, :j) => :iᵡj)
    join(A, :i, :j) # => :iᵡj by default

This replaces two dimensions `i, j` with a combined one `iᵡj`.

If the dimensions are adjacent and in the correct order
(and `A` is not a lazy `Transpose` etc) then this will be done by reshaping.
But if the dimensions aren't adjacent, or are in the wrong order,
then it needs to call `permutedims` first, which will copy `A`.

See `split(A, :iᵡj => (i=3, j=4))` for the reverse operation.
"""
Base.join(A::NamedUnion, i::Symbol, j::Symbol) = join(A, (i,j) => _join(i,j))
Base.join(A::NamedUnion, ij::Tuple) = join(A, ij...)

function Base.join(A::NamedUnion, p::Pair{<:Tuple,Symbol})
    d1, d2 = NamedDims.dim(A, p.first)

    if d2 == d1+1 && nameless(A) isa StridedArray
        sz = ntuple(ndims(A)-1) do d
            d < min(d1,d2) ? size(A,d) :
            d==min(d1,d2) ? size(A,d1) * size(A,d2) :
            size(A, d+1)
        end
        nm = ntuple(ndims(A)-1) do d
            d < min(d1,d2) ? getnames(A,d) :
            d==min(d1,d2) ? p.second :
            getnames(A, d+1)
        end
        @debug "NamedPlus join is easy as d1=$d1 is one less than d2=$d2" getnames(A) p
        # ENV["JULIA_DEBUG"] = "all" # turns these on
        return NamedDimsArray{nm}(reshape(nameless(A), nameless.(sz))) # remove NamedInt!

    elseif d2 == d1 + 1
        @debug "NamedPlus join is copying as A not a StridedArray" typeof(A) p
        return join(copy(A), p)

    elseif d1 < d2
        # 1 2 3* 4 5 6** 7 8
        # 1 2 4 5 3* 6** 7 8
        perm = ntuple(ndims(A)) do d
            d < d1 ? d :
            d < d2-1 ? d+1 :
            d == d2-1 ? d1 :
            d == d2 ? d2 :
            d
        end
        @debug "NamedPlus join needs permutedims, d1=$d1 < d2=$d2" getnames(A) perm p
        return join(permutedims(A, perm), p)
    elseif d1 > d2
        # 1 2 3** 4 5 6* 7 8
        # 1 2 4 5 6* 3** 7 8
        perm = ntuple(ndims(A)) do d
            d < d2 ? d :
            d < d1-1 ? d+1 :
            d == d1-1 ? d1 :
            d == d1 ? d2 :
            d
        end
        @debug "NamedPlus join needs permutedims, d1=$d1 > d2=$d2" getnames(A) perm p
        return join(permutedims(A, perm), p)
    end
    error("this shouldn't happen!")
end

# @btime (() -> _join(:i, :j))() # 0 allocations
_join(i::Symbol, j::Symbol) = _join(Val(i), Val(j))
@generated _join(::Val{i}, ::Val{j}) where {i,j} = QuoteNode(Symbol(i, :ᵡ, j))

# @btime (() -> _split(Symbol("iᵡj")))()  # 0 allocations, but 4 μs!
# @btime (() -> _split($(QuoteNode(Symbol("iᵡj")))))()  # 0 allocations, but 4 μs!
# @btime (() -> _split(_join(:i, :j)))()  # 0 allocations, 1.4 ns
_split(ij::Symbol) = _split(Val(ij))
@generated _split(::Val{ij}) where {ij} = Tuple(map(QuoteNode∘Symbol, split(string(ij), '_')))

"""
    split(A, :iᵡj => (i=2, j=3))
    split(A, :iᵡj => (:i, :j), (2,3))

This replaces the dimension named `iᵡj` with separate `i, j` by reshaping.
The final size of the two new dimension should be given afterwards;
you may write `(2,:)` etc.

    split(A, :iᵡj => (:i, :j), B)

The final sizes can also be read from another `B::NamedDimsArray` with names `i, j`.

See `join(A, (:i, :j) => :iᵡj)` for the opposite operation.
"""
Base.split(A::NamedUnion, pair::Pair{Symbol,<:NamedTuple}) =
    split(A, pair.first => keys(pair.second), Tuple(pair.second))

function Base.split(A::NamedUnion, pair::Pair{Symbol,<:Tuple}, sizes::Tuple)
    d0 = NamedDims.dim(A, pair.first)
    sz = ntuple(ndims(A)+1) do d
        d < d0 ? size(A,d) :
        d==d0 ? sizes[1] :
        d==d0+1 ? sizes[2] :
        size(A, d-1)
    end
    nm = ntuple(ndims(A)+1) do d
        d < d0 ? getnames(A,d) :
        d==d0 ? pair.second[1] :
        d==d0+1 ? pair.second[2] :
        getnames(A, d-1)
    end
    NamedDimsArray{nm}(reshape(nameless(A), nameless.(sz)))
end

Base.split(A::NamedUnion, s::Symbol, sizes::Union{Tuple, NamedUnion}) =
    split(A, s => _split(s), sizes)

Base.split(A::NamedUnion, pair::Pair{Symbol,<:Tuple}, B::NamedUnion) =
    split(A, pair, NamedDims.dim(B, pair.second))


#=
ABC = NamedDimsArray(rand(1:10, 2,3,4), (:a,:b,:c))

@btime (ABC -> join(ABC, :a, :b))($ABC)        # 9 μs
@code_warntype (ABC -> join(ABC, :a, :b))(ABC) # ::Any

@btime (ABC -> split(ABC, :c => (:c1, :c2), (2,2)))($ABC)        # 650 ns
@code_warntype (ABC -> split(ABC, :c => (:c1, :c2), (2,2)))(ABC) # ::NamedDimsArray{_A,Int64,_B,_C}
=#

####################
