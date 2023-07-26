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

    threadSystemRegistration[key] = ThreadSystemRegistrationInfo(onAttach, onDetach, isRegistered);
}

///
void deregisterThreadRegistration(void* key) {
    threadSystemRegistration.remove(key);
}

package(sidero.eventloop.threads):

void onAttachOfThread() {
    foreach(k, ts; threadSystemRegistration) {
        assert(ts);
        if(ts.attachFunc !is null)
            ts.attachFunc();
    }
}

void onDetachOfThread() {
    foreach(k, ts; threadSystemRegistration) {
        assert(ts);
        if(ts.detachFunc !is null)
            ts.detachFunc();
    }
}

private:
import sidero.base.allocators.predefined;
import sidero.base.containers.map.concurrenthashmap;

__gshared {
    ConcurrentHashMap!(void*, ThreadSystemRegistrationInfo) threadSystemRegistration;
}

struct ThreadSystemRegistrationInfo {
    OnAttachThisFunction attachFunc;
    OnDetachThisFunction detachFunc;
    IsThreadRegisteredFunction isThisRegisteredFunc;
}
