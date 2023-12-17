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

    protectAttachDetachMutex.writeLock;

    threadSystemRegistration[key] = ThreadSystemRegistrationInfo(onAttach, onDetach, isRegistered, detach);

    protectAttachDetachMutex.pureWriteUnlock;
}

///
void deregisterThreadRegistration(void* key) {
    protectAttachDetachMutex.writeLock;

    threadSystemRegistration.remove(key);

    protectAttachDetachMutex.pureWriteUnlock;
}

package(sidero.eventloop.threads):

// MUST be guarded and be on the thread to attach
size_t onAttachOfThread(Thread thread) {
    if (thread.isNull)
        return 0;

    size_t done;
    protectAttachDetachMutex.readLock;

    foreach (k, ts; threadSystemRegistration) {
        assert(k);
        assert(ts);

        auto isRegistered = thread.state.currentlyRegisteredOnRuntimes.get(k.get, false);
        assert(isRegistered);

        if (!isRegistered.get && ts.attachFunc !is null) {
            const set = thread.state.currentlyRegisteredOnRuntimes.update(k.get, true);
            assert(set);

            ts.attachFunc();
            done++;
        }
    }

    protectAttachDetachMutex.readUnlock;
    return done;
}

// MUST be guarded and be on the thread to attach
size_t onDetachOfThread(Thread thread) {
    if (thread.isNull)
        return 0;

    size_t done;
    protectAttachDetachMutex.readLock;

    foreach (k, ts; threadSystemRegistration) {
        assert(k);
        assert(ts);

        auto isRegistered = thread.state.currentlyRegisteredOnRuntimes.get(k, false);
        assert(isRegistered);

        if (isRegistered.get && ts.detachThisFunc !is null) {
            const set = thread.state.currentlyRegisteredOnRuntimes.update(k.get, false);
            assert(set);

            ts.detachThisFunc();
            done++;
        }
    }

    protectAttachDetachMutex.readUnlock;
    return done;
}

///
void deregisterOwnedThreads() {
    protectAttachDetachMutex.readLock;

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

                auto isRegistered = threadState.currentlyRegisteredOnRuntimes.get(k, false);
                assert(isRegistered);

                if (isRegistered.get && ts.detachFunc !is null) {
                    const set = threadState.currentlyRegisteredOnRuntimes.update(k.get, false);
                    assert(set);

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

    protectAttachDetachMutex.readUnlock;
}

private:
import sidero.base.allocators.predefined;
import sidero.base.containers.map.concurrenthashmap;
import sidero.base.synchronization.rwmutex;

__gshared {
    ReaderWriterLockInline protectAttachDetachMutex;
    ConcurrentHashMap!(void*, ThreadSystemRegistrationInfo) threadSystemRegistration;
}

struct ThreadSystemRegistrationInfo {
    OnAttachThisFunction attachFunc;
    OnDetachThisFunction detachThisFunc;
    IsThreadRegisteredFunction isThisRegisteredFunc;
    DetachOfThreadFunction detachFunc;
}
