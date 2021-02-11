module Factotum

using IterTools
using LinearAlgebra
using Optim
using Printf
using Statistics
using StatsBase
using StatsFuns
using PrettyTables

abstract type AbstractFactorModel end

struct FactorModel{M <: AbstractMatrix, V <: AbstractVector} <: AbstractFactorModel
    "The matrix of factors"
    factors::M
    "The matrix of loadings"
    loadings::M
    "The eigenvalues of X'X"
    eigenvalues::V
    "Residual " # Why here? Maybe to use to view and update in place...
    residuals::M
    "To demean and scale the matrix X"
    center::M
    scale::M
    "The original matrix"
    X::M
end

struct FactorModelView{M <: AbstractMatrix, S <: AbstractMatrix, V <: AbstractVector, R} <: AbstractFactorModel
    "The matrix of factors"
    factors::M
    "The matrix of loadings"
    loadings::S
    "The eigenvalues of X'X"
    eigenvalues::V
    "Residual " # Why here? Maybe to use to view and update in place...
    residuals::R
    "The rescaled matrix"
    X::R
end

function FactorModel(Z::AbstractMatrix{G}, numfactors; kwargs...) where G
    T, n = size(Z)
    (F, Λ, λ, ε, μ, σₓ, X) = T > n ? extract_ΛΛ(Z, numfactors; kwargs...) : extract_FF(Z; kwargs...)    
    FactorModel(F, Λ, λ, ε, μ, σₓ, X)
end

function extract_ΛΛ(Z, numfactors; demean::Bool = true, scale::Bool = false, corrected::Bool = false)
    ## Estimate
    ## X = FΛ' + e
    ##
    ## Λ'Λ = I
    ## F'F = V, V (rxr) diagonal
    T, n = size(Z)
    μ = demean ? mean(Z; dims = 1) : zeros(1, n)
    σₓ = scale ? std(Z; dims = 1, corrected = corrected) : ones(1, n)
    X = (Z .- μ)./σₓ
    ev = eigen(Symmetric(X'*X), n-numfactors+1:n)
    neg = findall(x -> x < 0, ev.values)
    if !isempty(neg)
        if any(ev.values[neg] .< -9 * eps(Float64) * first(ev.values))
            error("covariance matrix is not non-negative definite")
        else
            ev.values[neg] = 0.0
        end
    end
    λ  = ev.values[numfactors:-1:1] 
    Λ = sqrt(n).*ev.vectors[:, numfactors:-1:1]
    F = X*Λ/n
    ε = (X .- F*Λ')
    (F, Λ, λ, ε, μ, σₓ, Z)
end


function Base.view(fm::FactorModel, k::Int) 
    @assert k > 0 "Cannot view a FactorModel with 0 factors"
    view(fm, 1:k) 
end

function Base.view(fm::FactorModel, rnge::UnitRange)
    T, n = size(fm)
    @assert numfactors(fm) >= maximum(rnge) "Cannot create a FactorModel's view with $(maximum(rnge)) when the parent has $(numfactors(fm)) factors"
    @assert first(rnge) <= maximum(rnge) 
    ## To do: check that max(range) < numfactors fm
    FactorModelView(view(factors(fm), :, rnge), view(loadings(fm), :, rnge),
        view(eigvals(fm), rnge), similar(residuals(fm), T, n), rescaledX(fm))
end


## ------------------------------------------------------------
## Methods
## ------------------------------------------------------------
Base.size(fm::AbstractFactorModel) = size(fm.X)
numfactors(fm::AbstractFactorModel) = size(loadings(fm), 2)
loadings(fm::AbstractFactorModel) = fm.loadings
factors(fm::AbstractFactorModel) = fm.factors

LinearAlgebra.eigvals(fm::AbstractFactorModel) = fm.eigenvalues

function sdev(fm::AbstractFactorModel) 
    T, n = size(fm)
    λ = eigvals(fm)
    sqrt.(λ/(T*n))
end

function explained_variance(fm::FactorModel) 
    λ = eigvals(fm)
    λ./sum(λ)
end

function rescaled_factors(fm::AbstractFactorModel)
    F = factors(fm)
    σ = sdev(fm)
    F*diagm(0=>σ)
end

function StatsBase.residuals(fm::AbstractFactorModel)
    F = factors(fm)
    Λ = loadings(fm)
    rescaledX(fm) .- F*Λ'
end

plainX(fm::AbstractFactorModel) = fm.X
rescaledX(fm::FactorModel) = (plainX(fm) .- fm.center)./fm.scale
rescaledX(fm::FactorModelView) = plainX(fm)

## Output
function Base.show(io::IO, fm::AbstractFactorModel)
    printstyled(io, "\nStatic Factor Model\n", color = :green)
    #@printf io "------------------------------------------------------\n"
    @printf io "Dimensions of X..........: %s\n" size(fm)
    @printf io "Number of factors........: %s\n" numfactors(fm)
    @printf io "Factors calculated by....: %s\n" "Principal Component"
    #@printf io "\n"
    #@printf io "------------------------------------------------------\n"
end

describe(fm::FactorModel) = describe(stdout, fm)

function describe(io::IO, fm::FactorModel)
    show(io, fm)
    printstyled(io, "Factors' importance:\n", color = :green)
    factortable(io, fm)
end

function factortable(io::IO, fm::FactorModel)
    explainedvar = explained_variance(fm)
    colnms = "Factor_".*string.(1:numfactors(fm))
    rownms = ["Standard deviation", "Proportion of Variance", "Cumulative Proportion"]
    mat = vcat(sdev(fm)', explainedvar', cumsum(explainedvar)')
    ct = CoefTable(mat, colnms, rownms)
    show(io, ct)
end

## ------------------------------------------------------------
## Information Criteria
## ------------------------------------------------------------
abstract type SelectionCriteria end
struct ICp1 <: SelectionCriteria end
struct ICp2 <: SelectionCriteria end
struct ICp3 <: SelectionCriteria end
struct PCp1 <: SelectionCriteria end
struct PCp2 <: SelectionCriteria end
struct PCp3 <: SelectionCriteria end
struct AIC1 <: SelectionCriteria end
struct AIC2 <: SelectionCriteria end
struct AIC3 <: SelectionCriteria end
struct BIC1 <: SelectionCriteria end
struct BIC2 <: SelectionCriteria end
struct BIC3 <: SelectionCriteria end

struct InformationCriterion{M <: SelectionCriteria}
    criterion::M
    crit::Array{Float64,1}
    kₘₐₓ::UnitRange{Int64} ## Change name of this field -> rnge
end

## Calculate V(F̂ᵏ) for k ⩽ kₘₐₓ 
function V(fmv::FactorModelView)
    Λ = loadings(fmv)
    F = factors(fmv)
    mul!(fmv.residuals, F, Λ')
    fmv.residuals .= rescaledX(fmv) .- fmv.residuals    
    mean(fmv.residuals.^2)
end

V(fm::FactorModel, kₘₐₓ) = [V(view(fm, j)) for j ∈ 1:kₘₐₓ]    

variance_factor(::Type{M}, fm, kₘₐₓ) where M <: Union{ICp1, ICp2, ICp3} = 1.0
variance_factor(::Type{M}, fm, kₘₐₓ) where M <: SelectionCriteria = V(view(fm, kₘₐₓ))
transform_V(::Type{M}, V) where M <: Union{ICp1, ICp2, ICp3} = log.(V)
transform_V(::Type{M}, V) where M <: SelectionCriteria = V

function informationcriterion(s::Type{M}, fm::FactorModel, kₘₐₓ::Int64) where M <: SelectionCriteria
    T, n = size(fm)
    rnge = 1:kₘₐₓ
    σ̂² = Factotum.variance_factor(s, fm, kₘₐₓ)
    Vₖ  = Factotum.transform_V.(s, Factotum.V(fm, kₘₐₓ))
    gₜₙ= map(k -> penalty(s, T, n, k), rnge)
    InformationCriterion(M(), Vₖ + σ̂².*(rnge).*gₜₙ, rnge)
end

(for criterion ∈ (:BIC1, :BIC2, :BIC3, :AIC1, :AIC2, :AIC3, :ICp1, :ICp2, :ICp3, :PCp1, :PCp2, :PCp3)
    eval(quote 
    ($criterion)(fm, kₘₐₓ::Int64) = Factotum.informationcriterion($criterion, fm, kₘₐₓ)
    end)
end)

function Base.show(io::IO, ic::T) where T <: InformationCriterion
    header = ["# of factor"  "Criterion"]
    highlight1 = Highlighter((data, i, j) -> data[i,2] == minimum(data[:,2]), Crayon(background = :light_blue, foreground = :white, bold = true))
    highlight2 = Highlighter((data, i, j) -> (j == 2), Crayon(foreground = :light_blue))
    highlight3 = Highlighter((data, i, j) -> (j == 1), Crayon(foreground = :light_red, bold = true))
    pretty_table([ic.kₘₐₓ ic.crit], header, header_crayon = crayon"yellow bold", formatters = (ft_printf("%5.0f", 1), ft_printf("%5.3f", 2:2)), highlighters = (highlight1, highlight2, highlight3))
end

function penalty(s::Type{P}, T, N, k) where P <: Union{ICp1, PCp1}
    NtT = N*T
    NpT = N+T
    p1 = NpT/NtT
    p2 = log(NtT/NpT)
    p1*p2
end

function penalty(s::Type{P}, T, N, k) where P <: Union{ICp2, PCp2}
    C2  = min(T, N)
    NtT = N*T
    NpT = N+T
    p1 = NpT/NtT
    p2 = log(C2)
    p1*p2
end

function penalty(s::Type{P}, T, N, k) where P <: Union{ICp3, PCp3}
    C2  = min(T, N)
    log(C2)/C2
end

penalty(s::Type{AIC1}, T, N, k) = 2/T
penalty(s::Type{AIC2}, T, N, k) = 2/N
penalty(s::Type{AIC3}, T, N, k) = 2*(N+T-k)/(N*T)

penalty(s::Type{BIC1}, T, N, k) = log(T)/T
penalty(s::Type{BIC2}, T, N, k) = log(N)/N
penalty(s::Type{BIC3}, T, N, k) = ((N+T-k)*log(N*T))/(N*T)

############################################################
## Wald test
############################################################
# struct WaldTest
#     tbl::NamedTuple
#     rankmin::Int64
#     rankₘₐₓ::Int64
# end

# struct WaldTestFun{F, T, Z}
#     f::F
#     r::Int64
#     vecsigma::T
#     Vhat::Z
# end

# (wf::WaldTestFun)(theta) = wf.f(theta, wf.r, wf.vecsigma, wf.Vhat)

# function waldobjfun(th, r, vecsigma, Vhat)
#     ##r,k = size(theta) ## note that the rank being tested is r0 = r-1
#     theta = reshape(th, r+1, length(th)÷(r+1))
#     sigmamat = diagm(0=>theta[1,:].^2) .+ theta[2:r+1,:]'*theta[2:r+1,:]
#     tempsigma = sigmamat[findall(tril(ones(size(sigmamat))).==1)]
#     (vecsigma -tempsigma)' /Vhat *(vecsigma - tempsigma)
# end

# X = randn(100,10);
# fm = Factotum.FactorModel(X)

# function waldtest(fm::FactorModel, minrank::Int = 0, maxrank::Int = 2)
#     X = copy(fm.X)
#     T, n = size(X)
#     ## Normalize factor
#     Xs = X / diagm(0=>sqrt.(diag(cov(X))))
#     covX = cov(Xs)
#     meanX = mean(Xs, dims=1)
#     vecsigma = Factotum.vech(covX)
#     bigN = length(vecsigma)
#     Vhat = Array{Float64}(undef, bigN, bigN)
#     varvecsig = zeros(n,n,n,n);

#     for i1 in 1:n, i2 = 1:n, i3 = 1:n, i4 = 1:n
#         varvecsig[i1,i2,i3,i4] = sum( (Xs[:,i1] .- meanX[i1]).*(Xs[:,i2] .- meanX[i2]).*(Xs[:,i3] .- meanX[i3]) .*(Xs[:,i4] .- meanX[i4])) / T^2 - covX[i1,i2] *covX[i3,i4] /T
#     end

#     idx = findall(tril(ones(size(covX))).==1)
#     for i=1:bigN, j=1:bigN   ## map elements of varvecsig array into matrix corresponding to
#         Vhat[i,j] = varvecsig[idx[i],idx[j]]
#     end

#     out_table = (rank = -1, waldstat = NaN, df = NaN, pvalue = NaN)

#     ## Initial values
#     for k in minrank:maxrank
#         wf = WaldTestFun(waldobjfun, k, vecsigma, Vhat)
#         df = (n-k)*(n-k+1)/2 - n

#         theta0 = theta_initial_value(n,k)

#         outs = Array{Tuple{Float64,Array{Float64,1},Bool},1}()

#         for j in theta0
#             out = Optim.optimize(wf, j, BFGS(), Optim.Options(allow_f_increases=true); autodiff=:forward)
#             push!(outs, (out.minimum::Float64, out.minimizer::Array{Float64,1}, Optim.converged(out)::Bool))
#         end

#         convouts = outs[map(x->x[3], outs)]
#         out      = convouts[argmin(map(x->x[1], convouts))]

#         dfa = (rank = k, waldstat = out[1], df = df,  pvalue = 1-StatsFuns.chisqcdf(df, out[1]))
#         append!(out_table, dfa)
#     end
#     filter!(raw->raw[:rank]>=0, out_table)
#     WaldTest(out_table, minrank, maxrank)
# end

# function theta_initial_value(n,k)
#     I3 = ones(1,n)/3
#     ek = [diagm(0=>ones(k)) zeros(k, n-k)]
#     t0 = ([I3; zeros(k,n)], [I3; ones(k,n)./(2*k)],[I3; ek./(2*k)], [I3; reverse(ek./(2*k), dims=2)])::NTuple{4,Array{Float64,2}}
#     map(vec, t0)::NTuple{4,Array{Float64,1}}
# end

# function vech(X::Matrix{S}) where S
#     T, n = size(X)
#     r = round(Int64, n*(n+1)/2)
#     x = Array{S, 1}(undef, r)
#     i = 1
#     for j in 1:n, k in j:n
#         x[i] = X[j,k]
#         i += 1
#     end
#     x
# end

export FactorModel, subview, waldtest, describe, PValue, waldstat, Criteria,
       ICp1, ICp2, ICp3, PCp1, PCp2, PCp3,
       AIC1, AIC2, AIC3, BIC1, BIC2, BIC3

end # module"
