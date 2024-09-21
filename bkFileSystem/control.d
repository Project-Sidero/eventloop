module sidero.eventloop.filesystem.control;
import sidero.eventloop.internal.filesystem.platform;
import sidero.base.errors;

export @safe nothrow @nogc:

///
ErrorResult startUpFileSystem() @trusted {
    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(isInitialized)
        return ErrorResult.init;

    if(!startUpFileSystemMechanism)
        return ErrorResult(UnknownPlatformBehaviorException("Could not start filesystem"));

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
    shutdownFileSystemMechanism;
    isInitialized = false;
}

package(sidero.eventloop.filesystem):
import sidero.base.synchronization.mutualexclusion;

__gshared {
    TestTestSetLockInline mutex;
    bool isInitialized;
}

bool ensureItIsSetup() {
    import sidero.eventloop.tasks.workers;

    if(!startUpFileSystem)
        return false;
    else if(!startWorkerThreads)
        return false;

    return true;
}
