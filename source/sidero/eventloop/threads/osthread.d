module sidero.eventloop.threads.osthread;
import sidero.eventloop.handles;
import sidero.base.errors;
import sidero.base.datetime.duration;

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
            import core.sys.windows.windows : HANDLE, GetExitCodeThread, STILL_ACTIVE;

            uint result;
            if (GetExitCodeThread(cast(HANDLE)state.handle.handle, &result) == STILL_ACTIVE)
                return true;
            return false;
        } else version (Posix) {
            import core.atomic : atomicLoad;

            return atomicLoad(state.isRunning);
        } else
            static assert(0, "Unimplemented platform");
    }

    ///
    static Result!Thread create(Args...)(size_t stackSize, void function(Args) nothrow entryFunction, Args args) @trusted {
        Result!Thread ret;

        accessGlobals((ref mutex, ref allThreads, ref threadAllocator) {
            mutex.pureLock;

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
                efa.destroy;
                state.destroy;

                retThread.state = null;

                threadAllocator.deallocate(memory);
                threadAllocator.deallocate(efaMemory);
                mutex.unlock;
            }

            version (Windows) {
                import core.sys.windows.windows : CreateThread, CloseHandle;

                auto handle = CreateThread(null, stackSize, &start_routine!(EntryFunctionArgs!Args), state, 0, null);
                if (handle is null) {
                    cleanup;
                    ret = Result!Thread(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
                    return;
                }
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
                s = pthread_create(&handle, attr, &start_routine!(EntryFunctionArgs!Args), cast(void*)state);
                s |= pthread_attr_destroy(&attr);
                if (s != 0) {
                    cleanup;
                    ret = Result!Thread(UnknownPlatformBehaviorException("Unknown platform thread creation behavior failure"));
                    return;
                }
            }

            mutex.pureLock;
            version (Windows) {
                // on Windows the handle gets duplicated during startup, so gotta make win32 reference count zero
                CloseHandle(handle);
            }
            mutex.unlock;

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
            import core.sys.posix.time : clock_gettime, CLOCK_REALTIME, nanosleep;
            import core.stdc.time : timespec;
            import core.stdc.errno : EINTR, errno;

            long secs = timeout.totalSeconds();
            long nsecs = (timeout - secs.seconds()).totalNanoSeconds();

            timespec ts;
            if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
                return ErrorResult(UnknownPlatformBehaviorException("Could not get time to compute timeout for thread join"));

            ts.tv_sec += secs;
            ts.tv_nsec += nsecs;

            errno = 0;
            auto result = nanosleep(ts, null);

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
        mutex.pureLock;

        version (Windows) {
            import core.sys.windows.windows : GetCurrentProcess, DUPLICATE_CLOSE_SOURCE, DUPLICATE_SAME_ACCESS, FALSE,
                HANDLE, GetCurrentThread, DuplicateHandle;

            HANDLE handle = GetCurrentThread();
            DuplicateHandle(GetCurrentProcess(), handle, null, &handle, 0, FALSE, DUPLICATE_CLOSE_SOURCE | DUPLICATE_SAME_ACCESS);
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

            state.handle = SystemHandle(cast(void*)handle, ThreadHandleIdentifier, &waitForJoin);

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
                WAIT_OBJECT_0, WAIT_TIMEOUT, WAIT_FAILED, INFINITE;

            if (timeout < Duration.max) {
                auto result = WaitForSingleObjectEx(cast(HANDLE)state.handle.handle, timeout < Duration.max ?
                        cast(uint)timeout.totalMilliSeconds() : INFINITE, true);

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
            } else {
                return waitForJoin(cast(void*)state.handle.handle);
            }
        } else version (Posix) {
            import core.sys.posix.pthread : pthread_timedjoin_np, pthread_join;
            import core.sys.posix.time : clock_gettime, CLOCK_REALTIME;
            import core.stdc.time : timespec;

            if (timeout < Duration.max) {
                long secs = timeout.totalSeconds();
                long nsecs = (timeout - secs.seconds()).totalNanoSeconds();

                timespec ts;
                if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
                    return ErrorResult(UnknownPlatformBehaviorException("Could not get time to compute timeout for thread join"));

                ts.tv_sec += secs;
                ts.tv_nsec += nsecs;

                int s = pthread_timedjoin_np(cast(void*)state.handle.handle, null, ts);
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
import sidero.base.allocators.predefined;
import sidero.base.synchronization.mutualexclusion;
import sidero.base.containers.map.hashmap;

__gshared {
    TestTestSetLockInline mutex;
    HashMap!(void*, Thread.State*) allThreads;
    HouseKeepingAllocator!() threadAllocator;
}

export void accessGlobals(scope void delegate(ref TestTestSetLockInline mutex, ref HashMap!(void*,
        Thread.State*) allThreads, ref HouseKeepingAllocator!() threadAllocator) nothrow @nogc del) nothrow @nogc {
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
            HANDLE handle = GetCurrentThread();
            DuplicateHandle(GetCurrentProcess(), handle, null, &handle, 0, FALSE, DUPLICATE_CLOSE_SOURCE | DUPLICATE_SAME_ACCESS);

            self.state = cast(Thread.State*)state;
            self.__ctor(self);

            efa = *cast(EFA*)self.state.args;

            self.state.handle = SystemHandle(cast(void*)handle, ThreadHandleIdentifier, &waitForJoin);
            allThreads[self.state.handle.handle] = self.state;
            mutex.unlock;
        });

        self.externalAttach;
        (cast(void function(FunctionArgs)nothrow)self.state.entry)(efa.args);
        return 0;
    }

    ErrorResult waitForJoin(scope void* handle) @trusted nothrow @nogc {
        import core.sys.windows.windows : HANDLE, WaitForSingleObjectEx, WAIT_ABANDONED, WAIT_IO_COMPLETION,
            WAIT_OBJECT_0, WAIT_TIMEOUT, WAIT_FAILED, INFINITE;

        auto result = WaitForSingleObjectEx(cast(HANDLE)handle, INFINITE, true);

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
    static extern (C) void cleanupPosixRunning(void* state) {
        import core.atomic : atomicStore;

        Thread self;
        self.state = cast(Thread.State*)state;
        self.__ctor(self);

        atomicStore(state.isRunning, false);
    }

    extern (C) void* start_routine(EFA : EntryFunctionArgs!FunctionArgs, FunctionArgs...)(void* state_) {
        import core.sys.posix.pthread : pthread_cleanup_push, pthread_self, pthread_t;
        import core.atomic : atomicStore;

        Thread self;
        EFA efa;

        accessGlobals((ref mutex, ref allThreads, ref threadAllocator) {
            assert(state_ !is null);
            pthread_t handle = pthread_self();

            Thread.State* state = state_;
            self.state = state;
            self.__ctor(self);

            efa = *cast(EFA*)state.args;

            atomicStore(state.isRunning, true);
            pthread_cleanup_push(&cleanupPosixRunning, cast(void*)state);

            state.handle = SystemHandle(cast(void*)handle, ThreadHandleIdentifier, &waitForJoin);
            allThreads[state.handle.handle] = state;
            mutex.unlock;
        });

        self.externalAttach;
        (cast(void function(FunctionArgs)nothrow)self.state.entry)(efa.args);
        return null;
    }

    ErrorResult waitForJoin(scope void* handle) @trusted nothrow @nogc {
        int s = pthread_join(handle, null);
        if (s != 0)
            return ErrorResult(UnknownPlatformBehaviorException("Thread failed to join for an unknown reason"));
        return ErrorResult.init;
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

        int prior;

        do {
            prior = atomicLoad(*counter);
        }
        while (!cas(counter, prior, prior + 1));
    }

    foreach (ref thread; threads) {
        auto got = Thread.create(0, &handleIt, &counter, &goForIt);
        thread = got.assumeOkay;
    }

    atomicStore(goForIt, true);

    foreach (ref thread; threads) {
        thread.join;
    }

    int result = atomicLoad(counter);
    assert(counter > 5);
}
