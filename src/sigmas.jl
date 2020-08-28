abstract type AbstractSigmaRule end
function static_sigma_estimation(rule::AbstractSigmaRule, integ)
    return one(integ.cache.σ_sq)
end
function dynamic_sigma_estimation(rule::AbstractSigmaRule, integ)
    return one(integ.cache.σ_sq)
end


struct MLESigma <: AbstractSigmaRule end
function static_sigma_estimation(rule::MLESigma, integ)
    @unpack proposals = integ
    accepted_proposals = [p for p in proposals if p.accept]
    measurements = [p.measurement for p in accepted_proposals]
    d = integ.constants.d
    residuals = [v.μ' * inv(v.Σ) * v.μ for v in measurements] ./ d
    σ² = mean(residuals)
    return σ²
end


struct WeightedMLESigma <: AbstractSigmaRule end
function static_sigma_estimation(rule::WeightedMLESigma, integ)
    @unpack proposals = integ
    accepted_proposals = [p for p in proposals if p.accept]
    measurements = [p.measurement for p in accepted_proposals]
    d = integ.constants.d
    residuals = [v.μ' * inv(v.Σ) * v.μ for v in measurements] ./ d
    stepsizes = [p.dt for p in accepted_proposals]
    σ² = mean(residuals .* stepsizes)
    return σ²
end


struct MAPSigma <: AbstractSigmaRule end
function static_sigma_estimation(rule::MAPSigma, integ)
    @unpack proposals = integ
    accepted_proposals = [p for p in proposals if p.accept]
    measurements = [p.measurement for p in accepted_proposals]
    d = integ.constants.d
    residuals = [v.μ' * inv(v.Σ) * v.μ for v in measurements] ./ d
    N = length(residuals)

    α, β = 1/2, 1/2
    # prior = InverseGamma(α, β)
    α2, β2 = α + N*d/2, β + 1/2 * (sum(residuals))
    posterior = InverseGamma(α2, β2)
    sigma = mode(posterior)
    return sigma
end


struct SchoberSigma <: AbstractSigmaRule end
function dynamic_sigma_estimation(kind::SchoberSigma, integ)
    @unpack d = integ.constants
    @unpack h, H, Qh = integ.cache
    jitter = 1e-12
    σ² = h' * inv(H*Qh*H' + jitter*I) * h / d
    return σ²
end


"""Filip's proposition: Estimate sigma through a one-step EM

This seems pretty stable! One iteration indeed feels like it is enough.
I compared this single loop approach with one with `i in 1:1000`, and could not notice a difference.
=> This seems cool!
It does not seem to behave too different from the schober sigmas, but I mean the theory is wayy nicer!
"""
struct EMSigma <: AbstractSigmaRule end
function dynamic_sigma_estimation(kind::EMSigma, integ)
    @unpack d, q = integ.constants
    @unpack h, H, Qh, x_pred, x, Ah, σ_sq = integ.cache
    @unpack R = integ.constants

    sigma = σ_sq

    x_prev = x

    for i in 1:1
        x_n_pred = Gaussian(Ah * x_prev.μ, Ah * x_prev.Σ * Ah' + sigma*Qh)

        _m, _P = x_n_pred.μ, x_n_pred.Σ
        S = H * _P * H' + R
        K = _P * H' * inv(S)
        x_n_filt = Gaussian(_m + K*h, _P - K*S*K')

        # x_prev = integ.state_estimates[end]

        _m, _P = kf_smooth(x_prev.μ, x_prev.Σ, x_n_pred.μ, x_n_pred.Σ, x_n_filt.μ, x_n_filt.Σ, Ah, sigma*Qh)
        x_prev_smoothed = Gaussian(_m, _P)

        # Compute σ² in closed form:
        diff = x_n_filt.μ - Ah*x_prev_smoothed.μ
        sigma = diff' * inv(Qh) * diff / (d*(q+1))
    end

    return sigma
end
