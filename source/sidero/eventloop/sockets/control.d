module sidero.eventloop.sockets.control;
import sidero.eventloop.internal.networking.platform;
import sidero.base.errors;

export @safe nothrow @nogc:

///
ErrorResult startUpNetworking() @trusted {
    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(isInitialized)
        return ErrorResult.init;

    if(!startUpNetworkingMechanism)
        return ErrorResult(UnknownPlatformBehaviorException("Could not start networking"));

    isInitialized = true;
    return ErrorResult.init;
}

///
void shutdownNetworking() @trusted {
    import sidero.eventloop.internal.event_waiting;

    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(!isInitialized)
        return;

    shutdownEventWaiterThreads;
    shutdownNetworkingMechanism;
    isInitialized = false;
}

package(sidero.eventloop.sockets):
import sidero.base.synchronization.mutualexclusion;

__gshared {
    TestTestSetLockInline mutex;
    bool isInitialized;
}

bool ensureItIsSetup() {
    import sidero.eventloop.tasks.workers;

    if(!startUpNetworking)
        return false;
    else if(!startWorkers(0))
        return false;

    return true;
}
