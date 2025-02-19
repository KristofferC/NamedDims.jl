# This supports nonbroadcasting math on NamedDimArrays

################################################
# Matrix product

valid_matmul_dims(a::Tuple{Symbol}, b::Tuple{Vararg{Symbol}}) = true
function valid_matmul_dims(a::Tuple{Symbol,Symbol}, b::Tuple{Vararg{Symbol}})
    a_dim = a[end]
    b_dim = b[1]

    return a_dim === b_dim || a_dim === :_ || b_dim === :_
end

matmul_names((a1, a2)::Tuple{Symbol,Symbol}, (b,)::Tuple{Symbol}) = (a1,)
matmul_names((a1, a2)::Tuple{Symbol,Symbol}, (b1, b2)::Tuple{Symbol,Symbol}) = (a1, b2)
matmul_names((a1,)::Tuple{Symbol}, (b1, b2)::Tuple{Symbol,Symbol}) = (a1, b2)

function throw_matrix_dim_error(a, b)
    msg = "Cannot take matrix product of arrays with different inner dimension names. $a vs $b"
    return throw(DimensionMismatch(msg))
end

function matrix_prod_names(a, b)
    # 0 Allocations. See `@btime (()-> matrix_prod_names((:foo, :bar),(:bar,)))()`
    valid_matmul_dims(a, b) || throw_matrix_dim_error(a, b)
    res = matmul_names(a, b)
    return compile_time_return_hack(res)
end

for (NA, NB) in ((1, 2), (2, 1), (2, 2))  #Vector * Vector, is not allowed
    @eval function Base.:*(
        a::NamedDimsArray{A,T,$NA}, b::NamedDimsArray{B,S,$NB},
    ) where {A,B,T,S}
        L = matrix_prod_names(A, B)
        data = *(parent(a), parent(b))
        return NamedDimsArray{L}(data)
    end
end

# vector^T * vector
function Base.:*(
    a::NamedDimsArray{A,T,2,<:CoVector}, b::NamedDimsArray{B,S,1},
) where {A,B,T,S}
    valid_matmul_dims(A, B) || throw_matrix_dim_error(last(A), first(B))
    return *(parent(a), parent(b))
end

function Base.:*(a::NamedDimsArray{L,T,2,<:CoVector}, b::AbstractVector) where {L,T}
    return *(parent(a), b)
end

# Using `CoVector` results in Method ambiguities; have to define more specific methods.
for A in (
    Adjoint{<:Number,<:AbstractVector},
    Transpose{<:Real,<:AbstractVector{<:Real}},
    Transpose{<:Any, <:AbstractMatrix{T}} where T,  # resolves ambiguity error in AxisKeys
)
    @eval function Base.:*(a::$A, b::NamedDimsArray{L,T,1,<:AbstractVector{T}}) where {L,T}
        return *(a, parent(b))
    end
    @eval function Base.:*(a::NamedDimsArray{L,T,1,<:AbstractVector{T}}, b::$A) where {L,T}
        return *(parent(a), b)
    end
end

"""
    @declare_matmul(MatrixT, VectorT=nothing)

This macro helps define matrix multiplication for the types
with 2D type parameterization `MatrixT` and 1D `VectorT`.
It defines the various overloads for `Base.:*` that are required.
It should be used at the top level of a module.
"""
macro declare_matmul(MatrixT, VectorT=nothing)
    dim_combos = VectorT === nothing ? ((2, 2),) : ((1, 2), (2, 1), (2, 2))
    codes = map(dim_combos) do (NA, NB)
        TA_named = :(NamedDims.NamedDimsArray{<:Any,<:Any,$NA})
        TB_named = :(NamedDims.NamedDimsArray{<:Any,<:Any,$NB})
        TA_other = (VectorT, MatrixT)[NA]
        TB_other = (VectorT, MatrixT)[NB]

        quote
            function Base.:*(a::$TA_named, b::$TB_other)
                return *(a, NamedDims.NamedDimsArray{dimnames(b)}(b))
            end
            function Base.:*(a::$TA_other, b::$TB_named)
                return *(NamedDims.NamedDimsArray{dimnames(a)}(a), b)
            end
        end
    end
    return esc(Expr(:block, codes...))
end

# The following two methods can be defined by using
# @declare_matmul(Diagonal, AbstractVector)
# but that overwrites existing *(1D NDA, Vector) methods
# should improve the macro above to deal with this case
function Base.:*(a::Diagonal, b::NamedDimsArray{<:Any,<:Any,1})
    return *(NamedDimsArray{dimnames(a)}(a), b)
end

function Base.:*(a::NamedDimsArray{<:Any,<:Any,1}, b::Diagonal)
    return *(a, NamedDimsArray{dimnames(b)}(b))
end

@declare_matmul(AbstractMatrix, AbstractVector)
@declare_matmul(
    Adjoint{<:Any,<:AbstractMatrix{T1}} where {T1}, Adjoint{<:Any,<:AbstractVector}
)
@declare_matmul(Diagonal,)

################################################
# Others

function Base.inv(nda::NamedDimsArray{L,T,2}) where {L,T}
    data = inv(parent(nda))
    names = reverse(L)
    return NamedDimsArray{names}(data)
end

# Statistics
for fun in (:cor, :cov)
    @eval function Statistics.$fun(a::NamedDimsArray{L,T,2}; dims=1, kwargs...) where {L,T}
        numerical_dims = dim(a, dims)
        data = Statistics.$fun(parent(a); dims=numerical_dims, kwargs...)
        names = symmetric_names(L, numerical_dims)
        return NamedDimsArray{names}(data)
    end
end

# CovarianceEstimation
for E in (:LinearShrinkage, :SimpleCovariance, :AnalyticalNonlinearShrinkage)
    @eval function CovarianceEstimation.cov(
        estimator::$E, a::NamedDimsArray{L,T,2}; dims=1, kwargs...
    ) where {L,T}
        numerical_dims = dim(a, dims)
        # cov returns a Symmetric matrix which needs to be rewrapped in a NamedDimsArray
        data = cov(estimator, parent(a); dims=numerical_dims, kwargs...)
        names = symmetric_names(L, numerical_dims)
        return NamedDimsArray{names}(data)
    end
end

function symmetric_names(L::Tuple{Symbol,Symbol}, dims::Integer)
    # 0 Allocations. See `@btime (()-> symmetric_names((:foo, :bar), 1))()`
    names = if dims == 1
        (L[2], L[2])
    elseif dims == 2
        (L[1], L[1])
    else
        (:_, :_)
    end
    return compile_time_return_hack(names)
end
