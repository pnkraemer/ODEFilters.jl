__precompile__()

module ProbNumODE

using Reexport
@reexport using DiffEqBase

using LinearAlgebra
using Measurements
using ForwardDiff
using StructArrays
using UnPack
using StaticArrays
using RecipesBase
using Distributions

using UUIDs, ProgressLogging

import Base: copy

@inline _copy(a::SArray) = a
@inline _copy(a) = copy(a)

include("filtering.jl")
include("steprules.jl")
include("priors.jl")
include("utils.jl")
include("sigmas.jl")
include("algorithm.jl")

include("dev/problems.jl")
export exponential_decay, logistic_equation, brusselator, fitzhugh_nagumo, lotka_volterra, van_der_pol
include("dev/visualization.jl")
export hairer_plot

include("diffeq.jl")
include("solution.jl")

end
