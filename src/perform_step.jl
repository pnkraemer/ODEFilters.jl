# Called in the OrdinaryDiffEQ.__init; All `OrdinaryDiffEqAlgorithm`s have one
function OrdinaryDiffEq.initialize!(integ, cache::GaussianODEFilterCache)
    @assert integ.saveiter == 1
    OrdinaryDiffEq.copyat_or_push!(integ.sol.x, integ.saveiter, copy(cache.x))
    OrdinaryDiffEq.copyat_or_push!(integ.sol.pu, integ.saveiter, cache.SolProj*cache.x)
end

"""Perform a step

Not necessarily successful! For that, see `step!(integ)`.

Basically consists of the following steps
- Coordinate change / Predonditioning
- Prediction step
- Measurement: Evaluate f and Jf; Build z, S, H
- Calibration; Adjust prediction / measurement covs if the diffusion model "dynamic"
- Update step
- Error estimation
- Undo the coordinate change / Predonditioning
"""
function OrdinaryDiffEq.perform_step!(integ, cache::GaussianODEFilterCache, repeat_step=false)
    @unpack t, dt = integ
    @unpack d, Proj, SolProj, Precond, InvPrecond = integ.cache
    @unpack x, x_pred, u_pred, x_filt, u_filt, err_tmp = integ.cache
    @unpack A, Q = integ.cache

    tnew = t + dt

    # Coordinate change / preconditioning
    P = Precond(dt)
    PI = InvPrecond(dt)
    x = P * x

    # Predict
    predict!(x_pred, x, A, Q*dt, integ.cache.covmatcache)
    mul!(u_pred, SolProj, PI*x_pred.μ)

    # Measure
    measure!(integ, x_pred, tnew)

    # Estimate diffusion
    diffmat = estimate_diffusion(cache.diffusionmodel, integ)
    integ.cache.diffmat = diffmat
    if isdynamic(cache.diffusionmodel) # Adjust prediction and measurement
        predict!(x_pred, x, A, apply_diffusion(Q*dt, diffmat), integ.cache.covmatcache)
        copy!(integ.cache.measurement.Σ, X_A_Xt(x_pred.Σ, integ.cache.H))
    end

    # Likelihood
    v, S = cache.measurement.μ, cache.measurement.Σ
    cache.log_likelihood = logpdf(cache.measurement, zeros(d))

    # Update
    x_filt = update!(integ, x_pred)

    # Undo the coordinate change / preconditioning
    mul!(integ.cache.x, PI, x)
    mul!(integ.cache.x_pred, PI, x_pred)
    mul!(integ.cache.x_filt, PI, x_filt)
    mul!(u_filt, SolProj, integ.cache.x_filt.μ)
    integ.u .= u_filt

    # Estimate error for adaptive steps
    if integ.opts.adaptive
        err_est_unscaled = estimate_errors(integ, integ.cache)
        DiffEqBase.calculate_residuals!(
            err_tmp, dt * err_est_unscaled, integ.uprev, integ.u,
            integ.opts.abstol, integ.opts.reltol, integ.opts.internalnorm, t)
        integ.EEst = integ.opts.internalnorm(err_tmp, t) # scalar
    end
end


function h!(integ, x_pred, t)
    @unpack f, p, dt = integ
    @unpack u_pred, du, Proj, InvPrecond, measurement = integ.cache
    PI = InvPrecond(dt)
    z = measurement.μ
    E0, E1 = Proj(0), Proj(1)

    IIP = isinplace(integ.f)
    if IIP
        f(du, u_pred, p, t)
    else
        du .= f(u_pred, p, t)
    end
    integ.destats.nf += 1

    mul!(z, E1, PI*x_pred.μ)
    z .-= du

    return z
end

function H!(integ, x_pred, t)
    @unpack f, p, dt, alg = integ
    @unpack ddu, Proj, InvPrecond, H, u_pred = integ.cache
    E0, E1 = Proj(0), Proj(1)
    PI = InvPrecond(dt)

    if alg isa EKF1 || alg isa IEKS
        if alg isa IEKS && !isnothing(alg.linearize_at)
            linearizeat_u = alg.linearize_at(t).μ
        else
            linearizeat_u = u_pred
        end

        if isinplace(integ.f)
            f.jac(ddu, linearizeat_u, p, t)
        else
            ddu .= f.jac(linearizeat_u, p, t)
            # WIP: Handle Jacobians as OrdinaryDiffEq.jl does
            # J = OrdinaryDiffEq.jacobian((u)-> f(u, p, t), u_pred, integ)
            # @assert J ≈ ddu
        end
        integ.destats.njacs += 1
        mul!(H, E1 .- ddu * E0, PI)
    else
        mul!(H, E1, PI)
    end

    return H
end


function measure!(integ, x_pred, t)
    @unpack R = integ.cache
    @unpack u_pred, measurement, H = integ.cache

    z, S = measurement.μ, measurement.Σ
    z .= h!(integ, x_pred, t)
    H .= H!(integ, x_pred, t)
    # R .= Diagonal(eps.(z))
    @assert iszero(R)
    copy!(S, X_A_Xt(x_pred.Σ, H))

    return nothing
end


function update!(integ, prediction)
    @unpack measurement, H, R, x_filt, K, covmatcache, tmp = integ.cache
    update!(x_filt, prediction, measurement, H, K, R, covmatcache, tmp)
    # assert_nonnegative_diagonal(x_filt.Σ)
    return x_filt
end


function estimate_errors(integ, cache::GaussianODEFilterCache)
    @unpack dt = integ
    @unpack InvPrecond = integ.cache
    @unpack diffmat, Q, H, tmp, covmatcache = integ.cache
    error_estimate = tmp

    if diffmat isa Real && isinf(diffmat)
        return Inf
    end

    # Only split up to evaluate allocations
    mul!(covmatcache, Q, dt)
    _A = apply_diffusion(covmatcache, diffmat)
    _B = X_A_Xt(_A, H)
    _C = diag(_B)
    error_estimate .= sqrt.(_C)

    return error_estimate
end
