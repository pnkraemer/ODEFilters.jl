"""
Check the correctness of the filtering implementations vs. basic readable math code
"""

using ODEFilters
using LinearAlgebra


@testset "PREDICT" begin
    # Setup
    d = 5
    m = rand(d)
    L_p = LowerTriangular(rand(d,d))
    P = L_p*L_p'

    A = rand(d,d)
    L_Q = LowerTriangular(rand(d,d))
    Q = L_Q*L_Q'

    # PREDICT
    m_p = A*m
    P_p = A*P*A' + Q

    x_curr = Gaussian(m,P)
    x_out = copy(x_curr)

    @testset "predict!" begin
        ODEFilters.predict!(x_out, x_curr, A, Q)
        @test m_p == x_out.μ
        @test P_p == x_out.Σ
    end

    @testset "predict" begin
        x_out = ODEFilters.predict(x_curr, A, Q)
        @test m_p == x_out.μ
        @test P_p == x_out.Σ
    end

    @testset "predict! with PSDMatrix" begin
        x_curr = Gaussian(m, PSDMatrix(L_p))
        x_out = copy(x_curr)
        ODEFilters.predict!(x_out, x_curr, A, PSDMatrix(Q))
        @test m_p == x_out.μ
        @test P_p ≈ x_out.Σ
    end

end



@testset "UPDATE" begin
    # Setup
    d = 5
    m_p = rand(d)
    L_P_p = LowerTriangular(rand(d,d))
    P_p = L_P_p * L_P_p'

    # Measure
    o = 3
    H = rand(o, d)
    L_R = 0.0*rand(o, o)
    R = L_R*L_R'

    z_data = zeros(o)
    z = H*m_p
    S = H*P_p*H' + R

    # UPDATE
    S_inv = inv(S)
    K = P_p * H' * S_inv
    m = m_p + K * (z_data .- z)
    P = P_p - K*S*K'

    x_pred = Gaussian(m_p, P_p)
    x_out = copy(x_pred)
    measurement = Gaussian(z, S)

    @testset "update!" begin
        ODEFilters.update!(x_out, x_pred, measurement, H, R)
        @test m == x_out.μ
        @test P ≈ x_out.Σ
    end

    @testset "update!" begin
        x_out = ODEFilters.update(x_pred, measurement, H, R)
        @test m == x_out.μ
        @test P ≈ x_out.Σ
    end

end


@testset "SMOOTH" begin
    # Setup
    d = 5
    m, m_s = rand(d), rand(d)
    L_P, L_P_s = LowerTriangular(rand(d,d)), LowerTriangular(rand(d,d))
    P, P_s = L_P*L_P', L_P_s*L_P_s'

    A = rand(d,d)
    L_Q = LowerTriangular(rand(d,d))
    Q = L_Q*L_Q'

    # PREDICT first
    m_p = A*m
    P_p = A*P*A' + Q

    # SMOOTH
    G = P * A' * inv(P_p)
    m_smoothed = m + G * (m_s - m_p)
    P_smoothed = P + G * (P_s - P_p) * G'

    x_curr = Gaussian(m, P)
    x_smoothed = Gaussian(m_s, P_s)

    ODEFilters.smooth(x_curr, x_smoothed, A, Q)

    @testset "smooth" begin
        x_out, _ = ODEFilters.smooth(x_curr, x_smoothed, A, Q)
        @test m_smoothed == x_out.μ
        @test P_smoothed ≈ x_out.Σ
    end

end
