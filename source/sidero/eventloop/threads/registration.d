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
    rwlock.pureWriteLock;
    scope (exit)
        rwlock.writeUnlock;

    ThreadSystemRegistrationInfo* current = threadSystemRegistrationLL;
    ThreadSystemRegistrationInfo** parent = &threadSystemRegistrationLL;

    while (current !is null && cast(size_t)current.key < cast(size_t)key) {
        parent = &current.next;
        current = current.next;
    }

    if (current !is null && cast(size_t)current.key == cast(size_t)key) {
        // update, why? idk
        if (current.attachFunc is null)
            current.attachFunc = onAttach;
        if (current.detachFunc is null)
            current.detachFunc = onDetach;
        if (current.isThisRegisteredFunc is null)
            current.isThisRegisteredFunc = isRegistered;
    } else {
        void[] block = threadSystemRegistrationAllocator.allocate(ThreadSystemRegistrationInfo.sizeof);
        assert(block.length == ThreadSystemRegistrationInfo.sizeof);
        ThreadSystemRegistrationInfo* newNode = cast(ThreadSystemRegistrationInfo*)block.ptr;

        newNode.next = current;
        newNode.key = key;
        newNode.attachFunc = onAttach;
        newNode.detachFunc = onDetach;
        newNode.isThisRegisteredFunc = isRegistered;

        *parent = newNode;
    }
}

///
void deregisterThreadRegistration(void* key) {
    rwlock.pureWriteLock;
    scope (exit)
        rwlock.writeUnlock;

    ThreadSystemRegistrationInfo* current = threadSystemRegistrationLL;
    ThreadSystemRegistrationInfo** parent = &threadSystemRegistrationLL;

    while (current !is null && cast(size_t)current.key < cast(size_t)key) {
        parent = &current.next;
        current = current.next;
    }

    if (current !is null && cast(size_t)current.key == cast(size_t)key) {
        *parent = current.next;
        threadSystemRegistrationAllocator.deallocate((cast(void*)current)[0 .. ThreadSystemRegistrationInfo.sizeof]);
    }
}

package(sidero.eventloop.threads):

void onAttachOfThread() {
    rwlock.pureReadLock;
    scope (exit)
    rwlock.pureReadUnlock;

    ThreadSystemRegistrationInfo* current = threadSystemRegistrationLL;

    while(current !is null) {
        if (current.attachFunc !is null)
            current.attachFunc();
        current = current.next;
    }
}

void onDetachOfThread() {
    rwlock.pureReadLock;
    scope (exit)
    rwlock.pureReadUnlock;

    ThreadSystemRegistrationInfo* current = threadSystemRegistrationLL;

    while(current !is null) {
        if (current.detachFunc !is null)
            current.detachFunc();
        current = current.next;
    }
}

private:
import sidero.base.allocators.predefined;
import sidero.base.parallelism.rwmutex;

__gshared {
    ReaderWriterLockInline rwlock;
    ThreadSystemRegistrationInfo* threadSystemRegistrationLL;
    HouseKeepingAllocator!() threadSystemRegistrationAllocator;
}

struct ThreadSystemRegistrationInfo {
    ThreadSystemRegistrationInfo* next;
    void* key;

    OnAttachThisFunction attachFunc;
    OnDetachThisFunction detachFunc;
    IsThreadRegisteredFunction isThisRegisteredFunc;
}

