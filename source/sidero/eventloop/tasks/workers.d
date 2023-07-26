module sidero.eventloop.tasks.workers;
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
