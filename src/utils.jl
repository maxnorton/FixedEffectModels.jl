using DataFrames, DataArrays, Distances

# Definition and constructors for types Fe and FeInteracted.
# For each fixed effect, this stores the reference vector (ie a map of each row to a group), the weights, the size of each group, and, for FeInteracted, the interaction variable


abstract AbstractFe

immutable type Fe{R} <: AbstractFe
	refs::Vector{R}
	w::Vector{Float64}
	size::Vector{Float64}
	name::Symbol
end

immutable type FeInteracted{R} <: AbstractFe
	refs::Vector{R}
	w::Vector{Float64}
	size::Vector{Float64}
	x::Vector{Float64} # the continuous interaction 
	name::Symbol
	xname::Symbol
end


function Fe(f::PooledDataArray, w::Vector{Float64}, name::Symbol)
	scale = fill(zero(Float64), length(f.pool))
	refs = f.refs
	@simd for i in 1:length(refs)
		@inbounds scale[refs[i]] += abs2(w[i])
	end
	Fe(refs, w, scale, name)
end

function FeInteracted(f::PooledDataArray, w::Vector{Float64}, x::Vector{Float64}, name::Symbol, xname::Symbol)
	scale = fill(zero(Float64), length(f.pool))
	refs = f.refs
	@simd for i in 1:length(refs)
		@inbounds scale[refs[i]] += abs2((x[i] * w[i]))
	end
	FeInteracted(refs, w, scale, x, name, xname)
end


function construct_fe(df::AbstractDataFrame, a::Expr, w::Vector{Float64})
	if a.args[1] == :&
		if (typeof(df[a.args[2]]) <: PooledDataArray) & !(typeof(df[a.args[3]]) <: PooledDataArray)
			f = df[a.args[2]]
			x = convert(Vector{Float64}, df[a.args[3]])
			return(FeInteracted(f, w, x, a.args[2], a.args[3]))
		elseif (typeof(df[a.args[3]]) <: PooledDataArray) & !(typeof(df[a.args[2]]) <: PooledDataArray)
			f = df[a.args[3]]
			x = convert(Vector{Float64}, df[a.args[2]])
			return(FeInteracted(f, w, x, a.args[3], a.args[2]))
		else
			error("& is not of the form factor & nonfactor")
		end
	else
		error("Formula should be composed of & and symbols")
	end
end

function construct_fe(df::AbstractDataFrame, a::Symbol, w::Vector{Float64})
	if typeof(df[a]) <: PooledDataArray
		f = df[a]
		return(Fe(f, w, a))
	else
		error("$(a) is not a pooled data array")
	end
end


#
# This is the demean algorithm
# Algorithm from lfe: http://cran.r-project.org/web/packages/lfe/vignettes/lfehow.pdf

function demean_vector_factor(fe::Fe,  scale::Vector{Float64}, mean::Vector{Float64}, ans::Vector{Float64})
	refs = fe.refs
	w = fe.w
	@simd for i in 1:length(ans)
		@inbounds mean[refs[i]] += ans[i] * w[i]
	end
	@simd for i in 1:length(scale)
		 @inbounds mean[i] *= scale[i] 
	end
	@simd for i in 1:length(ans)
		@inbounds ans[i] -= mean[refs[i]] * w[i]
	end
	return(ans)
end

function demean_vector_factor(fe::FeInteracted,  scale::Vector{Float64}, mean::Vector{Float64}, ans::Vector{Float64})
	refs = fe.refs
	x = fe.x
	w = fe.w
	@simd for i in 1:length(ans)
		@inbounds mean[refs[i]] += ans[i] * x[i] * w[i]
	end
	@simd for i in 1:length(scale)
		 @inbounds mean[i] *= scale[i] 
	end
	@simd for i in 1:length(ans)
		@inbounds ans[i] -= mean[refs[i]] * x[i] * w[i]
	end
	return(ans)
end

function demean_vector(fes::Vector{AbstractFe}, x::Vector{Float64})
	tolerance = ((1e-8 * length(x))^2)::Float64
	delta = 1.0
	if length(fes) == 1 && typeof(fes[1]) <: Fe
		max_iter = 1
	else
		max_iter = 1000
	end
	olx = similar(x)
	# allocate array of means for each factor
	dict1 = Dict{AbstractFe, Vector{Float64}}()
	dict2 = Dict{AbstractFe, Vector{Float64}}()
	for fe in fes
		dict1[fe] = zeros(Float64, length(fe.size))
		dict2[fe] = 1.0 ./ fe.size
	end
	for iter in 1:max_iter
		@simd for i in 1:length(x)
			@inbounds olx[i] = x[i]
		end
		for fe in fes
			mean = dict1[fe]
			scale = dict2[fe]
			fill!(mean, zero(Float64))
			demean_vector_factor(fe, scale, mean,  x)
		end
		delta = sqeuclidean(x, olx)
		if delta < tolerance
			break
		end
	end
	return(x)
end


#
# helper functions
#
function dropUnusedLevels!(f::PooledDataArray)
	rr = f.refs
	uu = unique(rr)
	f.pool = uu
	T = eltype(rr)
	dict = Dict(uu, 1:convert(Uint32, length(uu)))
	@simd for i in 1:length(rr)
		@inbounds rr[i] = dict[rr[i]]
	end
	f
end
dropUnusedLevels!(f::DataArray) = f

function group(df::AbstractDataFrame; skipna = true) 
	ncols = length(df)
	dv = DataArrays.PooledDataArray(df[ncols])
	if skipna
		x = map(z -> convert(Uint32, z), dv.refs)
		ngroups = length(dv.pool)
		for j = (ncols - 1):-1:1
			dv = DataArrays.PooledDataArray(df[j])
			for i = 1:DataFrames.size(df, 1)
				x[i] += ((dv.refs[i] == 0 | x[i] == 0) ? 0 : (dv.refs[i] - 1) * ngroups)
			end
			ngroups = ngroups * length(dv.pool)
		end
		# factorize
		uu = unique(x)
		T = eltype(x)
		vv = setdiff(uu, zero(T))
		dict = Dict(vv, 1:(length(vv)))
		compact(PooledDataArray(DataArrays.RefArray(map(z -> z == 0 ? zero(T) : dict[z], x)),  [1:length(vv);]))
	else
		# code from groupby
		dv_has_nas = (findfirst(dv.refs, 0) > 0 ? 1 : 0)
		x = map(z -> convert(Uint32, z) + dv_has_nas, dv.refs)
		ngroups = length(dv.pool) + dv_has_nas
		for j = (ncols - 1):-1:1
			dv = DataArrays.PooledDataArray(df[j])
			dv_has_nas = (findfirst(dv.refs, 0) > 0 ? 1 : 0)
			for i = 1:DataFrames.size(df, 1)
				x[i] += (dv.refs[i] + dv_has_nas- 1) * ngroups
			end
			ngroups = ngroups * (length(dv.pool) + dv_has_nas)
		end
		# end of code from groupby
		# factorize
		uu = unique(x)
		T = eltype(x)
		dict = Dict(uu, 1:length(uu))
		compact(PooledDataArray(DataArrays.RefArray(map(z -> dict[z], x)),  [1:length(uu);]))
	end
end


group(df::AbstractDataFrame, cols::Vector; skipna = true) =  group(df[cols]; skipna = skipna)






# compute rss and tss from vector of residual and response vector

function compute_ss(residuals::Vector{Float64}, y::Vector{Float64}, hasintercept::Bool)
	ess = abs2(norm(residuals))
	if hasintercept
		tss = zero(Float64)
		m = mean(y)::Float64
		@simd for i in 1:length(y)
			@inbounds tss += abs2((y[i] - m))
		end
	else
		tss = abs2(norm(y))
	end
	(ess, tss)
end


function compute_ss(residuals::Vector{Float64}, y::Vector{Float64}, hasintercept::Bool, w::Vector{Float64}, sqrtw::Vector{Float64})
	ess = abs2(norm(residuals))
	if hasintercept
		m = (mean(y) / sum(sqrtw) * length(residuals))::Float64
		tss = zero(Float64)
		@simd for i in 1:length(y)
			@inbounds tss += abs2(y[i] - sqrtw[i] * m)
		end
	else
		tss = abs2(norm(y))
	end
	(ess, tss)
end

function remove_negweight!{R}(esample::BitArray{1}, w::DataVector{R})
	@simd for (i in 1:length(w))
		@inbounds esample[i] = esample[i] && (w[i] > zero(R))
	end
	esample
end

function multiplication_elementwise!(y::Vector{Float64}, sqrtw::Vector{Float64})
	@simd for i in 1:length(y)
		@inbounds y[i] *= sqrtw[i] 
	end
end


function division_elementwise!(y::Vector{Float64}, sqrtw::Vector{Float64})
	@simd for i in 1:length(y)
		@inbounds y[i] /= sqrtw[i] 
	end
end







