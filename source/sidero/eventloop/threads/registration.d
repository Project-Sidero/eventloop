module sidero.eventloop.threads.registration;
import sidero.eventloop.threads.osthread;

export nothrow @nogc:

///
alias OnAttachThisFunction = extern (C) void function();
///
alias OnDetachThisFunction = extern (C) void function();
///
alias IsThreadRegisteredFunction = extern (C) bool function();
///
alias DetachOfThreadFunction = extern (C) void function(Thread);

///
void registerThreadRegistration(void* key, OnAttachThisFunction onAttach, OnDetachThisFunction onDetach,
        IsThreadRegisteredFunction isRegistered, DetachOfThreadFunction detach) {
    threadSystemRegistration[key] = ThreadSystemRegistrationInfo(onAttach, onDetach, isRegistered, detach);
}

///
void deregisterThreadRegistration(void* key) {
    threadSystemRegistration.remove(key);
}

package(sidero.eventloop.threads):

// MUST be guarded and be on the thread to attach
size_t onAttachOfThread(Thread thread) {
    if (thread.isNull)
        return 0;

    size_t done;

    foreach (k, ts; threadSystemRegistration) {
        assert(k);
        assert(ts);

        if (ts.attachFunc !is null && thread.state.currentlyRegisteredOnRuntimes.update(k.get, true)) {
            ts.attachFunc();
            done++;
        }
    }

    return done;
}

// MUST be guarded and be on the thread to attach
size_t onDetachOfThread(Thread thread) {
    if (thread.isNull)
        return 0;

    size_t done;

    foreach (k, ts; threadSystemRegistration) {
        assert(k);
        assert(ts);

        auto isRegistered = thread.state.currentlyRegisteredOnRuntimes.get(k, false);
        assert(isRegistered);

        if (ts.detachThisFunc !is null && thread.state.currentlyRegisteredOnRuntimes.update(k.get, false)) {
            ts.detachThisFunc();
            done++;
        }
    }

    return done;
}

///
void deregisterOwnedThreads() {
    accessGlobals((ref mutex, ref allThreads, ref threadAllocator) {
        import sidero.base.internal.atomic : atomicLoad, atomicDecrementAndLoad;
        mutex.lock.assumeOkay;

        foreach(_, threadState; allThreads) {
            assert(threadState);

            if (atomicLoad(threadState.attachCount) == 0)
                continue;

            Thread thread;
            thread.state = threadState;
            thread.__ctor(thread);

            size_t done;

            foreach (k, ts; threadSystemRegistration) {
                assert(k);
                assert(ts);

                if (ts.detachFunc !is null && threadState.currentlyRegisteredOnRuntimes.get(k, false)) {
                    ts.detachFunc(thread);
                    done++;
                }
            }

            if (atomicDecrementAndLoad(threadState.attachCount, done) == 0) {
                // extra unpin for this thread instance
                atomicDecrementAndLoad(threadState.refCount, 1);
            }
        }

        mutex.unlock;
    });
}

private:
import sidero.base.allocators.predefined;
import sidero.base.containers.map.concurrenthashmap;

__gshared {
    ConcurrentHashMap!(void*, ThreadSystemRegistrationInfo) threadSystemRegistration;
}

struct ThreadSystemRegistrationInfo {
    OnAttachThisFunction attachFunc;
    OnDetachThisFunction detachThisFunc;
    IsThreadRegisteredFunction isThisRegisteredFunc;
    DetachOfThreadFunction detachFunc;
}
