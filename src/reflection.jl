# code reflection entry-points

using InteractiveUtils

using .CUPTI: CUpti_CallbackDomain, CUpti_CallbackId, CUpti_SubscriberHandle,
              CUpti_ResourceData, CUpti_ModuleResourceData


# return the capability of the current context's device, or a sane fall-back
# only use this within reflection; just use `capability(device())` otherwise
function current_capability()
    if CuCurrentContext() !== nothing
        return supported_capability(device())
    else
        # newer devices tend to support cleaner code (higher-level instructions, etc)
        # so target the most recent device as supported by this toolchain
        return maximum(target_support())
    end
end


#
# code_* replacements
#

# NOTE: these functions replicate parts of the main compiler driver in order to generate
#       more compact code (i.e. without the run-time library) and/or to support generating
#       otherwise invalid code (e.g. with missing symbols).

"""
    code_llvm([io], f, types; optimize=true, cap::VersionNumber, kernel=false,
              optimize=true, raw=false, dump_module=false, strict=false)

Prints the device LLVM IR generated for the method matching the given generic function and
type signature to `io` which defaults to `stdout`.

The following keyword arguments are supported:

- `cap` which device to generate code for
- `kernel`: treat the function as an entry-point kernel
- `optimize`: determines if the code is optimized, which includes kernel-specific
  optimizations if `kernel` is true
- `raw`: return the raw IR including all metadata
- `dump_module`: display the entire module instead of just the function
- `strict`: verify generate code as early as possible

See also: [`@device_code_llvm`](@ref), InteractiveUtils.code_llvm
"""
function code_llvm(io::IO, @nospecialize(func), @nospecialize(types);
                   cap::VersionNumber=current_capability(), kernel::Bool=false,
                   optimize::Bool=true, raw::Bool=false, debuginfo::Symbol=:default,
                   dump_module::Bool=false, strict::Bool=false, kwargs...)
    tt = Base.to_tuple_type(types)
    job = CompilerJob(func, tt, cap, kernel; kwargs...)
    code_llvm(io, job; optimize=optimize, raw=raw, debuginfo=debuginfo,
              dump_module=dump_module, strict=strict)
end
function code_llvm(io::IO, job::CompilerJob; optimize::Bool=true, raw::Bool=false,
                   debuginfo::Symbol=:default, dump_module::Bool=false, strict::Bool=false)
    # NOTE: jl_dump_function_ir supports stripping metadata, so don't do it in the driver
    ir, entry = codegen(:llvm, job; optimize=optimize, strip=false, strict=strict)
    str = ccall(:jl_dump_function_ir, Ref{String},
                (Ptr{Cvoid}, Bool, Bool, Ptr{UInt8}),
                LLVM.ref(entry), !raw, dump_module, debuginfo)
    print(io, str)
end
code_llvm(@nospecialize(func), @nospecialize(types); kwargs...) =
    code_llvm(stdout, func, types; kwargs...)

"""
    code_ptx([io], f, types; cap::VersionNumber, kernel=false, raw=false, strict=false)

Prints the PTX assembly generated for the method matching the given generic function and
type signature to `io` which defaults to `stdout`.

The following keyword arguments are supported:

- `cap` which device to generate code for
- `kernel`: treat the function as an entry-point kernel
- `raw`: return the raw code including all metadata
- `strict`: verify generate code as early as possible

See also: [`@device_code_ptx`](@ref)
"""
function code_ptx(io::IO, @nospecialize(func), @nospecialize(types);
                  cap::VersionNumber=current_capability(), kernel::Bool=false,
                  raw::Bool=false, strict::Bool=false, kwargs...)
    tt = Base.to_tuple_type(types)
    job = CompilerJob(func, tt, cap, kernel; kwargs...)
    code_ptx(io, job; raw=raw, strict=strict)
end
function code_ptx(io::IO, job::CompilerJob; raw::Bool=false, strict::Bool=false)
    asm, _ = codegen(:ptx, job; strip=!raw, strict=strict)
    print(io, asm)
end
code_ptx(@nospecialize(func), @nospecialize(types); kwargs...) =
    code_ptx(stdout, func, types; kwargs...)

function code_sass_callback(userdata::Ptr{Cvoid}, domain::CUpti_CallbackDomain,
                            cbid::CUpti_CallbackId, cbdada::Ptr{Cvoid})
    dest = Base.unsafe_pointer_to_objref(userdata)::Ref{Any}

    if domain == CUPTI.CUPTI_CB_DOMAIN_RESOURCE
        cbdada = unsafe_load(reinterpret(Ptr{CUpti_ResourceData}, cbdada))
        if cbid == CUPTI.CUPTI_CBID_RESOURCE_MODULE_LOADED
            resourceDescriptor =
                unsafe_load(reinterpret(Ptr{CUpti_ModuleResourceData}, cbdada.resourceDescriptor))
            cubin = unsafe_wrap(Vector{Cchar}, pointer(resourceDescriptor.pCubin),
                                resourceDescriptor.cubinSize)
            dest[] = copy(cubin)
        end
    end

    return
end

"""
    code_sass([io], f, types, cap::VersionNumber)

Prints the SASS code generated for the method matching the given generic function and type
signature to `io` which defaults to `stdout`.

The following keyword arguments are supported:

- `cap` which device to generate code for
- `kernel`: treat the function as an entry-point kernel
- `verbose`: enable verbose mode, which displays code generation statistics

See also: [`@device_code_sass`](@ref)
"""
function code_sass(io::IO, @nospecialize(func), @nospecialize(types);
                   cap::VersionNumber=current_capability(), kernel::Bool=true,
                   verbose::Bool=false, kwargs...)
    tt = Base.to_tuple_type(types)
    job = CompilerJob(func, tt, cap, kernel; kwargs...)
    code_sass(io, job; verbose=verbose)
end
function code_sass(io::IO, job::CompilerJob; verbose::Bool=false)
    if !job.kernel
        error("Can only generate SASS code for kernel functions")
    end

    ptx, _ = codegen(:ptx, job)

    cubin = Ref{Any}()
    callback = @cfunction(code_sass_callback, Cvoid,
                          (Ptr{Cvoid}, CUpti_CallbackDomain, CUpti_CallbackId, Ptr{Cvoid}))

    # JIT compile and capture the generated object file
    subscriber_ref = Ref{CUpti_SubscriberHandle}()
    CUPTI.cuptiSubscribe(subscriber_ref, callback, Base.pointer_from_objref(cubin))
    subscriber = subscriber_ref[]
    try
        CUPTI.cuptiEnableDomain(1, subscriber, CUPTI.CUPTI_CB_DOMAIN_RESOURCE)
        CuModule(ptx)
    finally
        CUPTI.cuptiUnsubscribe(subscriber)
    end

    # disassemble to SASS
    isassigned(cubin) || error("No kernels compiled")
    mktemp() do cubin_path,cubin_io
        write(cubin_io, cubin[])
        flush(cubin_io)

        cmd = `$(nvdisasm()) --print-code --print-line-info $cubin_path`
        for line in readlines(cmd)
            # nvdisasm output is pretty verbose;
            # perform some clean-up and make it look like @code_native
            line = replace(line, r"/\*[0-9a-f]{4}\*/" => "        ") # strip inst addr
            line = replace(line, r"^[ ]{30}" => "   ")               # reduce leading spaces
            line = replace(line, r"[\s+]//##" => ";")                # change line info tag
            line = replace(line, r"^\." => "\n.")                    # break before new BBs
            line = replace(line, r"; File \"(.+?)\", line (\d+)" => s"; Location \1:\2") # rename line info
            println(io, line)
        end
    end
end
code_sass(@nospecialize(func), @nospecialize(types); kwargs...) =
    code_sass(stdout, func, types; kwargs...)


#
# @device_code_* functions
#

export @device_code_lowered, @device_code_typed, @device_code_warntype,
       @device_code_llvm, @device_code_ptx, @device_code_sass,
       @device_code

function emit_hooked_compilation(inner_hook, ex...)
    user_code = ex[end]
    user_kwargs = ex[1:end-1]
    quote
        # wipe the compile cache to force recompilation
        empty!(CUDAnative.compilecache)

        local kernels = 0
        function outer_hook(job)
            kernels += 1
            $inner_hook(job; $(map(esc, user_kwargs)...))
        end

        if CUDAnative.compile_hook[] != nothing
            error("Chaining multiple @device_code calls is unsupported")
        end
        try
            CUDAnative.compile_hook[] = outer_hook
            $(esc(user_code))
        finally
            CUDAnative.compile_hook[] = nothing
        end

        if kernels == 0
            error("no kernels executed while evaluating the given expression")
        end

        nothing
    end
end

# NOTE: these hooks take both a `f` and an inner `f`, because of how `@cuda`/`_cuda` work:
#       kernels are automatically wrapper in a function returning nothing, for usability.
#
#       Julia-level reflection (lowered/typed/warntype) skips these wrapper, because we
#       can't do call-site inlining and the kernel wrapper would hide any meaningful code.
#
#       at the LLVM level, we inline everything so there's no need to hide the wrapper.

"""
    @device_code_lowered ex

Evaluates the expression `ex` and returns the result of
InteractiveUtils.code_lowered for every compiled CUDA kernel.

See also: InteractiveUtils.@code_lowered
"""
macro device_code_lowered(ex...)
    quote
        buf = Any[]
        function hook(job::CompilerJob)
            append!(buf, code_lowered(job.f, job.tt))
        end
        $(emit_hooked_compilation(:hook, ex...))
        buf
    end
end

"""
    @device_code_typed ex

Evaluates the expression `ex` and returns the result of
InteractiveUtils.code_typed for every compiled CUDA kernel.

See also: InteractiveUtils.@code_typed
"""
macro device_code_typed(ex...)
    quote
        buf = Any[]
        function hook(job::CompilerJob)
            if VERSION >= v"1.1.0"
                append!(buf, code_typed(job.f, job.tt, debuginfo=:source))
            else
                append!(buf, code_typed(job.f, job.tt))
            end
        end
        $(emit_hooked_compilation(:hook, ex...))
        buf
    end
end

"""
    @device_code_warntype [io::IO=stdout] ex

Evaluates the expression `ex` and prints the result of
InteractiveUtils.code_warntype to `io` for every compiled CUDA kernel.

See also: InteractiveUtils.@code_warntype
"""
macro device_code_warntype(ex...)
    function hook(job::CompilerJob; io::IO=stdout, kwargs...)
        code_warntype(io, job.f, job.tt; kwargs...)
    end
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code_llvm [io::IO=stdout, ...] ex

Evaluates the expression `ex` and prints the result of InteractiveUtils.code_llvm
to `io` for every compiled CUDA kernel. For other supported keywords, see
[`CUDAnative.code_llvm`](@ref).

See also: InteractiveUtils.@code_llvm
"""
macro device_code_llvm(ex...)
    hook(job::CompilerJob; io::IO=stdout, kwargs...) = code_llvm(io, job; kwargs...)
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code_ptx [io::IO=stdout, ...] ex

Evaluates the expression `ex` and prints the result of [`CUDAnative.code_ptx`](@ref) to `io`
for every compiled CUDA kernel. For other supported keywords, see
[`CUDAnative.code_ptx`](@ref).
"""
macro device_code_ptx(ex...)
    hook(job::CompilerJob; io::IO=stdout, kwargs...) = code_ptx(io, job; kwargs...)
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code_sass [io::IO=stdout, ...] ex

Evaluates the expression `ex` and prints the result of [`CUDAnative.code_sass`](@ref) to
`io` for every compiled CUDA kernel. For other supported keywords, see
[`CUDAnative.code_sass`](@ref).
"""
macro device_code_sass(ex...)
    hook(job::CompilerJob; io::IO=stdout, kwargs...) = code_sass(io, job; kwargs...)
    emit_hooked_compilation(hook, ex...)
end

"""
    @device_code dir::AbstractString=... [...] ex

Evaluates the expression `ex` and dumps all intermediate forms of code to the directory
`dir`.
"""
macro device_code(ex...)
    only(xs) = (@assert length(xs) == 1; first(xs))
    localUnique = 1
    function hook(job::CompilerJob; dir::AbstractString)
        name = something(job.name, nameof(job.f))
        fn = "$(name)_$(localUnique)"
        mkpath(dir)

        open(joinpath(dir, "$fn.lowered.jl"), "w") do io
            code = only(code_lowered(job.f, job.tt))
            println(io, code)
        end

        open(joinpath(dir, "$fn.typed.jl"), "w") do io
            if VERSION >= v"1.1.0"
                code = only(code_typed(job.f, job.tt, debuginfo=:source))
            else
                code = only(code_typed(job.f, job.tt))
            end
            println(io, code)
        end

        open(joinpath(dir, "$fn.unopt.ll"), "w") do io
            code_llvm(io, job; dump_module=true, raw=true, optimize=false)
        end

        open(joinpath(dir, "$fn.opt.ll"), "w") do io
            code_llvm(io, job; dump_module=true, raw=true)
        end

        open(joinpath(dir, "$fn.ptx"), "w") do io
            code_ptx(io, job)
        end

        open(joinpath(dir, "$fn.sass"), "w") do io
            code_sass(io, job)
        end

        localUnique += 1
    end
    emit_hooked_compilation(hook, ex...)
end
