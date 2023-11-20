module sidero.eventloop.threads.registration;

export nothrow @nogc:

///
alias OnAttachThisFunction = extern (C) void function();
///
alias OnDetachThisFunction = extern (C) void function();
///
alias IsThreadRegisteredFunction = extern (C) bool function();

///
void registerThreadRegistration(void* key, OnAttachThisFunction onAttach, OnDetachThisFunction onDetach,
        IsThreadRegisteredFunction isRegistered) {

    protectAttachDetachMutex.writeLock;

    threadSystemRegistration[key] = ThreadSystemRegistrationInfo(onAttach, onDetach, isRegistered);

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

    foreach(k, ts; threadSystemRegistration) {
        assert(ts);
        if(ts.attachFunc !is null)
            ts.attachFunc();
    }

    protectAttachDetachMutex.readUnlock;
}

// MUST be guarded and be on the thread to attach
void onDetachOfThread() {
    protectAttachDetachMutex.readLock;

    foreach(k, ts; threadSystemRegistration) {
        assert(ts);
        if(ts.detachFunc !is null)
            ts.detachFunc();
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
    OnDetachThisFunction detachFunc;
    IsThreadRegisteredFunction isThisRegisteredFunc;
}
