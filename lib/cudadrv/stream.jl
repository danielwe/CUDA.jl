# Stream management

export
    CuStream, default_stream, legacy_stream, per_thread_stream,
    priority, priority_range, synchronize, device_synchronize

"""
    CuStream(; flags=STREAM_DEFAULT, priority=nothing)

Create a CUDA stream.
"""
mutable struct CuStream
    handle::CUstream
    ctx::Union{CuContext,Nothing}

    function CuStream(; flags::CUstream_flags=STREAM_DEFAULT,
                        priority::Union{Nothing,Integer}=nothing)
        handle_ref = Ref{CUstream}()
        if priority === nothing
            cuStreamCreate(handle_ref, flags)
        else
            priority in priority_range() || throw(ArgumentError("Priority is out of range"))
            cuStreamCreateWithPriority(handle_ref, flags, priority)
        end

        ctx = current_context()
        obj = new(handle_ref[], ctx)
        finalizer(unsafe_destroy!, obj)
        return obj
    end

    global default_stream() = new(convert(CUstream, C_NULL), nothing)

    global legacy_stream() = new(convert(CUstream, 1), nothing)

    global per_thread_stream() = new(convert(CUstream, 2), nothing)
end

"""
    default_stream()

Return the default stream.

!!! note

    It is generally better to use `stream()` to get a stream object that's local to the
    current task. That way, operations scheduled in other tasks can overlap.
"""
default_stream()

"""
    legacy_stream()

Return a special object to use use an implicit stream with legacy synchronization behavior.

You can use this stream to perform operations that should block on all streams (with the
exception of streams created with `STREAM_NON_BLOCKING`). This matches the old pre-CUDA 7
global stream behavior.
"""
legacy_stream()

"""
    per_thread_stream()

Return a special object to use an implicit stream with per-thread synchronization behavior.
This stream object is normally meant to be used with APIs that do not have per-thread
versions of their APIs (i.e. without a `ptsz` or `ptds` suffix).

!!! note

    It is generally not needed to use this type of stream. With CUDA.jl, each task already
    gets its own non-blocking stream, and multithreading in Julia is typically
    accomplished using tasks.
"""
per_thread_stream()

Base.unsafe_convert(::Type{CUstream}, s::CuStream) = s.handle

Base.:(==)(a::CuStream, b::CuStream) = a.handle == b.handle
Base.hash(s::CuStream, h::UInt) = hash(s.handle, h)

@enum_without_prefix CUstream_flags_enum CU_

function unsafe_destroy!(s::CuStream)
    context!(s.ctx; skip_destroyed=true) do
        cuStreamDestroy_v2(s)
    end
end

function Base.show(io::IO, stream::CuStream)
    print(io, "CuStream(")
    @printf(io, "%p", stream.handle)
    print(io, ", ", stream.ctx, ")")
end

"""
    isdone(s::CuStream)

Return `false` if a stream is busy (has task running or queued)
and `true` if that stream is free.
"""
function isdone(s::CuStream)
    res = unsafe_cuStreamQuery(s)
    if res == ERROR_NOT_READY
        return false
    elseif res == SUCCESS
        return true
    else
        throw_api_error(res)
    end
end

"""
    synchronize([stream::CuStream])

Wait until `stream` has finished executing, with `stream` defaulting to the stream
associated with the current Julia task.

See also: [`device_synchronize`](@ref)
"""
function synchronize(stream::CuStream=stream(); blocking=nothing)
    if blocking !== nothing
        Base.depwarn("the blocking keyword to synchronize() has been deprecated", :synchronize)
    end

    # perform as much of the sync as possible without blocking in CUDA.
    # XXX: remove this using a yield callback, or by synchronizing on a dedicated stream?
    nonblocking_synchronize(stream)

    # even though the GPU should be idle now, CUDA hooks work to the actual API call.
    # see NVIDIA bug #3383169 for more details.
    cuStreamSynchronize(stream)

    check_exceptions()
end

@inline function nonblocking_synchronize(stream::CuStream)
    # fast path
    isdone(stream) && return

    # minimize latency of short operations by busy-waiting,
    # initially without even yielding to other tasks
    spins = 0
    while spins < 256
        if spins < 32
            ccall(:jl_cpu_pause, Cvoid, ())
            # Temporary solution before we have gc transition support in codegen.
            ccall(:jl_gc_safepoint, Cvoid, ())
        else
            yield()
        end
        isdone(stream) && return
        spins += 1
    end

    # minimize CPU usage of long-running kernels by waiting for an event signalled by CUDA
    event = Base.Event()
    launch(; stream) do
        notify(event)
    end
    # if an error occurs, the callback may never fire, so use a timer to detect such cases
    dev = device()
    timer = Timer(0; interval=1)
    Base.@sync begin
        Threads.@spawn try
            device!(dev)
            while true
                try
                    Base.wait(timer)
                catch err
                    err isa EOFError && break
                    rethrow()
                end
                if unsafe_cuStreamQuery(stream) != ERROR_NOT_READY
                    break
                end
            end
        finally
            notify(event)
        end

        Threads.@spawn begin
            Base.wait(event)
            close(timer)
        end
    end

    return
end

"""
    priority_range()

Return the valid range of stream priorities as a `StepRange` (with step size  1). The lower
bound of the range denotes the least priority (typically 0), with the upper bound
representing the greatest possible priority (typically -1).
"""
function priority_range()
    least_ref = Ref{Cint}()
    greatest_ref = Ref{Cint}()
    cuCtxGetStreamPriorityRange(least_ref, greatest_ref)
    step = least_ref[] < greatest_ref[] ? 1 : -1
    return least_ref[]:Cint(step):greatest_ref[]
end


"""
    priority_range(s::CuStream)

Return the priority of a stream `s`.
"""
function priority(s::CuStream)
    priority_ref = Ref{Cint}()
    cuStreamGetPriority(s, priority_ref)
    return priority_ref[]
end
