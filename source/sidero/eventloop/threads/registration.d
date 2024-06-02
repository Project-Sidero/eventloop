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
void registerThreadRegistration(void* key, OnAttachThisFunction attachThis, OnDetachThisFunction detachThis,
        IsThreadRegisteredFunction isRegistered, DetachOfThreadFunction detach) {
    import sidero.base.synchronization.system.lock;
    import sidero.base.containers.map.hashmap;
    import sidero.base.allocators.predefined;

    accessGlobals((ref SystemLock mutex, ref HashMap!(void*, Thread.State*) allThreads, ref HouseKeepingAllocator!() threadAllocator) {
        mutex.lock.assumeOkay;
        scope (exit)
        mutex.unlock;

        if (key !in threadSystemRegistration) {
            auto ts = ThreadSystemRegistrationInfo(attachThis, detachThis, isRegistered, detach);
            threadSystemRegistration[key] =ts;

            foreach (_, threadState; allThreads) {
                assert(threadState);

                if (ts.detachFunc !is null && threadState.currentlyRegisteredOnRuntimes.update(key, false)) {
                    Thread thread;
                    thread.state = threadState;
                    threadState.rc(true);

                    ts.detachFunc(thread);
                }

                threadState.onDetach(1);
            }

        }

        if (threadSystemRegistration.length == 0)
            threadSystemRegistration = typeof(threadSystemRegistration).init;
    });

}

///
void deregisterThreadRegistration(void* key) {
    import sidero.base.synchronization.system.lock;
    import sidero.base.containers.map.hashmap;
    import sidero.base.allocators.predefined;

    accessGlobals((ref SystemLock mutex, ref HashMap!(void*, Thread.State*) allThreads, ref HouseKeepingAllocator!() threadAllocator) {
        mutex.lock.assumeOkay;
        scope (exit)
            mutex.unlock;

        if (key in threadSystemRegistration) {
            auto ts = threadSystemRegistration[key];
            assert(ts);

            foreach (_, threadState; allThreads) {
                assert(threadState);

                if (ts.detachFunc !is null && threadState.currentlyRegisteredOnRuntimes.update(key, false)) {
                    Thread thread;
                    thread.state = threadState;
                    threadState.rc(true);

                    ts.detachFunc(thread);
                }

                threadState.onDetach(1);
            }

            threadSystemRegistration.remove(key);
        }

        if (threadSystemRegistration.length == 0)
            threadSystemRegistration = typeof(threadSystemRegistration).init;
    });
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

        if (ts.attachThisFunc !is null && thread.state.currentlyRegisteredOnRuntimes.update(k.get, true)) {
            ts.attachThisFunc();
            done++;
        }
    }

    return done;
}

// MUST be guarded and be on the thread to attach
size_t onDetachOfThread(Thread thread) {
    scope (exit) {
        if (threadSystemRegistration.length == 0)
            threadSystemRegistration = typeof(threadSystemRegistration).init;
    }

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

        foreach (_, threadState; allThreads) {
            assert(threadState);

            if (atomicLoad(threadState.attachCount) == 0)
                continue;

            Thread thread;
            thread.state = threadState;
            threadState.rc(true);

            size_t done;

            foreach (k, ts; threadSystemRegistration) {
                assert(k);
                assert(ts);

                if (ts.detachFunc !is null && threadState.currentlyRegisteredOnRuntimes.get(k, false)) {
                    ts.detachFunc(thread);
                    done++;
                }
            }

            threadState.onDetach(done);
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
    OnAttachThisFunction attachThisFunc;
    OnDetachThisFunction detachThisFunc;
    IsThreadRegisteredFunction isThisRegisteredFunc;
    DetachOfThreadFunction detachFunc;
}
