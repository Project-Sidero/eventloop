module sidero.eventloop.threads.osthread;
import sidero.eventloop.handles;
import sidero.base.errors;
import sidero.base.datetime.duration;

// https://idea.popcount.org/2017-02-20-epoll-is-fundamentally-broken-12/ EPOLLONESHOT EPOLLEXCLUSIVE
// https://idea.popcount.org/2017-03-20-epoll-is-fundamentally-broken-22/

///
enum ThreadHandleIdentifier = SystemHandleType.from("thread");

enum {
    ///
    EarlyThreadReturnException = ErrorMessage("ETRE", "Thread result returned early"),
}

///
struct Thread {
    private {
        import core.atomic : atomicOp;

        State* state;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref Thread other) scope @trusted {
        this.tupleof = other.tupleof;

        if (this.state !is null)
            atomicOp!"+="(state.refCount, 1);
    }

    ///
    ~this() scope @trusted {
        if (this.state !is null && atomicOp!"-="(state.refCount, 1) == 0 && !this.isRunning) {
            externalDetach;

            mutex.pureLock;
            allThreads.remove(state.handle.handle);

            if (state.owns) {
                // destroy handle (not needed with pthreads)

                version (Windows) {
                    import core.sys.windows.winbase : CloseHandle;
                    import core.sys.windows.basetsd : HANDLE;

                    auto success = CloseHandle(cast(HANDLE)state.handle.handle);
                }
            }

            threadAllocator.deallocate((cast(void*)state)[0 .. State.sizeof]);
            mutex.unlock;
        }
    }

    ///
    bool isNull() scope const {
        return state is null;
    }

    ///
    bool isRunning() scope const @trusted {
        if (isNull)
            return false;

        version(Windows) {
            import core.sys.windows.windows : HANDLE, GetExitCodeThread, STILL_ACTIVE;
            uint result;
            if (GetExitCodeThread(cast(HANDLE)state.handle.handle, &result) == STILL_ACTIVE)
                return true;
        } else version(Posix) {
            import core.sys.posix.pthread : pthread_tryjoin_np, pthread_t;
            // ok this is almost certainly wrong... sigh
            if (pthread_tryjoin_np(cast(pthread_t)state.handle.handle, null) == 0)
                return true;
        }

        return false;
    }

    ///
    static Result!Thread create(Args...)(size_t stackSize, void function(Args) nothrow entryFunction, Args args) @trusted {
        mutex.pureLock;

        void[] memory = threadAllocator.allocate(Thread.State.sizeof);
        assert(memory.length == Thread.State.sizeof);

        Thread.State* state = cast(Thread.State*)(memory.ptr);
        *state = Thread.State.init;
        state.entry = cast(void*)entryFunction;

        EntryFunctionArgs!Args* efa;
        void[] efaMemory;

        {
            efaMemory = threadAllocator.allocate(EntryFunctionArgs!Args.sizeof);
            assert(efaMemory.length == EntryFunctionArgs!Args.sizeof);
            state.args = efaMemory.ptr;

            efa = cast(EntryFunctionArgs!Args*)state.args;
            efa.args = args;
        }

        void cleanup() {
            efa.destroy;
            state.destroy;

            threadAllocator.deallocate(memory);
            threadAllocator.deallocate(efaMemory);
            mutex.unlock;
        }

        version (Windows) {
            import core.sys.windows.windows : CreateThread;

            auto handle = CreateThread(null, stackSize, &start_routine!(EntryFunctionArgs!Args), state, 0, null);
            if (handle is null) {
                cleanup;
                return typeof(return)(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
            }
        } else version (Posix) {
            import core.sys.posix.pthread : pthread_create, pthread_t, pthread_attr_t, pthread_attr_init,
                pthread_attr_destroy, pthread_attr_setstacksize;

            int s;
            pthread_attr_t attr;

            s = pthread_attr_init(&attr);
            if (s != 0) {
                cleanup;
                return typeof(return)(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
            }
            s = pthread_attr_setstacksize(&attr, stackSize);
            if (s != 0) {
                cleanup;
                return typeof(return)(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
            }

            pthread_t handle;
            s = pthread_create(&handle, attr, &start_routine!(EntryFunctionArgs!Args), cast(void*)state);
            s |= pthread_attr_destroy(&attr);
            if (s != 0) {
                cleanup;
                return typeof(return)(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
            }
        }

        state.handle = SystemHandle(cast(void*)handle, ThreadHandleIdentifier);

        Thread ret;
        ret.state = state;
        ret.__ctor(ret);
        return ret;
    }

    ///
    static void yield() {
        // sched_yield
        // SwitchToThread
        assert(0);
    }

    ///
    static void sleep(Duration minimum) {
        // nanosleep
        // SleepEx
        assert(0);
    }

    ///
    static Thread self() @trusted {
        mutex.pureLock;

        version (Windows) {
            import core.sys.windows.winbase : GetCurrentThread;
            import core.sys.windows.basetsd : HANDLE;

            HANDLE handle = GetCurrentThread();
        } else version (Posix) {
            import core.sys.posix.pthread : pthread_self, pthread_t;

            pthread_t handle = pthread_self();
        } else
            static assert(0, "Unimplemented platform");

        {
            auto ifExists = allThreads.get(cast(void*)handle, null);

            if (ifExists) {
                Thread ret;
                ret.state = ifExists.get;
                ret.__ctor(ret);

                mutex.unlock;
                return ret;
            }
        }

        {
            void[] memory = threadAllocator.allocate(Thread.State.sizeof);
            assert(memory.length == Thread.State.sizeof);

            Thread.State* state = cast(Thread.State*)(memory.ptr);
            *state = Thread.State.init;

            state.handle = SystemHandle(cast(void*)handle, ThreadHandleIdentifier);

            Thread ret;
            ret.state = state;
            ret.__ctor(ret);

            mutex.unlock;
            return ret;
        }
    }

    ///
    ErrorResult join(Duration timeout = Duration.max) scope const @trusted {
        if (isNull)
            return ErrorResult(NullPointerException);
        else if (timeout <= Duration.init)
            return ErrorResult(MalformedInputException("Timeout duration must be above zero"));

        version (Windows) {
            import core.sys.windows.windows : HANDLE, WaitForSingleObjectEx, WAIT_ABANDONED, WAIT_IO_COMPLETION,
                WAIT_OBJECT_0, WAIT_TIMEOUT, WAIT_FAILED;

            auto result = WaitForSingleObjectEx(cast(HANDLE)state.handle.handle, cast(uint)timeout.totalMilliSeconds(), true);

            switch (result) {
            case WAIT_OBJECT_0:
                return ErrorResult.init;

            case WAIT_IO_COMPLETION:
                return ErrorResult(EarlyThreadReturnException("Thread join completed early due APC IO execution"));
            case WAIT_TIMEOUT:
                return ErrorResult(EarlyThreadReturnException("Thread join completed early due to timeout"));

            default:
            case WAIT_ABANDONED:
            case WAIT_FAILED:

                return ErrorResult(UnknownPlatformBehaviorException("Thread failed to join for an unknown reason"));
            }
        } else version (Posix) {
            import core.sys.posix.pthread : pthread_timedjoin_np;
            import core.sys.posix.time : clock_gettime, CLOCK_REALTIME;
            import core.stdc.time : timespec;

            long secs = timeout.totalSeconds();
            long nsecs = (timeout - secs.seconds()).totalNanoSeconds();

            timespec ts;
            if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
                return ErrorResult(UnknownPlatformBehaviorException("Could not get time to compute timeout for thread join"));

            ts.tv_sec += secs;
            ts.tv_nsec += nsecs;

            int s = pthread_timedjoin_np(state.handle.handle, null, ts);
            if (s != 0)
                return ErrorResult(UnknownPlatformBehaviorException("Thread failed to join for an unknown reason"));
        } else
            static assert(0, "Platform not implemented");
    }

    /// Attaching and detaching of this thread to pin it for other thread systems
    void externalAttach() scope @system {
        if (isNull)
            return;

        if (atomicOp!"+="(state.attachCount, 1) == 1) {
            // tell all external thread registration mechanisms
            onAttachOfThread;
        }
    }

    /// Ditto
    void externalDetach() scope @system {
        if (isNull)
            return;

        if (atomicOp!"-="(state.attachCount, 1) == 0) {
            // tell all external thread registration mechanisms
            onDetachOfThread;
        }
    }

private:
    static struct State {
        shared(ptrdiff_t) refCount, attachCount;
        SystemHandle handle;
        bool owns;

        void* entry, args;
    }
}

private:
import sidero.eventloop.threads.registration;
import sidero.base.allocators.predefined;
import sidero.base.parallelism.mutualexclusion;
import sidero.base.containers.map.hashmap;

__gshared {
    TestTestSetLockInline mutex;
    HashMap!(void*, Thread.State*) allThreads;
    HouseKeepingAllocator!() threadAllocator;
}

struct EntryFunctionArgs(Args...) {
    Args args;
}

version (Windows) {
    import core.sys.windows.windows : DWORD;

    extern (Windows) DWORD start_routine(EFA : EntryFunctionArgs!FunctionArgs, FunctionArgs...)(void* state) {
        Thread self;
        self.state = cast(Thread.State*)state;
        self.__ctor(self);

        EFA efa = *cast(EFA*)self.state.args;
        allThreads[self.state.handle.handle] = self.state;

        mutex.unlock;

        self.externalAttach;
        (cast(void function(FunctionArgs)nothrow)self.state.entry)(efa.args);
        return 0;
    }
} else version (Posix) {
    // our start routine
    extern (C) void* start_routine(EFA : EntryFunctionArgs!FunctionArgs, FunctionArgs...)(void* state) {
        assert(state !is null);
        Thread self;
        self.state = state;
        self.__ctor(self);

        EFA efa = *cast(EFA*)self.state.args;
        allThreads[self.state.handle.handle] = self.state;

        mutex.unlock;

        self.externalAttach;
        (cast(void function(FunctionArgs)nothrow)self.state.entry)(efa.args);
        return null;
    }
}

unittest {
    import core.atomic;

    shared(int) counter;
    shared(bool) goForIt;

    Thread[10] threads;

    static void handleIt(shared(int)* counter, shared(bool)* goForIt) nothrow {
        while (!atomicLoad(goForIt)) {
            pause;
        }

        atomicOp!"+="(*counter, 1);
    }

    foreach (ref thread; threads) {
        auto got = Thread.create(0, &handleIt, &counter, &goForIt);
        assert(got);
        thread = got.get;
    }

    atomicStore(goForIt, true);

    foreach (ref thread; threads) {
        thread.join;
    }

    assert(atomicLoad(counter) == 10);
}
