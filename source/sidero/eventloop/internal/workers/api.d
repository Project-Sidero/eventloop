module sidero.eventloop.internal.workers.api;
import sidero.eventloop.threads;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.coroutine.condition;
import kernelwait = sidero.eventloop.internal.workers.kernelwait.api;
import userland = sidero.eventloop.internal.workers.userland.api;
import sidero.base.system : cpuCount;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.map.duplicatehashmap;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.allocators;
import sidero.base.errors;
import sidero.base.synchronization.system.lock;
import sidero.base.internal.atomic;

export @safe nothrow @nogc:

__gshared {
    private {
        SystemLock mutex;
        shared(bool) isInitialized;

        bool useKernelWait, useUserLand;

        DynamicArray!Thread threadPool;
        LoggerReference logger;

        DuplicateHashMap!(GenericCoroutine, GenericCoroutine) coroutinesWaitingOnOthers;

        size_t maxWorkerThreads;
        void function() @safe nothrow @nogc workerProc;
    }

    package(sidero.eventloop.internal) {
        FiFoConcurrentQueue!GenericCoroutine coroutinesForWorkers;
    }
}

bool usesKernelWait() @trusted {
    return useKernelWait;
}

bool checkWorkerInit() @trusted {
    if(atomicLoad(isInitialized))
        return true;

    mutex.lock.assumeOkay;
    scope(exit)
        mutex.unlock;

    logger = Logger.forName(String_UTF8(__MODULE__));
    if(!logger)
        return false;
    logger.setLevel = LogLevel.Warning;

    mutex.unlock;
    configureWorkerMultiplier(2);
    mutex.lock.assumeOkay;

    if(kernelwait.initializeWorkerMechanism(maxWorkerThreads)) {
        logger.info("Workers using kernel mechanism");
        useKernelWait = true;
        workerProc = &kernelwait.workerProc;
    } else if(userland.initializeWorkerMechanism(maxWorkerThreads)) {
        logger.info("Workers using userland mechanism");
        useUserLand = true;
        workerProc = &userland.workerProc;
    } else
        return false;

    startAWorker;

    atomicStore(isInitialized, true);
    return true;
}

void shutdownWorkers() @trusted {
    mutex.lock.assumeOkay;
    scope(exit)
        mutex.unlock;

    if(!isInitialized)
        return;

    logger.notice("Shutting down of workers");

    if(useKernelWait)
        kernelwait.shutdownWorkerMechanism;
    else if(useUserLand)
        userland.shutdownWorkerMechanism;
    else
        assert(0);

    foreach(thread; threadPool) {
        for(;;) {
            auto got = thread.join();
            if(got)
                break;
        }

        assert(!thread.isNull);
        assert(!thread.isRunning);
    }

    foreach(from; coroutinesWaitingOnOthers) {
        foreach(on; coroutinesWaitingOnOthers[from]) {
            on.unsafeSetErrorResult(ErrorInfo(ShuttingStateDownException));
        }

        from.unsafeSetErrorResult(ErrorInfo(ShuttingStateDownException));
    }

    logger.notice("All worker threads have been joined");

    threadPool = typeof(threadPool).init;
    coroutinesWaitingOnOthers = typeof(coroutinesWaitingOnOthers).init;
    isInitialized = false;
    workerProc = null;
}

void configureWorkerMultiplier(size_t workerMultiplier) @trusted {
    mutex.lock.assumeOkay;
    scope(exit)
        mutex.unlock;

    const oldCount = maxWorkerThreads;
    const newCount = workerMultiplier * cpuCount();

    if(oldCount > 0) {
        if(newCount > oldCount) {
            logger.notice("Configuring for additional workers, using multiplier ", workerMultiplier,
                    " for an additional ", newCount - oldCount, " to form ", newCount, " workers");
        } else if(newCount == oldCount) {
            logger.debug_("Not configuring for additional workers as the old count is the same as the new one with a multipler ",
                    workerMultiplier, " for a total of ", newCount, " workers");
            return;
        } else {
            logger.debug_("Attempted to configure for additional workers, but the calculated new workers were less than the old ones ",
                    newCount, " but was ", oldCount);
            return;
        }
    } else
        logger.notice("Configuring for workers, using multiplier ", workerMultiplier, " for a total of ", newCount, " workers");

    const neededCapacity = newCount - threadPool.capacity;
    if(threadPool.capacity < neededCapacity)
        threadPool.reserve(neededCapacity);

    maxWorkerThreads = newCount;
}

bool isWorkerThread(Thread other) @trusted {
    mutex.lock.assumeOkay;
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

    mutex.lock.assumeOkay;
    scope(exit)
        mutex.unlock;

    if(estimate == 0)
        estimate = coroutinesForWorkers.count;

    if(useKernelWait)
        kernelwait.triggerACoroutineMechanism(estimate);
    else if(useUserLand)
        userland.triggerACoroutineMechanism(estimate);
    else
        assert(0);
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
        mutex.lock.assumeOkay;

        auto conditionToContinue = coroutine.condition.coroutine;

        if(conditionToContinue.isComplete) {
            logger.debug_("Adding coroutine task on ", Thread.self, " and condition is complete");
            // condition is complete (could be null)
            coroutine.unsafeUnblock;
            coroutinesForWorkers.push(coroutine);
            triggerACoroutine(1);
        } else {
            logger.debug_("Adding coroutine task on ", Thread.self, " and condition is not complete");
            coroutinesWaitingOnOthers[conditionToContinue] ~= coroutine;
        }

        mutex.unlock;
        break;
    }
}

void coroutineCompletedTask(GenericCoroutine coroutine, ErrorResult errorResult) @trusted {
    checkWorkerInit;
    mutex.lock.assumeOkay;

    if(errorResult) {
        // ok no error
        logger.debug_("Coroutine worker success on ", Thread.self);

        foreach(co; coroutinesWaitingOnOthers[coroutine]) {
            logger.debug_("Got dependent on coroutine");
            co.unsafeUnblock;
            coroutinesForWorkers.push(co);
        }
        coroutinesWaitingOnOthers.remove(coroutine);
        triggerACoroutine(coroutinesForWorkers.count);

        mutex.unlock;
        addCoroutineTask(coroutine);
    } else {
        logger.debug_("Coroutine worker failed: ", errorResult, " on ", Thread.self);

        foreach(co; coroutinesWaitingOnOthers[coroutine]) {
            co.unsafeSetErrorResult(errorResult.getError());
            coroutinesForWorkers.push(co);
        }
        coroutinesWaitingOnOthers.remove(coroutine);

        triggerACoroutine(coroutinesForWorkers.count);
        mutex.unlock;
    }
}

void debugWorkers() @trusted {
    mutex.lock.assumeOkay;

    import sidero.base.console;

    writeln("\\/---- workers ---- \\/");

    foreach(from; coroutinesWaitingOnOthers) {
        from.debugMe("from");

        foreach(on; coroutinesWaitingOnOthers[from]) {
            on.debugMe("-");
        }
    }

    writeln("/\\---- workers ---- /\\");
    mutex.unlock;
}

package(sidero.eventloop.internal):

// NOTE: must be guarded
void startAWorker() @trusted {
    if(threadPool.length >= maxWorkerThreads)
        return;

    auto thread = Thread.create(workerProc);

    if(thread)
        threadPool ~= thread.get;
    else
        logger.error("Could not create worker thread ", thread.getError());
}

private:

void triggerACoroutine(size_t count) @trusted {
    if(useKernelWait) {
        kernelwait.triggerACoroutineMechanism(count);
    } else if(useUserLand) {
        userland.triggerACoroutineMechanism(count);
    } else
        assert(0);
}
