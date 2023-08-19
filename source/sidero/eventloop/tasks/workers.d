module sidero.eventloop.tasks.workers;
import sidero.eventloop.threads;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.instanceable;
import sidero.base.errors;
import iw = sidero.eventloop.internal.workers;

export @safe nothrow @nogc:

/// Params: workerMultiplier = Default is 2, recommended by Jeffrey Richter and Jason D. Clark for Windows IOCP.
ErrorResult startWorkers(size_t workerMultiplier = 2) @trusted {
    if(iw.startWorkers(workerMultiplier))
        return ErrorResult.init;

    return ErrorResult(UnknownPlatformBehaviorException("Could not start workers"));
}

///
void shutdownWorkers() @trusted {
    iw.shutdownWorkers();
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
    iw.addCoroutineTask(coroutine.asGeneric());
}

///
void registerAsTask(ResultType, Args...)(InstanceableCoroutine!(ResultType, Args) coroutine) {
    iw.addCoroutineTask(coroutine.asGeneric());
}
