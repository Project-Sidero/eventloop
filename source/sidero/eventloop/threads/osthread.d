module sidero.eventloop.threads.osthread;
import sidero.eventloop.handles;
import sidero.base.errors;
import sidero.base.datetime.duration;
import sidero.base.internal.atomic;

// https://idea.popcount.org/2017-02-20-epoll-is-fundamentally-broken-12/ EPOLLONESHOT EPOLLEXCLUSIVE
// https://idea.popcount.org/2017-03-20-epoll-is-fundamentally-broken-22/

///
enum ThreadHandleIdentifier = SystemHandleType.from("thread");

///
enum {
    ///
    EarlyThreadReturnException = ErrorMessage("ETRE", "Thread result returned early"),
}

/**
Thread abstraction over an OS thread.

If you need a unique id use the result of toHash.
*/
struct Thread {
    private {
        State* state;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref Thread other) scope @trusted {
        this.tupleof = other.tupleof;

        if (this.state !is null)
            atomicIncrementAndLoad(state.refCount, 1);
    }

    ///
    ~this() scope @trusted {
        if (this.state !is null && atomicDecrementAndLoad(state.refCount, 1) == 0 && !this.isRunning) {
            mutex.lock.assumeOkay;
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

    /// Warning: unsafe, you must handle reference counting and keeping this instance alive
    SystemHandle unsafeGetHandle() @system {
        if (isNull)
            return SystemHandle.init;
        return this.state.handle;
    }

    /// Warning: this only really works right on Windows. On Posix this only will give the right results if it was created by this abstraction.
    bool isRunning() scope const @trusted {
        if (isNull)
            return false;

        version (Windows) {
            import core.sys.windows.windows : HANDLE, STILL_ACTIVE, GetExitCodeThread;

            DWORD exitCode;
            return GetExitCodeThread(cast(HANDLE)state.handle.handle, &exitCode) != 0 && exitCode == STILL_ACTIVE;
        } else version (Posix) {
            return atomicLoad(state.isRunning);
        } else
            static assert(0, "Unimplemented platform");
    }

    ///
    static Result!Thread create(Args...)(void function(Args) nothrow entryFunction, Args args) @trusted {
        // 8mb stack is a very good size regardless of platform, very unlikely to cause problems with code
        return Thread.create(8 * 1024 * 1024, entryFunction, args);
    }

    ///
    static Result!Thread create(Args...)(size_t stackSize, void function(Args) nothrow entryFunction, Args args) @trusted {
        Result!Thread ret;

        accessGlobals((ref mutex, ref allThreads, ref threadAllocator) {
            mutex.lock.assumeOkay;

            void[] memory = threadAllocator.allocate(Thread.State.sizeof);
            assert(memory.length == Thread.State.sizeof);

            Thread.State* state = cast(Thread.State*)(memory.ptr);
            *state = Thread.State.init;
            state.entry = cast(void*)entryFunction;

            Thread retThread;
            retThread.state = state;
            retThread.__ctor(retThread);

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
                (*efa).destroy;
                (*state).destroy;

                retThread.state = null;

                threadAllocator.deallocate(memory);
                threadAllocator.deallocate(efaMemory);
                mutex.unlock;
            }

            version (Windows) {
                import core.sys.windows.windows : CreateThread, CREATE_SUSPENDED, ResumeThread, GetThreadId;

                auto handle = CreateThread(null, stackSize, &start_routine!(EntryFunctionArgs!Args), state, CREATE_SUSPENDED, null);
                if (handle is null) {
                    cleanup;
                    ret = Result!Thread(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
                    return;
                }

                state.handle = SystemHandle(cast(void*)handle, ThreadHandleIdentifier);
                allThreads[cast(void*)GetThreadId(handle)] = state;
                ResumeThread(handle);
            } else version (Posix) {
                import core.sys.posix.pthread : pthread_create, pthread_t, pthread_attr_t, pthread_attr_init,
                    pthread_attr_destroy, pthread_attr_setstacksize;

                int s;
                pthread_attr_t attr;

                s = pthread_attr_init(&attr);
                if (s != 0) {
                    cleanup;
                    ret = Result!Thread(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
                    return;
                }
                s = pthread_attr_setstacksize(&attr, stackSize);
                if (s != 0) {
                    cleanup;
                    ret = Result!Thread(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
                    return;
                }

                pthread_t handle;
                s = pthread_create(&handle, &attr, &start_routine!(EntryFunctionArgs!Args), cast(void*)state);
                s |= pthread_attr_destroy(&attr);
                if (s != 0) {
                    cleanup;
                    ret = Result!Thread(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
                    return;
                }
            }

            ret = Result!Thread(retThread);
        });

        return ret;
    }

    /// Tells the kernel that this thread can wait before continuing its work
    static void yield() @trusted {
        version (Windows) {
            import core.sys.windows.windows : SwitchToThread;

            SwitchToThread();
        } else version (Posix) {
            import core.sys.posix.sched : sched_yield;

            sched_yield();
        }
    }

    ///
    static ErrorResult sleep(Duration timeout) @trusted {
        if (timeout <= Duration.init)
            return ErrorResult(MalformedInputException("Timeout duration must be above zero"));

        version (Windows) {
            import core.sys.windows.windows : SleepEx, WAIT_IO_COMPLETION;

            auto result = SleepEx(cast(uint)timeout.totalMilliSeconds(), true);

            if (result == WAIT_IO_COMPLETION)
                return ErrorResult(EarlyThreadReturnException("Thread sleep completed early due APC IO execution"));
        } else version (Posix) {
            import core.sys.posix.time : timespec, clock_gettime, CLOCK_REALTIME, nanosleep;
            import core.stdc.errno : EINTR, errno;

            long secs = timeout.totalSeconds();
            long nsecs = (timeout - secs.seconds()).totalNanoSeconds();

            timespec ts;
            if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
                return ErrorResult(UnknownPlatformBehaviorException("Could not get time to compute timeout for thread join"));

            ts.tv_sec += secs;
            ts.tv_nsec += nsecs;

            errno = 0;
            auto result = nanosleep(&ts, null);

            if (result != 0) {
                if (errno == EINTR)
                    return ErrorResult(EarlyThreadReturnException("Thread sleep completed early due signal execution"));
                else
                    return ErrorResult(UnknownPlatformBehaviorException("Thread failed to join for an unknown reason"));
            }
        }

        return ErrorResult.init;
    }

    ///
    static Thread self() @trusted {
        version (Windows) {
            import core.sys.windows.windows : GetCurrentThreadId;

            auto lookupKey = GetCurrentThreadId();
        } else version (Posix) {
            import core.sys.posix.pthread : pthread_self, pthread_t;

            pthread_t handle = pthread_self();
            auto lookupKey = handle;
        } else
            static assert(0, "Unimplemented platform");

        {
            auto ifExists = allThreads.get(cast(void*)lookupKey, null);

            if (ifExists) {
                Thread ret;
                ret.state = ifExists.get;
                ret.__ctor(ret);
                return ret;
            }
        }

        {
            mutex.lock.assumeOkay;

            version (Windows) {
                import core.sys.windows.windows : GetCurrentProcess, DUPLICATE_CLOSE_SOURCE, DUPLICATE_SAME_ACCESS,
                    FALSE, HANDLE, GetCurrentThread, DuplicateHandle;

                HANDLE handle = GetCurrentThread();
                DuplicateHandle(GetCurrentProcess(), handle, null, &handle, 0, FALSE, DUPLICATE_CLOSE_SOURCE | DUPLICATE_SAME_ACCESS);
            }

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
    ErrorResult join(Duration timeout = Duration.min) scope const @trusted {
        if (isNull)
            return ErrorResult(NullPointerException);

        if (!isRunning)
            return ErrorResult.init;

        const block = timeout < Duration.zero;

        version (Windows) {
            import core.sys.windows.windows : HANDLE, WaitForMultipleObjectsEx, WAIT_ABANDONED, WAIT_IO_COMPLETION,
                WAIT_OBJECT_0, WAIT_TIMEOUT, WAIT_FAILED, INFINITE;

            DWORD dwTimeout = block ? INFINITE : cast(uint)timeout.totalMilliSeconds();

            HANDLE handles = cast(HANDLE)state.handle.handle;
            auto result = WaitForMultipleObjectsEx(1, &handles, false, dwTimeout, true);

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
            import core.sys.posix.pthread : pthread_join;
            import core.sys.posix.time : clock_gettime, CLOCK_REALTIME;

            if (timeout >= Duration.zero) {
                long secs = timeout.totalSeconds();
                long nsecs = (timeout - secs.seconds()).totalNanoSeconds();

                timespec ts;
                if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
                    return ErrorResult(UnknownPlatformBehaviorException("Could not get time to compute timeout for thread join"));

                ts.tv_sec += secs;
                ts.tv_nsec += nsecs;

                int s = pthread_timedjoin_np(cast(pthread_t)state.handle.handle, null, &ts);
                if (s != 0)
                    return ErrorResult(UnknownPlatformBehaviorException("Thread failed to join for an unknown reason"));
            } else {
                return waitForJoin(cast(void*)state.handle.handle);
            }

            return ErrorResult.init;
        } else
            static assert(0, "Platform not implemented");
    }

    /// Attaching and detaching of this thread to pin it for other thread systems
    void externalAttach() scope @system {
        if (isNull)
            return;

        if (atomicIncrementAndLoad(state.attachCount, 1) == 1) {
            // tell all external thread registration mechanisms
            onAttachOfThread;
        }
    }

    /// Ditto
    void externalDetach() scope @system {
        if (isNull)
            return;

        if (atomicDecrementAndLoad(state.attachCount, 1) == 0) {
            // tell all external thread registration mechanisms
            onDetachOfThread;
        }
    }

    ///
    bool opEquals(scope const Thread other) scope const {
        return this.state is other.state;
    }

    ///
    int opCmp(scope const Thread other) scope const {
        if (cast(size_t)this.state < cast(size_t)other.state)
            return -1;
        else if (cast(size_t)this.state > cast(size_t)other.state)
            return 1;
        else
            return 0;
    }

    /// A unique id, not the system handle.
    ulong toHash() scope const {
        return cast(size_t)state;
    }

private:
    static struct State {
        shared(ptrdiff_t) refCount, attachCount;
        SystemHandle handle;
        bool owns;
        shared(bool) isRunning;

        void* entry, args;
    }
}

private:
import sidero.eventloop.threads.registration;
import sidero.eventloop.synchronization.system.lock;
import sidero.base.allocators.predefined;
import sidero.base.containers.map.hashmap;

__gshared {
    SystemLock mutex;
    HashMap!(void*, Thread.State*) allThreads;
    HouseKeepingAllocator!() threadAllocator;
}

export void accessGlobals(scope void delegate(ref SystemLock mutex, ref HashMap!(void*, Thread.State*) allThreads,
        ref HouseKeepingAllocator!() threadAllocator) nothrow @nogc del) nothrow @nogc {
    del(mutex, allThreads, threadAllocator);
}

struct EntryFunctionArgs(Args...) {
    Args args;
}

version (Windows) {
    import core.sys.windows.windows : DWORD;

    extern (Windows) DWORD start_routine(EFA : EntryFunctionArgs!FunctionArgs, FunctionArgs...)(void* state) {
        import core.sys.windows.windows : GetCurrentProcess, DUPLICATE_CLOSE_SOURCE, DUPLICATE_SAME_ACCESS, FALSE,
            HANDLE, GetCurrentThread, DuplicateHandle;

        Thread self;
        EFA efa;

        accessGlobals((ref mutex, ref allThreads, ref threadAllocator) {
            self.state = cast(Thread.State*)state;
            self.__ctor(self);

            efa = *cast(EFA*)self.state.args;
            mutex.unlock;
        });

        self.externalAttach;
        scope (exit)
            self.externalDetach;

        (cast(void function(FunctionArgs)nothrow)self.state.entry)(efa.args);
        return 0;
    }

    ErrorResult waitForJoin(scope void* handle) @trusted nothrow @nogc {
        import core.sys.windows.windows : HANDLE, WaitForMultipleObjectsEx, WAIT_ABANDONED, WAIT_IO_COMPLETION,
            WAIT_OBJECT_0, WAIT_TIMEOUT, WAIT_FAILED, INFINITE, LARGE_INTEGER;

        Thread self;

        accessGlobals((ref mutex, ref allThreads, ref threadAllocator) {
            mutex.lock.assumeOkay;
            auto got = allThreads[handle];
            if (got && got !is null) {
                self.state = got;
                self.__ctor(self);
            }
            mutex.unlock;
        });

        if (self.isNull || self.state.handle.handle is null)
            return ErrorResult.init;

        assert(handle !is null);
        auto result = WaitForMultipleObjectsEx(1, &cast(HANDLE)handle, false, INFINITE, true);

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
    }
} else version (Posix) {
    import core.sys.posix.pthread : pthread_t;
    import core.sys.posix.time : timespec;

    extern (C) nothrow @nogc {
        int pthread_timedjoin_np(pthread_t thread, void** retval, const timespec* abstime);
    }

    static extern (C) void cleanupPosixRunning(void* state) nothrow {
        Thread self;
        self.state = cast(Thread.State*)state;
        self.__ctor(self);

        atomicStore(self.state.isRunning, false);
        self.externalDetach;
    }

    extern (C) void* start_routine(EFA : EntryFunctionArgs!FunctionArgs, FunctionArgs...)(void* state_) {
        import core.sys.posix.pthread;

        Thread self;
        EFA efa;

        accessGlobals((ref mutex, ref allThreads, ref threadAllocator) nothrow @nogc {
            assert(state_ !is null);
            pthread_t handle = pthread_self();

            Thread.State* state = cast(Thread.State*)state_;
            self.state = state;
            self.__ctor(self);

            efa = *cast(EFA*)state.args;

            atomicStore(state.isRunning, true);

            // copied right out of druntime
            // https://github.com/dlang/dmd/blob/f4be7f6f7bae75f1613b862940cdd533b5ae99b2/druntime/src/core/thread/osthread.d#L2200
            // needed because this isn't as simple as it should be
            static if (__traits(compiles, pthread_cleanup)) {
                pthread_cleanup cleanup = void;

                void addCleanup(ref pthread_cleanup cleanup, void* state) {
                    cleanup.push(&cleanupPosixRunning, state);
                }

                (cast(void delegate(ref pthread_cleanup, void* state)nothrow @nogc)&addCleanup)(cleanup, cast(void*)state);
            } else static if (__traits(compiles, pthread_cleanup_push)) {
                pthread_cleanup_push(&cleanupPosixRunning, cast(void*)state);
            } else
                static assert(0, "Unimplemented");

            state.handle = SystemHandle(cast(void*)handle, ThreadHandleIdentifier);
            allThreads[state.handle.handle] = state;
            mutex.unlock;
        });

        self.externalAttach;

        (cast(void function(FunctionArgs)nothrow)self.state.entry)(efa.args);
        return null;
    }

    ErrorResult waitForJoin(scope void* handle) @trusted nothrow @nogc {
        import core.sys.posix.pthread : pthread_join;

        int s = pthread_join(cast(pthread_t)handle, null);
        if (s != 0)
            return ErrorResult(UnknownPlatformBehaviorException("Thread failed to join for an unknown reason"));
        return ErrorResult.init;
    }
}

unittest {
    shared(int) counter;
    shared(bool) goForIt;

    Thread[10] threads;

    static void handleIt(shared(int)* counter, shared(bool)* goForIt) nothrow {
        while (!atomicLoad(*goForIt)) {
            atomicFence;
        }

        int prior;

        do {
            prior = atomicLoad(*counter);
        }
        while (!cas(*counter, prior, prior + 1));
    }

    foreach (ref thread; threads) {
        auto got = Thread.create(0, &handleIt, &counter, &goForIt);
        thread = got.assumeOkay;
    }

    atomicStore(goForIt, true);

    foreach (ref thread; threads) {
        cast(void)thread.join;
    }

    int result = atomicLoad(counter);
    assert(counter > 5);
}
