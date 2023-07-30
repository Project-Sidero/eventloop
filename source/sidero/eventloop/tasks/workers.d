module sidero.eventloop.tasks.workers;
import sidero.eventloop.threads;

import sidero.base.errors;

export @safe nothrow @nogc:

///
ErrorResult startWorkers(size_t workerMultiplier) @trusted {
    import iw = sidero.eventloop.internal.workers;

    if(iw.startWorkers(workerMultiplier))
        return ErrorResult.init;

    return ErrorResult(UnknownPlatformBehaviorException("Could not start workers"));
}

///
void shutdownWorkers() @trusted {
    import iw = sidero.eventloop.internal.workers;

    iw.shutdownWorkers();
}

///
bool isWorkerThread(Thread other) {
    import iw = sidero.eventloop.internal.workers;

    return iw.isWorkerThread(other);
}

///
bool isOnWorkerThread() {
    import iw = sidero.eventloop.internal.workers;

    return iw.isWorkerThread(Thread.self);
}
