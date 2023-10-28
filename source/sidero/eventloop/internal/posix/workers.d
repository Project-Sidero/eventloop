module sidero.eventloop.internal.posix.workers;
import sidero.eventloop.internal.workers;
import sidero.base.internal.atomic;

@safe nothrow @nogc:

private {
    __gshared {
        shared(bool) workersInShutdown;
        shared(int) countAliveThreads;
    }

    version(Posix) {
        import core.sys.posix.pthread : pthread_cond_t, pthread_cond_broadcast, pthread_cond_signal, pthread_cond_destroy,
            pthread_cond_init, pthread_mutex_init, pthread_mutex_t, pthread_mutex_destroy, pthread_mutex_lock, pthread_mutex_unlock;

        __gshared {
            pthread_cond_t workerCondition;
            pthread_mutex_t workersWorkMutex;
        }
    }
}

void shutdownWorkerMechanism() {
    version(Posix) {
        if(atomicLoad(countAliveThreads) == 0) {
            pthread_cond_destroy(&workerCondition);
            pthread_mutex_destroy(&workersWorkMutex);
            logger.debug_("Shutdown Posix workers immediately");
        }

        atomicStore(workersInShutdown, true);
        pthread_cond_broadcast(&workerCondition);
        logger.notice("Shutdown Posix workers");
    }
}

bool initializeWorkerMechanism(size_t count) {
    version(Posix) {
        atomicStore(workersInShutdown, false);

        int err = pthread_cond_init(&workerCondition, null);
        if(err != 0) {
            logger.error("Failed to initialize Posix worker condition ", err);
            return false;
        }

        err = pthread_mutex_init(&workersWorkMutex, null);
        if(err != 0) {
            logger.error("Failed to initialize Posix worker mutex ", err);
            return false;
        }

        logger.notice("Initialized Posix workers succesfully");
        return true;
    } else
        return false;
}

void triggerACoroutineMechanism(size_t count) {
    version(Posix) {
        logger.debug_("Triggering a Posix worker to wakeup");
        pthread_cond_signal(&workerCondition);
    }
}

void workerProc() {
    version(Posix) {
        atomicIncrementAndLoad(countAliveThreads, 1);
        scope(exit) {
            logger.info("Stopping Posix worker ", Thread.self);

            if(atomicDecrementAndLoad(countAliveThreads, 1) == 0 && atomicLoad(workersInShutdown)) {
                pthread_cond_destroy(&workerCondition);
                pthread_mutex_destroy(&workersWorkMutex);
            }
        }

        logger.info("Starting Posix worker ", Thread.self);

        for(;;) {
            pthread_mutex_lock(&workersWorkMutex);
            while(coroutinesForWorkers.empty && !atomicLoad(workersInShutdown)) {
                pthread_cond_wait(&workersCondition, &workersWorkMutex);
            }

            if(atomicLoad(workersInShutdown)) {
                pthread_mutex_unlock(&workersWorkMutex);
                pthread_cond_broadcast(&workerCondition);
                return;
            }

            auto workToDo = coroutinesForWorkers.pop;

            if(!coroutinesForWorkers.empty)
                pthread_cond_signal(&workerCondition);
            pthread_mutex_unlock(&workersWorkMutex);

            if(workToDo && !workToDo.isNull) {
                logger.debug_("Got coroutine work ", Thread.self);

                auto errorResult = workToDo.unsafeResume;
                coroutineCompletedTask(workToDo, errorResult);
            }
        }
    }
}
