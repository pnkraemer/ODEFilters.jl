########################################################################################
# Solution
########################################################################################
abstract type AbstractProbODESolution{T,N,S} <: DiffEqBase.AbstractODESolution{T,N,S} end
mutable struct ProbODESolution{
    T,N,uType,
    puType, uType2, DType, tType, rateType, xType, diffType, llType,
    P, A,
    IType,DE} <: AbstractProbODESolution{T,N,uType}
    u::uType
    pu::puType
    u_analytic::uType2
    errors::DType
    t::tType
    k::rateType
    x::xType
    diffusions::diffType
    log_likelihood::llType
    prob::P
    alg::A
    interp::IType
    dense::Bool
    tslocation::Int
    destats::DE
    retcode::Symbol
end
function DiffEqBase.solution_new_retcode(sol::ProbODESolution{T,N}, retcode) where {T,N}
    ProbODESolution{T, N, typeof(sol.u),
                    typeof(sol.pu),
                    typeof(sol.u_analytic),
                    typeof(sol.errors),
                    typeof(sol.t),
                    typeof(sol.k),
                    typeof(sol.x),
                    typeof(sol.diffusions),
                    typeof(sol.log_likelihood),
                    typeof(sol.prob),
                    typeof(sol.alg),
                    typeof(sol.interp), typeof(sol.destats)}(
        sol.u, sol.pu, sol.u_analytic, sol.errors, sol.t, sol.k, sol.x, sol.diffusions,
        sol.log_likelihood,
        sol.prob, sol.alg, sol.interp, sol.dense, sol.tslocation, sol.destats, retcode,
    )
end

# Used to build the initial empty solution in OrdinaryDiffEq.__init
function DiffEqBase.build_solution(
    prob::DiffEqBase.AbstractODEProblem,
    alg::GaussianODEFilter,
    t, u;
    k = nothing,
    retcode = :Default,
    destats = nothing,
    dense = true,
    kwargs...)

    T = eltype(eltype(u))
    N = length((size(prob.u0)..., length(u)))

    d = length(prob.u0)
    uEltype = eltype(prob.u0)
    cov = zeros(uEltype, d, d)
    if alg.squarerootfilter
        cov = PSDMatrix(UpperTriangular(cov))
    end
    pu = StructArray{Gaussian{Vector{eltype(prob.u0)}, typeof(cov)}}(undef, 1)
    x = copy(pu)

    interp = GaussianODEFilterPosterior(alg, prob.u0)

    if DiffEqBase.has_analytic(prob.f)
        u_analytic = Vector{typeof(prob.u0)}()
        errors = Dict{Symbol,real(eltype(prob.u0))}()
    else
        u_analytic = nothing
        errors = nothing
    end

    k = []
    diffusions = []
    log_likelihood = 0
    return ProbODESolution{
        T, N, typeof(u),
        typeof(pu), typeof(u_analytic), typeof(errors), typeof(t), typeof(k), typeof(x), typeof(diffusions), typeof(log_likelihood), typeof(prob), typeof(alg),
        typeof(interp), typeof(destats)}(
        u, pu, u_analytic, errors, t, k, x, diffusions, log_likelihood, prob, alg, interp, dense, 0, destats, retcode,
    )
end


function DiffEqBase.build_solution(sol::ProbODESolution{T,N}, u_analytic, errors) where {T,N}
    return ProbODESolution{
        T, N, typeof(sol.u),
        typeof(sol.pu), typeof(u_analytic), typeof(errors), typeof(sol.t), typeof(sol.k), typeof(sol.x), typeof(sol.diffusions), typeof(sol.log_likelihood), typeof(sol.prob), typeof(sol.alg),
        typeof(sol.interp), typeof(sol.destats)}(
        sol.u, sol.pu, u_analytic, errors, sol.t, sol.k, sol.x, sol.diffusions,
        sol.log_likelihood, sol.prob,
        sol.alg, sol.interp, sol.dense, sol.tslocation, sol.destats, sol.retcode,
    )
end


########################################################################################
# Dense Output
########################################################################################
abstract type AbstractODEFilterPosterior <: DiffEqBase.AbstractDiffEqInterpolation end
struct GaussianODEFilterPosterior{SolProjType, AType, QType, F1, F2} <: AbstractODEFilterPosterior
    d::Int
    q::Int
    SolProj::SolProjType
    A::AType
    Q::QType
    Precond::F1
    InvPrecond::F2
    smooth::Bool
end
function GaussianODEFilterPosterior(alg, u0)
    uElType = eltype(u0)
    d = length(u0)
    q = alg.order

    Proj(deriv) = kron([i==(deriv+1) ? 1 : 0 for i in 1:q+1]', diagm(0 => ones(d)))
    SolProj = Proj(0)

    A, Q = ibm(d, q, uElType)
    Precond, InvPrecond = preconditioner(d, q)
    GaussianODEFilterPosterior(
        d, q, SolProj, A, Q, Precond, InvPrecond, alg.smooth)
end
DiffEqBase.interp_summary(interp::GaussianODEFilterPosterior) = "Gaussian ODE Filter Posterior"

function (posterior::GaussianODEFilterPosterior)(tval::Real, t, x, diffusions)
    @unpack A, Q, d, q, Precond, InvPrecond = posterior

    if tval < t[1]
        error("Invalid t<t0")
    end
    if tval in t
        idx = sum(t .<= tval)
        @assert t[idx] == tval
        return x[idx]
    end

    idx = sum(t .<= tval)
    prev_t = t[idx]
    prev_rv = x[idx]
    diffmat = diffusions[minimum((idx, end))]

    # Extrapolate
    h1 = tval - prev_t
    P, PI = Precond(h1), InvPrecond(h1)
    Qh = apply_diffusion(Q*h1, diffmat)
    goal_pred = predict(P * prev_rv, A, Qh)
    goal_pred = PI * goal_pred

    if !posterior.smooth || tval >= t[end]
        return goal_pred
    end

    next_t = t[idx+1]
    next_smoothed = x[idx+1]

    # Smooth
    h2 = next_t - tval
    P, PI = Precond(h2), InvPrecond(h2)
    goal_pred = P * goal_pred
    next_smoothed = P * next_smoothed
    Qh = apply_diffusion(Q*h2, diffmat)

    goal_smoothed, _ = smooth(goal_pred, next_smoothed, A, Qh)

    return PI * goal_smoothed
end
function (sol::ProbODESolution)(t::Real, deriv::Val{N}=Val(0)) where {N}
    @unpack q, d = sol.interp
    return sol.interp.SolProj * sol.interp(t, sol.t, sol.x, sol.diffusions)
end
(sol::ProbODESolution)(t::AbstractVector, deriv=Val(0)) = StructArray(sol.(t, deriv))



########################################################################################
# Plotting
########################################################################################
@recipe function f(sol::AbstractProbODESolution; ribbon_width=1.96)
    times = range(sol.t[1], sol.t[end], length=1000)
    dense_post = sol(times)
    values = stack(mean(dense_post))
    stds = stack(std(dense_post))
    ribbon --> ribbon_width * stds
    xguide --> "t"
    yguide --> "u(t)"
    label --> hcat(["u$(i)(t)" for i in 1:length(sol.u[1])]...)
    return times, values
end


########################################################################################
# Sampling from a solution
########################################################################################
"""Helper function to sample from our covariances, which often have a "cross" of zeros
For the 0-cov entries the outcome of the sampling is deterministic!"""
function _rand(x::Gaussian, n::Int=1)
    m, C = x.μ, x.Σ
    @assert C isa PSDMatrix

    sample = m .+ C.L*randn(length(m), n)
    return sample
end


function sample_back(x_curr::Gaussian, x_next_sample::AbstractVector, Ah::AbstractMatrix, Qh::AbstractMatrix, PI=I)
    m_p, P_p = Ah*x_curr.μ, Ah*x_curr.Σ*Ah' + Qh
    P_p_inv = inv(Symmetric(P_p))
    Gain = x_curr.Σ * Ah' * P_p_inv

    m = x_curr.μ + Gain * (x_next_sample - m_p)

    P = X_A_Xt(x_curr.Σ, (I - Gain*Ah)) + X_A_Xt(Qh, Gain)

    assert_nonnegative_diagonal(P)
    return Gaussian(m, P)
end


function sample(sol::ProbODESolution, n::Int=1)
    sample(sol.t, sol.x, sol.diffusions, sol.t, sol.interp, n)
end
function sample(ts, xs, diffusions, difftimes, posterior, n::Int=1)

    @unpack A, Q, d, q, Precond, InvPrecond = posterior
    E0 = kron([i==1 ? 1 : 0 for i in 1:q+1]', diagm(0 => ones(d)))
    dim = d*(q+1)

    x = xs[end]
    sample = _rand(x, n)
    @assert size(sample) == (dim, n)

    sample_path = zeros(length(ts), dim, n)
    sample_path[end, :, :] .= sample
    # @info "final value and samples" x.μ sample sample_path[end, :]

    for i in length(xs)-1:-1:1
        dt = ts[i+1] - ts[i]

        i_diffusion = sum(difftimes .<= ts[i])
        diffmat = diffusions[i_diffusion]

        Qh = apply_diffusion(Q*dt, diffmat)
        P, PI = Precond(dt), InvPrecond(dt)

        for j in 1:n
            sample_p = P*sample_path[i+1, :, j]
            x_prev_p = P*xs[i]

            prev_sample_p = sample_back(x_prev_p, sample_p, A, Qh, PI)

            # sample_path[i, :, j] .= PI*prev_sample_p.μ
            sample_path[i, :, j] .= PI*_rand(prev_sample_p)[:]
        end
    end

    return sample_path[:, 1:d, :]
end
function dense_sample(sol::ProbODESolution, n::Int=1)
    times = range(sol.t[1], sol.t[end], length=1000)
    states = StructArray([sol.interp(t, sol.t, sol.x, sol.diffusions) for t in times])

    sample(times, states, sol.diffusions, sol.t, sol.interp, n), times
end
