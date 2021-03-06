# ------------------------------------------------------------------
# Licensed under the ISC License. See LICENCE in the project root.
# ------------------------------------------------------------------

module DirectGaussianSimulation

using GeoStatsBase

using Variography
using LinearAlgebra

import GeoStatsBase: preprocess, solvesingle

export DirectGaussSim

"""
    DirectGaussSim(var₁=>param₁, var₂=>param₂, ...)

Direct Gaussian simulation (a.k.a. LU simulation).

## Parameters

* `variogram` - theoretical variogram (default to `GaussianVariogram()`)
* `mean`      - mean of (unconditional simulation) (default to `0`)

## Joint parameters

* `correlation` - correlation coefficient between two covariates (default to `0`).

## Examples

Simulate two variables `var₁` and `var₂` independently:

```julia
julia> DirectGaussSim(:var₁ => (variogram=SphericalVariogram(),mean=10.),
                      :var₂ => (variogram=GaussianVariogram(),))
```

Simulate two correlated variables `var₁` and `var₂` with correlation `0.7`:

```julia
julia> DirectGaussSim(:var₁ => (variogram=SphericalVariogram(),mean=10.),
                      :var₂ => (variogram=GaussianVariogram(),),
                      (:var₁,:var₂) => (correlation=0.7,))
```

### References

Alabert 1987. *The practice of fast conditional simulations through the
LU decomposition of the covariance matrix.*

Oliver 2003. *Gaussian cosimulation: modeling of the cross-covariance.*
"""
@simsolver DirectGaussSim begin
  @param variogram = GaussianVariogram()
  @param mean = nothing
  @jparam correlation = 0.0
end

function preprocess(problem::SimulationProblem, solver::DirectGaussSim)
  # retrieve problem info
  pdata   = data(problem)
  pdomain = domain(problem)

  # result of preprocessing
  preproc = Dict()

  for covars in covariables(problem, solver)
    conames  = covars.names
    coparams = []

    # 1 or 2 variables can be simulated simultaneously
    @assert length(conames) ∈ (1, 2) "invalid number of covariables"

    # preprocess parameters for individual variables
    for var in conames
      # get parameters for variable
      vparams = covars.params[(var,)]
      V = variables(problem)[var]

      # determine variogram model
      γ = vparams.variogram

      # check stationarity
      @assert isstationary(γ) "variogram model must be stationary"

      # retrieve data locations in domain and data values
      dlocs = Vector{Int}()
      z₁ = Vector{V}()
      for (loc, dloc) in datamap(problem, var)
        push!(dlocs, loc)
        push!(z₁, pdata[var][dloc])
      end

      # retrieve simulation locations
      slocs = [l for l in 1:nelms(pdomain) if l ∉ dlocs]

      # covariance between simulation locations
      C₂₂ = sill(γ) .- pairwise(γ, pdomain, slocs)

      if isempty(dlocs)
        d₂  = zero(V)
        L₂₂ = cholesky(Symmetric(C₂₂)).L
      else
        # covariance beween data locations
        C₁₁ = sill(γ) .- pairwise(γ, pdomain, dlocs)
        C₁₂ = sill(γ) .- pairwise(γ, pdomain, dlocs, slocs)

        L₁₁ = cholesky(Symmetric(C₁₁)).L
        B₁₂ = L₁₁ \ C₁₂
        A₂₁ = B₁₂'

        d₂ = A₂₁ * (L₁₁ \ z₁)
        L₂₂ = cholesky(Symmetric(C₂₂ - A₂₁*B₁₂)).L
      end

      if !isnothing(vparams.mean) && !isempty(dlocs)
        @warn "mean can only be specified in unconditional simulation"
      end

      # mean for unconditional simulation
      μ = isnothing(vparams.mean) ? zero(V) : vparams.mean

      # save preprocessed parameters for variable
      push!(coparams, (z₁, d₂, L₂₂, μ, dlocs, slocs))
    end

    # preprocess joint parameters
    if length(conames) == 2
      # get parameters for pair of variables
      if conames ∈ keys(covars.params)
        jparams = covars.params[conames]
      else
        jparams = covars.params[reverse(conames)]
      end

      # 0-lag correlation between variables
      ρ = jparams.correlation

      # save preprocessed parameters for pair of variables
      push!(coparams, (ρ,))
    end
    push!(preproc, conames => coparams)
  end

  preproc
end

function solvesingle(problem::SimulationProblem, covars::NamedTuple,
                     solver::DirectGaussSim, preproc)
  # preprocessed parameters
  conames = covars.names
  params = preproc[conames]

  # simulate first variable
  Y₁, w₁ = lusim(params[1])
  result = Dict(conames[1] => Y₁)

  # simulate second variable
  if length(conames) == 2
    ρ = params[3][1]
    Y₂, w₂ = lusim(params[2], ρ, w₁)
    push!(result, conames[2] => Y₂)
  end

  result
end

function lusim(params, ρ=nothing, w₁=nothing)
  # unpack parameters
  z₁, d₂, L₂₂, μ, dlocs, slocs = params

  # number of points in domain
  npts = length(dlocs) + length(slocs)

  # allocate memory for result
  y = Vector{eltype(z₁)}(undef, npts)

  # conditional simulation
  w₂ = randn(size(L₂₂, 2))
  if isnothing(ρ)
    y₂ = d₂ .+ L₂₂*w₂
  else
    y₂ = d₂ .+ L₂₂*(ρ*w₁ + √(1-ρ^2)*w₂)
  end

  # hard data and simulated values
  y[dlocs] = z₁
  y[slocs] = y₂

  # adjust mean in case of unconditional simulation
  isempty(dlocs) && (y .+= μ)

  y, w₂
end

end
