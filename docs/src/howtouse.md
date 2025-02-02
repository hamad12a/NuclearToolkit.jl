# How to use NuclearToolkit.jl

In this page, we explain the main interfaces of NuclearToolkit.jl with sample codes.

## Generate Chiral EFT potentials

The [ChiEFTint](../ChiEFTint) subblock provides the codes to generate nucleon-nucleon (NN) potentials from Chiral effective field theory. You can specify the options through `optional_parameters.jl`, if it exists in the working directory.
A sample of `optional_parameters.jl` is available on the [repository](https://github.com/SotaYoshida/NuclearToolkit.jl), and see the [Optional parameters](../parameters) page for more details.

The main API is `make_chiEFTint()` and the sample code is given below.
```julia
using NuclearToolkit
#1). generate NN interaction file in snt or snt.bin format
make_chiEFTint()

#2). 1). & showing how much time and memory has been used
make_chiEFTint(;is_show=true)

#3). You can specify the parameters for ChiEFTint through the optional argument `fn_params`
make_chiEFTint(;is_show=true,fn_params="myparam.jl")

#4). You don't need to write out the snt/snt.bin file, but want to calibrate or sample the LECs in the 3NF using HFMBPT.
#    You have to specify the number of itertions, target nuclei, optimizer:
make_chiEFTint(;itnum=5,nucs=["O16"],optimizer="MCMC")
```

### Working on a super-computer

You can also run Julia codes on a super-computer.
Pkg (Julia's builtin package manager) intalls the Julia packages in `$JULIA_DEPOT_PATH`, which is `~/.julia` by default.
When working on a working node (w/o permissions to access `~/`), overwrite the `JULIA_DEPOT_PATH` by `export JULIA_DEPOT_PATH="PATH_TO_JULIA_DEPOT"`.

!!! note  
    For now, utilizing MPI is limited to LECs calibration with HF-MBPT & MCMC. One cannot benefit from many-node parallelization for most of many-body methods in the package. If you have feature requests on it or are willing to contribute along this line, please make an issue.

In NuclearToolkit.jl, many-nodes calculation utilizing MPI.jl is supported for LECs calibration with HF-MBPT.
A sample script for that, let's call `mpisample.jl`, can be something like
```julia
using NuclearToolkit
make_chiEFTint(;itnum=500,nucs=["O16"],optimizer="MCMC",MPIcomm=true)
```

Then, you can run with, e.g., 20 nodes:
```
mpirun -np 20 PATH_TO_JULIA/julia mpisample.jl
```


## HF-MBPT calculations 

You can evaluate ground state properties by the so-called Hartree-Fock many-body perturbation theory (HF-MBPT). The `hf_main` function in [HartreeFock](../HartreeFock) is the main interface.

You must specify target nuclei, snt file (generated by chiEFTint), harmonic oscillator parameter `hw`, model space size `emax`.

```julia
using NuclearToolkit
hw = 20; emax=4
sntf = "path_to_your.snt"
#1). you can evaluate HF-MBPT(3) estimate of g.s. energy of the target nuclus
nucs = ["O16","Ca40"]
hf_main(nucs,sntf,hw,emax)

#2). nucs can be both string and [Z,N] array
nucs = [ [8,8], [20,20]]
hf_main(nucs,sntf,hw,emax)

#3). specify Rp2 operators if you need
nucs = ["O16","Ca40"]
hf_main(nucs,sntf,hw,emax;Operators=["Rp2"])
```

## IMSRG calculations 

One can perform in-medium similarity renormalization group (IM-SRG) calculations by specifing the optional argument `doIMSRG=true`:
```julia
using NuclearToolkit
hw = 20; emax=4
nucs = ["He4","O16"]
sntf = "path_to_your.snt"
hf_main(nucs,sntf,hw,emax;doIMSRG=true,Operators=["Rp2"])
```

Since the IM-SRG is one of the post-HF methods, it uses the same interface for HF(-MBPT).


## VS-IMSRG calculations 

You can also perform valence-space IMSRG (VS-IMSRG) decoupling to derive shell-model interactions for a target model space.
The API is similar to the IMSRG case, but you must specify `core`, `ref`, and `vspace`.

```julia
using NuclearToolkit
hw = 20; emax=4
core = "O16"; vspace="sd-shell", ref="core"
nucs = ["Mg24"]
sntf = "path_to_your.snt"

#1). derivation of sd-shell interaction on top of the 16O core w/o target/ensemble normal ordering
hf_main(nucs,sntf,hw,emax;doIMSRG=true,corenuc=core,ref="core",valencespace=vspace)

#2). derivation of sd-shell interaction on top of the 16O core w/ target/ensemble normal ordering
nucs = ["Mg24"]
hf_main(nucs,sntf,hw,emax;doIMSRG=true,corenuc=core,ref="nucl",valencespace=vspace)
```

The output of VS-IMSRG is always in ".snt" format, which can be used in shell-model part of the package or [KSHELL](https://sites.google.com/alumni.tsukuba.ac.jp/kshell-nuclear/).

## valence shell-model calculations 

You need to specify the effective interaction (in snt format), number of eigenvalues, and target total J
to perform shell-model calculations.

```julia
using NuclearToolkit
hw = 20; emax=4;
vs_sntf = "vsimsrg_sd-shell_coreO16refO16_O16_hw20e4_Delta0.0.snt"
n_eigen=10
targetJ=[]

#1). 10 lowest states
main_sm(vs_sntf,"Mg24",n_eigen,targetJ)

#2). 10 lowest states with J = 0
targetJ = [0]
main_sm(vs_sntf,"Mg24",n_eigen,targetJ)
```

The codes are rather optimized to repeat smaller calculations (up to 48Cr on the pf shell) iteratively,
(i.e., memory-hogging compared to other shell-model codes).
For nuclei in a larger model space than the pf shell, it is recommended to use the [KSHELL](https://sites.google.com/alumni.tsukuba.ac.jp/kshell-nuclear/) by Prof. Noritaka Shimizu.