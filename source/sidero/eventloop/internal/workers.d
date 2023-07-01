module sidero.eventloop.internal.workers;
import sidero.eventloop.threads;
import sidero.base.system : cpuCount;
import sidero.base.containers.dynamicarray;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.synchronization.mutualexclusion;

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
    TestTestSetLockInline mutex;
    bool isInitialized;

    DynamicArray!Thread threadPool;
    LoggerReference logger;
}

bool startWorkers(size_t workerMultiplier) @trusted {
    mutex.pureLock;
    scope (exit)
        mutex.unlock;

    logger = Logger.forName(String_UTF8(__MODULE__));
    if (!logger)
        return false;

    const count = workerMultiplier * cpuCount();
    if (threadPool.length >= count)
        return true;

    auto oldCount = threadPool.length;

    threadPool.reserve(count - oldCount);
    if (!initializeWorkerMechanism(count))
        return false;

    foreach (i; oldCount .. count) {
        auto thread = Thread.create(&workerProc);

        if (thread)
            threadPool ~= thread.get;
        else {
            logger.error("Could not create thread", thread.getError());
            break;
        }
    }

    isInitialized = true;
    return true;
}

void shutdownWorkers() @trusted {
    mutex.pureLock;
    scope (exit)
        mutex.unlock;

    if (!isInitialized)
        return;

    shutdownWorkerMechanism;

    foreach (thread; threadPool) {
        for (;;) {
            auto got = thread.join();
            if (got)
                break;
        }

        assert(!thread.isNull);
        assert(!thread.isRunning);
    }

    threadPool = typeof(threadPool).init;
    isInitialized = false;
}
