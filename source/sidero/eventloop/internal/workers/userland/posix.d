module sidero.eventloop.internal.workers.userland.posix;
import sidero.eventloop.internal.workers;
import sidero.eventloop.threads;
import sidero.base.internal.atomic;
import sidero.base.logger;
import sidero.base.text;

@safe nothrow @nogc:

private {
    __gshared {
        shared(bool) workersInShutdown;
        shared(int) countAliveThreads;
        LoggerReference logger;
    }

    version (Posix) {
        import core.sys.posix.pthread : pthread_cond_t, pthread_cond_broadcast, pthread_cond_signal,
            pthread_cond_destroy, pthread_cond_init,
            pthread_mutex_init, pthread_mutex_t, pthread_mutex_destroy, pthread_mutex_lock, pthread_mutex_unlock, pthread_cond_wait;

        __gshared {
            pthread_cond_t workerCondition;
            pthread_mutex_t workersWorkMutex;
        }
    }
}

bool initializeWorkerPlatformMechanism(size_t count) @trusted {
    version (Posix) {
        atomicStore(workersInShutdown, false);

        logger = Logger.forName(String_UTF8(__MODULE__));
        if (!logger)
            return false;
        logger.setLevel(LogLevel.Warning);

        int err = pthread_cond_init(&workerCondition, null);
        if (err != 0) {
            logger.error("Failed to initialize Posix worker condition ", err);
            return false;
        }

        err = pthread_mutex_init(&workersWorkMutex, null);
        if (err != 0) {
            logger.error("Failed to initialize Posix worker mutex ", err);
            return false;
        }

        logger.notice("Initialized Posix workers succesfully");
        return true;
    } else
        return false;
}

void shutdownWorkerPlatformMechanism() @trusted {
    version (Posix) {
        if (atomicLoad(countAliveThreads) == 0) {
            logger.debug_("Shutdown Posix workers immediately");
        }

        atomicStore(workersInShutdown, true);
        pthread_cond_broadcast(&workerCondition);

        while (atomicLoad(countAliveThreads) > 0) {
            Thread.yield;
        }

        pthread_cond_destroy(&workerCondition);
        pthread_mutex_destroy(&workersWorkMutex);

        logger.notice("Shutdown Posix workers");
    }
}

void triggerACoroutineMechanism(size_t count) @trusted {
    version (Posix) {
        logger.debug_("Triggering a Posix worker to wakeup");
        pthread_cond_signal(&workerCondition);
    }
}

void workerProc() @trusted {
    version (Posix) {
        atomicIncrementAndLoad(countAliveThreads, 1);
        scope (exit) {
            logger.info("Stopping Posix worker ", Thread.self);

            atomicDecrementAndLoad(countAliveThreads, 1);
        }

        logger.info("Starting Posix worker ", Thread.self);

        for (;;) {
            checkForMoreThreadsToSpinUp;

            pthread_mutex_lock(&workersWorkMutex);
            while (coroutinesForWorkers.empty && !atomicLoad(workersInShutdown)) {
                pthread_cond_wait(&workerCondition, &workersWorkMutex);
            }

            if (atomicLoad(workersInShutdown)) {
                pthread_mutex_unlock(&workersWorkMutex);
                pthread_cond_broadcast(&workerCondition);
                return;
            }

            auto workToDo = coroutinesForWorkers.pop;

            if (!coroutinesForWorkers.empty)
                pthread_cond_signal(&workerCondition);
            pthread_mutex_unlock(&workersWorkMutex);

            if (workToDo && !workToDo.isNull) {
                logger.debug_("Got coroutine work ", Thread.self);

                auto errorResult = workToDo.unsafeResume;
                coroutineCompletedTask(workToDo, errorResult);
            }
        }
    }
}
