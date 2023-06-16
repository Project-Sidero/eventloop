module sidero.eventloop.internal.workers;
import sidero.eventloop.threads;
import sidero.base.system : cpuCount;
import sidero.base.containers.readonlyslice;
import sidero.base.logger;
import sidero.base.text;

version (Windows) {
    import sidero.eventloop.internal.windows.iocp;
} else {
    static assert(0, "unimplemented");
}

export @safe nothrow @nogc:

version (none) {
    void shutdownWorkerMechanism() {
    }

    bool initializeWorkerMechanism(size_t count) {
        return false;
    }

    void workerProc() {
    }
}

private __gshared {
    Slice!Thread threadPool;
    LoggerReference logger;
}

bool startWorkers(size_t workerMultiplier) @trusted {
    import sidero.base.containers.dynamicarray;

    auto gotLogger = Logger.forName(String_UTF8(__MODULE__));
    if (gotLogger)
        logger = gotLogger.get;
    else
        return false;

    const count = workerMultiplier * cpuCount();

    DynamicArray!Thread tempPool;
    tempPool.reserve(count);

    if (!initializeWorkerMechanism(count))
        return false;

    foreach (i; 0 .. count) {
        auto thread = Thread.create(&workerProc);

        if (thread)
            tempPool ~= thread.get;
        else {
            logger.error("Could not create thread", thread.getError());
            break;
        }
    }

    threadPool = tempPool.asReadOnly();
    return true;
}

void shutdownWorkers() {
    shutdownWorkerMechanism;
}

void waitForWorkersToJoin() @trusted {
    foreach (thread; threadPool) {
        cast(void)thread.join;
    }

    threadPool = typeof(threadPool).init;
}
