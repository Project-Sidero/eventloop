module sidero.eventloop.internal.workers;
import sidero.eventloop.threads;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.coroutine.condition;
import sidero.base.system : cpuCount;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.map.duplicatehashmap;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.allocators;
import sidero.base.errors;
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

    void triggerACoroutineMechanism(size_t count) {
    }

    void workerProc() {
    }
}

__gshared {
    private {
        TestTestSetLockInline mutex;
        bool isInitialized;

        DynamicArray!Thread threadPool;
        LoggerReference logger;

        DuplicateHashMap!(GenericCoroutine, GenericCoroutine) coroutinesWaitingOnOthers;
    }

    package(sidero.eventloop.internal) {
        FiFoConcurrentQueue!GenericCoroutine coroutinesForWorkers;
    }
}

bool startWorkers(size_t workerMultiplier) @trusted {
    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    logger = Logger.forName(String_UTF8(__MODULE__));
    if(!logger)
        return false;

    if(coroutinesForWorkers.isNull) {
        coroutinesForWorkers = FiFoConcurrentQueue!GenericCoroutine(RCAllocator.init);
    }

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

void triggerACoroutineExecution(size_t estimate = 0) @trusted {
    if(coroutinesForWorkers.empty)
        return;

    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(estimate == 0)
        triggerACoroutineMechanism(coroutinesForWorkers.count);
    else
        triggerACoroutineMechanism(estimate);
}

void addCoroutineTask(GenericCoroutine coroutine) @trusted {
    if(coroutine.isNull)
        return;

    final switch(coroutine.condition.waitingOn) {
    case CoroutineCondition.WaitingOn.Nothing:
        // nothing to wait on, yahoo!

        if(!coroutine.isComplete) {
            // is not complete, so we gotta put it in queue once again
            coroutinesForWorkers.push(coroutine);
            triggerACoroutineExecution(1);
        }
        break;
    case CoroutineCondition.WaitingOn.ExternalTrigger:
        // what? This shouldn't be possible (right now anyway).
        logger.error("Coroutine is waiting on an external trigger, but was ran ", Thread.self);
        assert(0);

    case CoroutineCondition.WaitingOn.Coroutine:
        mutex.pureLock;
        coroutinesWaitingOnOthers[coroutine.condition.coroutine] ~= coroutine;
        mutex.unlock;
        break;

    case CoroutineCondition.WaitingOn.SystemHandle:
        // TODO: register coroutine as waiting on something
        break;
    }
}

void coroutineCompletedTask(GenericCoroutine coroutine, ErrorResult errorResult) @trusted {
    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(errorResult) {
        // ok no error

        foreach(co; coroutinesWaitingOnOthers[coroutine]) {
            co.unsafeUnblock;
            coroutinesForWorkers.push(co);
        }
        coroutinesWaitingOnOthers.remove(coroutine);

        coroutinesForWorkers.push(coroutine);
        triggerACoroutineMechanism(coroutinesForWorkers.count);
    } else {
        logger.warning("Coroutine worker failed: ", errorResult, " on ", Thread.self);

        FiFoConcurrentQueue!GenericCoroutine queue;
        queue.push(coroutine);

        while(!queue.empty) {
            auto todo = queue.pop;
            if (!todo)
                continue;

            foreach(co; coroutinesWaitingOnOthers[todo]) {
                co.unsafeSetErrorResult(errorResult.getError());
                queue.push(co);
            }

            coroutinesWaitingOnOthers.remove(todo);
        }
    }
}
