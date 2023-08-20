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

    if (workerMultiplier == 0) {
        if (isInitialized)
            return true;
        workerMultiplier = 2;
    }

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
        } else if(newCount == oldCount) {
            logger.debug_("Not starting additional workers as the old count is the same as the new one with a multipler ",
                    workerMultiplier, " for a total of ", newCount, " workers");
            return true;
        } else {
            logger.debug_("Attempted to start additional workers, but the calculated new workers were less than the old ones ",
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
            logger.debug_("Adding coroutine task on ", Thread.self, " and is ready");

            // is not complete, so we gotta put it in queue once again
            coroutinesForWorkers.push(coroutine);
            triggerACoroutineExecution(1);
        } else {
            logger.debug_("Coroutine task on ", Thread.self, " is complete");
        }
        break;
    case CoroutineCondition.WaitingOn.ExternalTrigger:
        // what? This shouldn't be possible (right now anyway).
        logger.error("Coroutine is waiting on an external trigger, but was ran ", Thread.self);
        assert(0);

    case CoroutineCondition.WaitingOn.Coroutine:
        mutex.pureLock;

        auto conditionToContinue = coroutine.condition.coroutine;

        if(conditionToContinue.isComplete) {
            logger.debug_("Adding coroutine task on ", Thread.self, " and condition is complete");
            // condition is complete (could be null)
            coroutine.unsafeUnblock;
            coroutinesForWorkers.push(coroutine);
            triggerACoroutineMechanism(1);
        } else {
            logger.debug_("Adding coroutine task on ", Thread.self, " and condition is not complete");
            coroutinesWaitingOnOthers[conditionToContinue] ~= coroutine;
        }

        mutex.unlock;
        break;
    }
}

void coroutineCompletedTask(GenericCoroutine coroutine, ErrorResult errorResult) @trusted {
    mutex.pureLock;

    if(errorResult) {
        // ok no error
        logger.debug_("Coroutine worker success on ", Thread.self);

        foreach(co; coroutinesWaitingOnOthers[coroutine]) {
            logger.debug_("Got dependent on coroutine");
            co.unsafeUnblock;
            coroutinesForWorkers.push(co);
        }
        coroutinesWaitingOnOthers.remove(coroutine);
        triggerACoroutineMechanism(coroutinesForWorkers.count);

        mutex.unlock;
        addCoroutineTask(coroutine);
    } else {
        logger.debug_("Coroutine worker failed: ", errorResult, " on ", Thread.self);

        foreach(co; coroutinesWaitingOnOthers[coroutine]) {
            co.unsafeSetErrorResult(errorResult.getError());
            coroutinesForWorkers.push(co);
        }
        coroutinesWaitingOnOthers.remove(coroutine);

        triggerACoroutineMechanism(coroutinesForWorkers.count);
        mutex.unlock;
    }
}
