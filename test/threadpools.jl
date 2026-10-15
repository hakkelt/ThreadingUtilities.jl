@testset "Tasks are pinned to default-pool threads" begin
  @test length(ThreadingUtilities.THREADIDS) == length(ThreadingUtilities.TASKS)
  @test allunique(ThreadingUtilities.THREADIDS)
  # `THREADIDS` is 0-based; thread 1 (the main thread) is never used
  @test all(>(0), ThreadingUtilities.THREADIDS)
  @static if isdefined(Threads, :threadpooltids)
    @test all(tid -> Threads.threadpool(tid + 1) === :default, ThreadingUtilities.THREADIDS)
  end
end

# A task that never yields on an interactive thread (as test-runner watchdogs do) must not
# keep `launch`ed work from running. Before tasks were pinned by pool, the task for index 1
# sat on thread 2, which with `--threads=N,2` on Julia 1.12+ is an interactive thread.
@static if VERSION >= v"1.12-"
  @testset "A busy interactive thread does not starve the tasks" begin
    script = """
    using ThreadingUtilities
    function done!(p::Ptr{UInt})
      ThreadingUtilities._atomic_store!(p, ThreadingUtilities.SPIN)
      return nothing
    end
    setup!(p) = ThreadingUtilities.store!(p, @cfunction(done!, Cvoid, (Ptr{UInt},)), sizeof(UInt))
    stop = Threads.Atomic{Bool}(false)
    busy = Task() do
      while !stop[]
        Libc.systemsleep(0.01)
        GC.safepoint()
      end
    end
    busy.sticky = true
    ccall(:jl_set_task_tid, Cvoid, (Any, Cint), busy, 1) # thread 2, interactive
    schedule(busy)
    t = @async for tid in eachindex(ThreadingUtilities.TASKS)
      ThreadingUtilities.launch(setup!, tid)
      ThreadingUtilities.wait(tid)
    end
    deadline = time() + 30
    while !istaskdone(t) && time() < deadline
      sleep(0.05)
    end
    print(Threads.threadpool(2), " ", length(ThreadingUtilities.TASKS), " ", istaskdone(t) && !istaskfailed(t))
    stop[] = true
    exit(0)
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no --threads=3,2 --project=$(Base.active_project()) -e $script`
    pool, ntasks, done = split(readchomp(cmd))
    @test pool == "interactive"
    @test ntasks == "2"
    @test done == "true"
  end
end
