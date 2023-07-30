module sidero.eventloop.internal.workers;
import sidero.eventloop.threads;
import sidero.base.system : cpuCount;
import sidero.base.containers.dynamicarray;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.synchronization.mutualexclusion;

version(Windows) {
    import sidero.eventloop.internal.windows.iocp;
} else {
    static assert(0, "unimplemented");
}

export @safe nothrow @nogc:

version(none) {
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
    scope(exit)
        mutex.unlock;

    logger = Logger.forName(String_UTF8(__MODULE__));
    if(!logger)
        return false;

    const oldCount = threadPool.length;
    const newCount = workerMultiplier * cpuCount();

    if(oldCount > 0) {
        if(newCount > oldCount) {
            logger.notice("Starting additional workers, using multiplier ", workerMultiplier, " for an additional ",
                    newCount - oldCount, " to form ", newCount, " workers");
        } else {
            logger.notice("Attempted to start additional workers, but the calculated new workers were less than the old ones ",
                    newCount, " but was ", oldCount);
            return true;
        }
    } else
        logger.notice("Starting workers, using multiplier ", workerMultiplier, " for a total of ", newCount, " workers");

    threadPool.reserve(newCount - oldCount);
    if(!initializeWorkerMechanism(newCount))
        return false;

    foreach(i; oldCount .. newCount) {
        auto thread = Thread.create(&workerProc);

        if(thread)
            threadPool ~= thread.get;
        else {
            logger.error("Could not create worker thread ", thread.getError());
            break;
        }
    }

    isInitialized = true;
    return threadPool.length > oldCount;
}

void shutdownWorkers() @trusted {
    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(!isInitialized)
        return;

    logger.notice("Shutting down of workers");

    shutdownWorkerMechanism;

    foreach(thread; threadPool) {
        for(;;) {
            auto got = thread.join();
            if(got)
                break;
        }

        assert(!thread.isNull);
        assert(!thread.isRunning);
    }

    logger.notice("All worker threads have been joined");

    threadPool = typeof(threadPool).init;
    isInitialized = false;
}

bool isWorkerThread(Thread other) @trusted {
    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    foreach(thread; threadPool) {
        if(thread == other)
            return true;
    }

    return false;
}
