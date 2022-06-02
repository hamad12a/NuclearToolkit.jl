#using PyCall
#@pyimport matplotlib.pyplot as plt
function myCholesky!(tmpA,ln,cLL)
    l11 = sqrt(tmpA[1,1]) 
    cLL[1,1] = l11
    cLL[2,1] = tmpA[2,1]/l11; cLL[2,2] = sqrt( tmpA[2,2]-cLL[2,1]^2)
    for i=3:ln
        for j=1:i-1
            cLL[i,j] = tmpA[i,j]
            for k = 1:j-1
                cLL[i,j] += - cLL[i,k]*cLL[j,k]                
            end
            cLL[i,j] = cLL[i,j] / cLL[j,j]
        end
        cLL[i,i] = tmpA[i,i]
        for j=1:i-1
            cLL[i,i] += -cLL[i,j]^2
        end
        cLL[i,i] = sqrt(cLL[i,i])             
    end
    return nothing
end

function eval_HFMBPT(it,BOobj,HFdata,varE,Lam)
    thist = BOobj.history[it]
    params = BOobj.params
    params_ref = BOobj.params_ref

    tvec = params-params_ref
    logprior = -0.5*Lam*dot(tvec,tvec)
    llh = 0.0
    for (n,tmp) in enumerate(HFdata)
        nuc = tmp.nuc
        data = tmp.data
        dtype = tmp.datatype
        A= nuc.A
        for (i,tdtype) in enumerate(dtype)
            vtho = data[i][1] *ifelse(tdtype=="E",1/A,1.0)
            vexp = data[i][2] *ifelse(tdtype=="E",1/A,1.0)
            tllh = 0.5 * (vtho-vexp)^2 / varE
            llh -= tllh
        end 
    end 
    logpost = logprior + llh
    thist[1] = logprior
    thist[2] = llh    
    thist[3] = logpost
    println("eval: ","logprior ",@sprintf("%9.2e",logprior),
            "  logllh  ",@sprintf("%9.2e",llh),
            "  logpost ",@sprintf("%9.2e",logpost),"\n" )
    return nothing
end

struct BOobject
    maxDim::Int64
    targetLECs::Vector{String}
    params::Vector{Float64}
    params_ref::Vector{Float64}
    pdomains::Vector{Tuple{Float64, Float64}}
    pKernel::Vector{Float64}
    Data::Vector{Vector{Float64}}
    cand::Vector{Vector{Float64}}
    observed::Vector{Int64}
    unobserved::Vector{Int64}
    history::Vector{Vector{Float64}}
    Ktt::Matrix{Float64}
    Ktinv::Matrix{Float64}
    Ktp::Matrix{Float64}
    L::Matrix{Float64}
    tMat::Matrix{Float64}
    yt::Vector{Float64}
    yscale::Vector{Float64}
    acquis::Vector{Float64}   
end


function get_LECs_params(op)
    targetLECs = String[]
    params = Float64[]; params_ref=Float64[]; pdomains = Tuple{Float64, Float64}[]
    if op=="2n3nall"
        targetLECs= ["ct1_NNLO","ct3_NNLO","ct4_NNLO","cD","cE"]
        params = zeros(Float64,length(targetLECs))
        params_ref = zeros(Float64,length(targetLECs))
        params_ref[1] = -0.81; params_ref[2] = -3.2; params_ref[3] = 5.4    
        pdomains = [ (-1.5,-0.5), (-4.5,-2.0), (2.0,6.0), (-3.0,3.0), (-3.0,3.0) ]
    elseif op=="c34"
        targetLECs= ["ct3_NNLO","ct4_NNLO"]
        params = zeros(Float64,length(targetLECs))
        params_ref = zeros(Float64,length(targetLECs))
        params_ref[1] = -3.2; params_ref[2] = 5.4    
        pdomains = [ (-4.5,-2.0), (2.0,6.0)]
    elseif op == "cDE"
        targetLECs= ["ct3_NNLO","ct4_NNLO"]
        params = zeros(Float64,length(targetLECs))
        params_ref = zeros(Float64,length(targetLECs))
        params_ref[1] = -3.2; params_ref[2] = 5.4    
        pdomains = [ (-4.5,-2.0), (2.0,6.0)]
    else
        println("warn: op=$op in get_LECs_paramas is not supported!")
        exit()
    end
    return targetLECs, params,params_ref,pdomains
end

function prepBO(LECs,idxLECs,dLECs,opt,to;num_cand=1000,
                op="cDE"
                )
    if opt == false;return nothing;end   
    targetLECs, params,params_ref,pdomains = get_LECs_params(op)
    for (k,target) in enumerate(targetLECs)
        idx = idxLECs[target]
        dLECs[target]=params[k] = LECs[idx]
    end 
    pDim = length(targetLECs)

    Data = [zeros(Float64,pDim) for i=1:num_cand] 
    gens = 200
    @timeit to "LHS" plan, _ = LHCoptim(num_cand,pDim,gens)
    tmp = scaleLHC(plan,pdomains)    
    cand = [ tmp[i,:] for i =1:num_cand]

    """
    cand:: candidate point given by LatinHypercubeSampling
    observed:: list of index of `cand` which has been observed
    unobserved:: rest candidate indices
    history:: array of [logprior,logllh,logpost] for i=1:num_cand
    Ktt,Kttinv,Ktp,L:: matrix needed for GP calculation
    yt:: mean value of training point, to be mean of initial random point 
    yscale:: mean&std of yt that is used to scale/rescale data    
    acquis:: vector of acquisition function values
    pKernel:: hypara for GP kernel, first one is `tau` and the other ones are correlation lengths
    adhoc=> tau =1.0, l=1/domain size
    """
    observed = Int64[ ]
    unobserved = collect(1:num_cand)
    history = [zeros(Float64,3) for i=1:num_cand]
    Ktt = zeros(Float64,num_cand,num_cand) 
    Ktinv = zeros(Float64,num_cand,num_cand)
    tMat = zeros(Float64,num_cand,num_cand)
    Ktp = zeros(Float64,num_cand,1)
    L = zeros(Float64,num_cand,num_cand)
    yt = zeros(Float64,num_cand)
    yscale = zeros(Float64,2) 
    acquis = zeros(Float64,num_cand)
    pKernel = ones(Float64,pDim+1)
    for i =1:pDim
        tmp = pdomains[i]
        pKernel[i+1] = 1.0 / (abs(tmp[2]-tmp[1])^2)
    end    
    BOobj = BOobject(num_cand,targetLECs,params,params_ref,pdomains,pKernel,Data,cand,observed,unobserved,history,Ktt,Ktinv,Ktp,L,tMat,yt,yscale,acquis)

    Random.seed!(1234)
    propose!(1,BOobj,false)
    BOobj.Data[1] .= BOobj.params
    for (k,target) in enumerate(targetLECs)
        idx = idxLECs[target]
        LECs[idx] = dLECs[target] = params[k]
    end
    return BOobj
end

function BO_HFMBPT(it,BOobj,HFdata,to;var_proposal=0.2,varE=1.0,varR=0.25,Lam=0.1)
    params = BOobj.params
    D = length(params); n_ini_BO = 2*D
    ## Update history[it]
    eval_HFMBPT(it,BOobj,HFdata,varE,Lam)
    if it==n_ini_BO
        println("obs ",BOobj.observed)
        @timeit to "Kernel" calcKernel!(it,BOobj;ini=true)        
        tmp = [ BOobj.history[i][3] for i=1:it ]
        ymean = mean(tmp); ystd = std(tmp)
        BOobj.yscale[1] = ymean
        BOobj.yscale[2] = ystd
        yt = @view BOobj.yt[1:it]
        yt .= (tmp .- ymean) ./ ystd
    elseif it > n_ini_BO
        @timeit to "Kernel" calcKernel!(it,BOobj)        
        @timeit to "eval p" evalcand(it,BOobj,to)
    end 
    ## Make proposal
    BOproposal = ifelse(it<=n_ini_BO,false,true)
    propose!(it,BOobj,BOproposal)
    BOobj.Data[it] .= BOobj.params
    return nothing
end
function calcKernel!(it,BOobj;ini=false)
    Ktt = @view BOobj.Ktt[1:it,1:it]
    obs = BOobj.observed
    cand = BOobj.cand
    pKernel = BOobj.pKernel
    tau = pKernel[1]
    Theta = @view pKernel[2:end]
    pdim = length(Theta)
    tv = @view BOobj.tMat[pdim+1:2*pdim,1:1]
    tv2 = @view BOobj.tMat[2*pdim+1:3*pdim,1:1]
    rTr = @view BOobj.tMat[3*pdim+1:3*pdim+1,1:1]
    if ini 
        for i = 1:it
            c_i = cand[obs[i]]
            for j=i:it
                c_j = cand[obs[j]]
                tv .= c_i
                BLAS.axpy!(-1.0,c_j,tv)
                tv2 .= tv .* Theta
                BLAS.gemm!('T','N',1.0,tv,tv2,0.0,rTr)
                #Ktt[i,j] = Ktt[j,i] = exp(-0.5*tau*sqrt(rTr[1]))
                Ktt[i,j] = Ktt[j,i] = exp(-0.5*tau*rTr[1])
            end
        end
    else
        i = it
        c_i = cand[obs[i]]
        for j=1:it            
            c_j = cand[obs[j]]
            tv .= c_i
            BLAS.axpy!(-1.0,c_j,tv)
            tv2 .= tv .* Theta
            BLAS.gemm!('T','N',1.0,tv,tv2,0.0,rTr)
            Ktt[i,j] = Ktt[j,i] = exp(-0.5*tau*rTr[1])
            #Ktt[i,j] = Ktt[j,i] = exp(-0.5*tau*sqrt(rTr[1]))
        end
    end
    ## Calculate Ktt^{-1} 
    Ktinv = @view BOobj.Ktinv[1:it,1:it]
    L = @view BOobj.L[1:it,1:it]
    try
        myCholesky!(Ktt,it,L)
    catch
        println("Theta $Theta")
        for i=1:size(Ktt)[1]
            print_vec("",@view Ktt[i,:])
        end
        exit()
    end
    Linv = inv(L)
    BLAS.gemm!('T','N', 1.0,Linv,Linv,0.0,Ktinv)
    return nothing
end

function calcKtp!(it,xp,BOobj)
    tau = BOobj.pKernel[1]
    Theta = @view BOobj.pKernel[2:end]
    pdim = length(Theta)
    #mTheta = @view BOobj.tMat[1:pdim,1:pdim]
    #mTheta .= 0.0;for i =1:pdim; mTheta[i,i] = Theta[i];end
    Ktp = @view BOobj.Ktp[1:it,1:1]
    tv = @view BOobj.tMat[pdim+1:2*pdim,1:1]
    tv2 = @view BOobj.tMat[2*pdim+1:3*pdim,1:1]
    rTr = @view BOobj.tMat[3*pdim+1:3*pdim+1,1:1]
    obs = BOobj.observed
    cand = BOobj.cand
    for i = 1:it
        c_i = cand[obs[i]]
        tv .= c_i 
        BLAS.axpy!(-1.0,xp,tv)
        tv2 .= tv .* Theta
        #BLAS.gemm!('N','N',1.0,mTheta,tv,0.0,tv2)
        BLAS.gemm!('T','N',1.0,tv,tv2,0.0,rTr)
        Ktp[i] = exp(-0.5*tau*rTr[1])
        #Ktp[i] = exp(-0.5*tau* sqrt(rTr[1]))
    end
end 

function evalcand(it,BOobj,to;epsilon=1.e-6)
    Ktt = @view BOobj.Ktt[1:it,1:it]
    Ktp = @view BOobj.Ktp[1:it,1:1]
    Ktinv = @view BOobj.Ktinv[1:it,1:it]
    tM1 = @view BOobj.tMat[1:1,1:it]
    tM2 = @view BOobj.tMat[2:2,1:1]    
    yt = @view BOobj.yt[1:it]
    unobs = BOobj.unobserved
    cand = BOobj.cand
    fplus = BOobj.acquis[1]
    tau = BOobj.pKernel[1]
    fAs = @view BOobj.acquis[2:1+length(unobs)]
    fAs .= 0.0
    for (n,idx) in enumerate(unobs)
        xp = cand[idx]
        calcKtp!(it,xp,BOobj)
        BLAS.gemm!('T','N',1.0,Ktp,Ktinv,0.0,tM1)       
        BLAS.gemm!('N','N',1.0,tM1,Ktp,0.0,tM2)
        mup = dot(tM1,yt)
        sigma = tau
        try
            sigma = sqrt(tau + epsilon - tM2[1])
        catch   
            Imat = Matrix{Float64}(I,it,it)
            Mat = Ktt*Ktinv
            tnorm = norm(Imat-Mat,Inf)
            println("Theta ",BOobj.Theta)
            println("tau-tM2[1] ",tau-tM2[1], "  tnorm $tnorm")
            if it < 10
                println("Ktt ",isposdef(Ktt))
                for i=1:size(Ktt)[1]
                    print_vec("",@view Ktt[i,:])
                end
                println("Ktinv")
                for i=1:size(Ktinv)[1]
                    print_vec("",@view Ktinv[i,:])
                end
                println("Mat")
                for i=1:size(Mat)[1]
                    print_vec("",@view Mat[i,:])
                end
                println("Ktp \n$Ktp")
            end
            exit()
        end
        Z = (mup-fplus) / sigma
        fAs[n] = Z*sigma * fPhi(Z) + exp(-0.5*Z^2)/sqrt(2.0*pi)
    end 
    return nothing
end

function propose!(it,BOobj,BOproposal)
    params = BOobj.params
    cand = BOobj.cand
    #println("scaled_plan size ",size(scaled_plan), "\n$scaled_plan")
    obs = BOobj.observed
    unobs = BOobj.unobserved
    idx = 0
    if BOproposal == false
        tidx = sample(1:length(unobs))
    else
        tidx = find_max_acquisition(it,BOobj)
    end 
    idx = unobs[tidx]
    deleteat!(unobs,tidx)    
    push!(obs,idx)
    params .= cand[idx]
    return nothing
end 

# function showBOhist(itnum,BOobj,targetLECs)
#     history = @view BOobj.history[1:itnum]
#     Data = @view BOobj.Data[1:itnum]
#     logpriors = [history[i][1] for i =1:itnum]
#     logllhs = [history[i][2] for i =1:itnum]
#     logposts = [history[i][3] for i =1:itnum]

#     Ktt = @view BOobj.Ktt[1:itnum,1:itnum]

#     fig = plt.figure(figsize=(6,6))
#     axs = [fig.add_subplot(111)]
#     axs[1].imshow(Ktt)
#     plt.savefig("pic/checkBayesOpt_$itnum.pdf",pad_inches=0)
#     plt.close()
     
#     fig = plt.figure(figsize=(8,8))
#     ax = fig.add_subplot(111)
#     ax.plot(logpriors,label="logprior",alpha=0.6)
#     ax.plot(logllhs,label="loglllh",alpha=0.6)
#     ax.plot(logposts,label="logprior",alpha=0.6)
#     ax.legend()
#     plt.savefig("pic/history_BayesOpt _$itnum.pdf",pad_inches=0)
#     plt.close()

#     paramdat = [zeros(Float64,itnum) for i =1:5]
#     for (i,tmp) in enumerate(Data)
#         for n =1:5
#             paramdat[n][i] = tmp[n]
#         end
#     end
#     fig = plt.figure(figsize=(8,8))
#     ax = fig.add_subplot(111) 
#     for (n,tlabel) in enumerate(targetLECs)
#         ax.plot(paramdat[n],label=tlabel,alpha=0.6)
#     end
#     ax.legend() 
#     plt.savefig("pic/params_BayesOpt _$itnum.pdf",pad_inches=0)
#     plt.close()
# end 


# function showBOhist_plots(itnum,BOobj,targetLECs)
#     history = @view BOobj.history[1:itnum]
#     Data = @view BOobj.Data[1:itnum]
#     logpriors = [history[i][1] for i =1:itnum]
#     logllhs = [history[i][2] for i =1:itnum]
#     logposts = [history[i][3] for i =1:itnum]
     
#     plot(logpriors,label="logprior",alpha=0.6)
#     ax.plot(logllhs,label="loglllh",alpha=0.6)
#     ax.plot(logposts,label="logprior",alpha=0.6)
#     ax.legend()
#     plt.savefig("pic/history_BayesOpt _$itnum.pdf",pad_inches=0)
#     plt.close()

#     paramdat = [zeros(Float64,itnum) for i =1:5]
#     for (i,tmp) in enumerate(Data)
#         for n =1:5
#             paramdat[n][i] = tmp[n]
#         end
#     end
#     fig = plt.figure(figsize=(8,8))
#     ax = fig.add_subplot(111) 
#     for (n,tlabel) in enumerate(targetLECs)
#         ax.plot(paramdat[n],label=tlabel,alpha=0.6)
#     end
#     ax.legend() 
#     plt.savefig("pic/params_BayesOpt _$itnum.pdf",pad_inches=0)
#     plt.close()
# end 

function plotKernel(it,Ktt)
    fig = plt.figure(figsize=(8,8))
    axs = [fig.add_subplot(111)]
    axs[1].imshow(@view Ktt[1:it,1:it])
    plt.savefig("pic/checkBayesOpt_$it.pdf",pad_inches=0)
    plt.close()
end

function find_max_acquisition(it,BOobj)
    unobs = BOobj.unobserved
    fAs = @view BOobj.acquis[2:1+length(unobs)]
    idx = argmax(fAs)
    BOobj.acquis[1] = fAs[idx] #overwrite fplus
    return idx
end 

function printBOhist(BOobj,it)
    hist = BOobj.history
    print_vec("it = $it prior/lh/post ", hist[it])
    return nothing
end

function fPhi(Z)
    return  0.5 * erfc(-(Z/sqrt(2.0)))
end

function AcquisitionFunc(mup,Sp,fplus,fAs)
    for i = 1:length(mup)
        sigma = sqrt(Sp[i,i])
        Z = (mup[i]-fplus) / sigma
        fAs[i] = Z*sigma * fPhi(Z) + exp(-0.5*Z^2)/sqrt(2.0*pi)
    end
    return nothing
end

# function kRBF(xi,xj,params)
#     tau = params[0]; sigma = params[1]
#     return -0.5*tau * ((xi-xj)/sigma)^2
# end 

# function kARD(vi,vj,params)
#     tau = params[0]; sigma = params[1]
#     return -0.5*tau * ((xi-xj)/sigma)^2
# end 
