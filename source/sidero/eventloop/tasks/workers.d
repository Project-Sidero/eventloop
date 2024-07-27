module sidero.eventloop.tasks.workers;
import sidero.eventloop.threads;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.instanceable;
import sidero.base.errors;
import iw = sidero.eventloop.internal.workers;

export @safe nothrow @nogc:

///
ErrorResult startWorkerThreads() @trusted {
    if(iw.checkWorkerInit())
        return ErrorResult.init;

    return ErrorResult(UnknownPlatformBehaviorException("Could not start workers"));
}

///
void shutdownWorkerThreads() @trusted {
    iw.shutdownWorkers();
}

/**
    Configure the worker maximum multiplier based upon the cpu core count.

    Note: does not start any additional worker threads.

    Params: workerMultiplier = Default is 2, recommended by Jeffrey Richter and Jason D. Clark for Windows IOCP.
*/
void configureWorkerMultiplier(size_t workerMultiplier = 2) @trusted {
    configureWorkerMultiplier(workerMultiplier);
}

///
bool isWorkerThread(Thread other) {
    return iw.isWorkerThread(other);
}

///
bool isOnWorkerThread() {
    return iw.isWorkerThread(Thread.self);
}

/// Register a coroutine as a task on to the worker threads pool
void registerAsTask(GenericCoroutine coroutine) {
    iw.addCoroutineTask(coroutine);
}

///
void registerAsTask(ResultType)(Future!ResultType coroutine) {
    auto co = coroutine.asGeneric();
    iw.addCoroutineTask(co);
}

///
void registerAsTask(ResultType, Args...)(InstanceableCoroutine!(ResultType, Args) coroutine) {
    auto co = coroutine.asGeneric();
    iw.addCoroutineTask(co);
}
