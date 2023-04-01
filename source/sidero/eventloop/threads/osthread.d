module sidero.eventloop.threads.osthread;
import sidero.eventloop.handles;
import sidero.base.errors;
import sidero.base.datetime.duration;

// https://idea.popcount.org/2017-02-20-epoll-is-fundamentally-broken-12/ EPOLLONESHOT EPOLLEXCLUSIVE
// https://idea.popcount.org/2017-03-20-epoll-is-fundamentally-broken-22/

alias ThreadEntryFunction = void function() nothrow;

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
            rwlock.pureWriteLock;
            externalDetach;

            allThreads.remove(state.handle.handle);

            if (state.owns) {
                // TODO: destroy handle
            }

            threadAllocator.deallocate((cast(void*)state)[0 .. State.sizeof]);
            rwlock.writeUnlock;
        }
    }

    ///
    bool isNull() scope const {
        return state is null;
    }

    ///
    bool isRunning() scope const {
        if (isNull)
            return false;

        // pthread_tryjoin_np
        // GetExitCodeThread
        assert(0);
    }

    ///
    static Result!Thread create(ThreadEntryFunction entryFunction, size_t stackSize = 0) {
        // pthread_create
        // CreateThread

        //allThreads[cast(void*)handle] = ret.state;
        //externalAttach
        assert(0);
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
    static Thread self() {
        // pthread_self
        // GetCurrentThread
        assert(0);
    }

    ///
    Result!size_t wait(Duration timeout = Duration.max) scope const {
        // WaitForSingleObjectEx
        // pthread_timedjoin_np
        assert(0);
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
    }
}

private:
import sidero.eventloop.threads.registration;
import sidero.base.allocators.predefined;
import sidero.base.parallelism.rwmutex;
import sidero.base.containers.map.hashmap;

__gshared {
    ReaderWriterLockInline rwlock;
    HashMap!(void*, Thread.State*) allThreads;
    HouseKeepingAllocator!() threadAllocator;
}
