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
void onAttachOfThread() {
    protectAttachDetachMutex.readLock;

    foreach (k, ts; threadSystemRegistration) {
        assert(ts);
        if (ts.attachFunc !is null)
            ts.attachFunc();
    }

    protectAttachDetachMutex.readUnlock;
}

// MUST be guarded and be on the thread to attach
void onDetachOfThread() {
    protectAttachDetachMutex.readLock;

    foreach (k, ts; threadSystemRegistration) {
        assert(ts);
        if (ts.detachThisFunc !is null)
            ts.detachThisFunc();
    }

    protectAttachDetachMutex.readUnlock;
}

///
void deregisterOwnedThreads() {
    protectAttachDetachMutex.readLock;

    accessGlobals((ref mutex, ref allThreads, ref threadAllocator) {
        import sidero.base.internal.atomic : atomicLoad, atomicDecrementAndLoad;
        mutex.lock.assumeOkay;

        foreach(_, threadState; allThreads) {
            assert(threadState);

            // if we don't own it, who cares?
            if (!threadState.owns && atomicLoad(threadState.attachCount) == 0)
                continue;

            Thread thread;
            thread.state = threadState;
            thread.__ctor(thread);

            foreach (k, ts; threadSystemRegistration) {
                assert(ts);
                if (ts.detachFunc is null)
                    continue;

                ts.detachFunc(thread);
            }

            if (!threadState.owns) {
                atomicDecrementAndLoad(threadState.attachCount, 1);
                atomicDecrementAndLoad(threadState.refCount, 1);
            }
        }

        mutex.unlock;
    });

    protectAttachDetachMutex.readUnlock;
}

// MUST be guarded and be on the thread to attach
void onDetachOfThread(Thread thread) {
    protectAttachDetachMutex.readLock;

    foreach (k, ts; threadSystemRegistration) {
        assert(ts);
        if (ts.detachFunc !is null)
            ts.detachFunc(thread);
    }

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
