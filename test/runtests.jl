using NamedDims
using BenchmarkTools
using Test

const testfiles = (
    "name_core.jl",
    "wrapper_array.jl",
    "name_operations.jl",
    "functions.jl",
    "functions_dims.jl",
    "functions_math.jl",
    "broadcasting.jl",
    "tracker_compat.jl",
    "deprecations.jl",
)

@testset "NamedDims.jl" begin
    @testset "$file" for file in testfiles
        include(file)
    end
end
