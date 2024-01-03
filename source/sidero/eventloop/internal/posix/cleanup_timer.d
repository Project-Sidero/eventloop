module sidero.eventloop.internal.posix.cleanup_timer;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.threads;
import sidero.eventloop.processes.defs;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.list.concurrentlinkedlist;
import sidero.base.synchronization.mutualexclusion : TestTestSetLockInline;
import sidero.base.errors;

export @safe nothrow @nogc:

__gshared {
    private {
        LoggerReference logger;
        TestTestSetLockInline mutex;

        ConcurrentLinkedList!Process processList;
        FiFoConcurrentQueue!Socket socketRetryQueue;

        version (linux) {
            import core.sys.linux.timerfd;
            import core.sys.posix.unistd : close;
            import core.sys.posix.sys.time : timeval, gettimeofday;

            int timerHandle;
        }

        version (Posix) {
            import sidero.base.internal.atomic;
            import core.sys.posix.pthread : pthread_cond_t, pthread_cond_broadcast, pthread_cond_signal,
                pthread_cond_destroy, pthread_cond_timedwait,
                pthread_cond_init, pthread_mutex_init, pthread_mutex_t, pthread_mutex_destroy, pthread_mutex_lock, pthread_mutex_unlock;

            Thread timerThread;
            pthread_cond_t timerCondition;
            pthread_mutex_t timerMutex;
            shared(bool) timerThreadInShutdown;
        }
    }
}

void addSocketToRetrigger(Socket socket) @trusted {
    version (Posix) {
        socketRetryQueue.push(socket);
    } else
        assert(0);
}

void addProcessToList(Process process) @trusted {
    version (Posix) {
        requireCleanupTimer;
        processList ~= process;
    } else
        assert(0);
}

void removeProcessFromList(Process process) @trusted {
    version (Posix) {
        processList.remove(process);
    } else
        assert(0);
}

void requireCleanupTimer() @trusted {
    version (Posix) {
        mutex.lock;

        scope (exit)
            mutex.unlock;

        if (!logger || logger.isNull) {
            logger = Logger.forName(String_UTF8(__MODULE__));
            if (!logger)
                return;

            version (none) {
                {
                    import sidero.eventloop.internal.event_waiting;

                    timerHandle = timerfd_create(CLOCK_REALTIME, TFD_CLOEXEC);

                    // reactivate every 5 seconds
                    itimerspec spec;
                    spec.it_value.tv_sec = time_t.max;
                    spec.it_interval.tv_sec = 5;

                    timerfd_settime(timerHandle, TFD_NONBLOCK | TFD_CLOEXEC, &spec, null);
                    addEventWaiterHandle(cast(void*)timerHandle, &onTimerFunction, null);

                    logger.notice("Initialized Linux socket rearming succesfully");
                }
            } else {
                {
                    atomicStore(timerThreadInShutdown, false);

                    int err = pthread_cond_init(&timerCondition, null);
                    if (err != 0) {
                        logger.error("Failed to initialize Posix socket rearming condition ", err);
                        return;
                    }

                    err = pthread_mutex_init(&timerMutex, null);
                    if (err != 0) {
                        logger.error("Failed to initialize Posix socket rearming mutex ", err);
                        return;
                    }

                    auto gotThread = Thread.create(&timerThreadProc);
                    if (!gotThread) {
                        logger.error(gotThread);
                        return;
                    }
                    timerThread = gotThread;

                    logger.notice("Initialized Posix socket rearming succesfully");
                    return;
                }
            }
        }
    }
}

pragma(crt_destructor) extern (C) void deinitializeCleanupTimer() @trusted {
    if (!logger || !logger.isNull) {
        socketRetryQueue = typeof(socketRetryQueue).init;

        version (none) {
            import sidero.eventloop.internal.event_waiting;

            removeEventWaiterHandle(cast(void*)timerHandle);
            close(timerHandle);
            timerHandle = 0;

            logger.notice("Shutdown Linux socket rearming");
        } else version (Posix) {
            atomicStore(timerThreadInShutdown, true);
            pthread_cond_broadcast(&timerCondition);
            logger.notice("Shutdown Posix socket rearming");
        } else
            assert(0);
    }
}

private:

void onTimerFunction(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version (linux) {
        whenReady;
    } else
        assert(0);
}

void timerThreadProc() @trusted {
    version (Posix) {
        import sidero.base.internal.atomic;

        logger.debug_("Posix cleanup rearm thread start");

        while (!atomicLoad(timerThreadInShutdown)) {
            pthread_mutex_lock(&timerMutex);
            bool doneOne;

            while (socketRetryQueue.empty && (processList.length == 0 || (processList.length > 0 && !doneOne)) &&
                    !atomicLoad(timerThreadInShutdown)) {
                doneOne = true;

                timeval now;
                gettimeofday(&now, null);

                timespec next;
                next.tv_sec = now.tv_sec + 5;
                pthread_cond_timedwait(&timerCondition, &timerMutex, &next);
            }

            logger.debug_("Posix cleanup rearm triggered");

            if (atomicLoad(timerThreadInShutdown)) {
                pthread_mutex_unlock(&timerMutex);
                pthread_cond_broadcast(&timerCondition);
                timerThread = Thread.init;

                logger.debug_("Socket rearm thread end");
                return;
            }

            pthread_mutex_unlock(&timerMutex);

            whenReady;
        }
    }
}

void whenReady() @trusted {
    version (Posix) {
        import sidero.eventloop.tasks.future_completion;
        import core.sys.posix.sys.wait : waitpid, WNOHANG, WIFEXITED, WEXITSTATUS, WIFSIGNALED, WTERMSIG;
        import core.stdc.errno : errno;

        logger.debug_("Posix cleanup timer start");

        size_t handledSockets, handlesProcesses;

        while (!socketRetryQueue.empty) {
            auto got = socketRetryQueue.pop;
            if (got) {
                handledSockets++;
                got.state.haveBeenRetriggered(got.state);
            }
        }

        foreach (process; processList) {
            assert(process);

            auto id = process.id;

            if (id == ProcessID.init) {
                processList.remove(process);
                handlesProcesses++;
            } else {
                int status;
                auto child = waitpid(id, &status, WNOHANG);

                logger.trace("Got child ", child, " for ", process, " with status ", status);

                if (child == id) {
                    int exitCode;

                    if (WIFEXITED(status)) {
                        exitCode = WEXITSTATUS(status);
                    } else if (WIFSIGNALED(status)) {
                        exitCode = -WTERMSIG(status);
                    }

                    logger.trace("Got child exit code ", exitCode, " for process ", process);

                    if (process.state.resultStorage !is null) {
                        auto error = trigger(process.state.resultStorage, exitCode);

                        if (!error)
                            logger.info("Could not trigger result for process ", process, " with error ", error);

                        process.state.resultStorage = null;
                    }

                    processList.remove(process);
                    handlesProcesses++;
                } else if (child < 0) {
                    // error
                    logger.info("Could not wait for result for process ", process, " with error ", errno);

                    auto error = trigger(process.state.resultStorage, UnknownPlatformBehaviorException("Failed to wait on process"));

                    if (!error)
                        logger.info("Could not trigger result for process ", process, " with error ", error);

                    process.state.resultStorage = null;
                    processList.remove(process);
                    handlesProcesses++;
                }
            }
        }

        logger.debug_("Posix cleanup timer handled ", handledSockets, " sockets, ", handlesProcesses, " processes");
    }
}
