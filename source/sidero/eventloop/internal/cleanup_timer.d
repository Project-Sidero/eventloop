module sidero.eventloop.internal.cleanup_timer;
import sidero.eventloop.sockets;
import sidero.eventloop.processes;
import sidero.eventloop.threads;
import sidero.eventloop.pipes;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.list.concurrentlinkedlist;
import sidero.base.synchronization.mutualexclusion;

__gshared {
    private {
        LoggerReference logger;
        TestTestSetLockInline mutex;

        FiFoConcurrentQueue!Socket socketRetryQueue;
        ConcurrentLinkedList!Process processList;
        ConcurrentLinkedList!ReadPipe toReadPipeList;

        version(Windows) {
            import sidero.eventloop.internal.windows.bindings;

            HANDLE timerHandle;
        } else version(Posix) {
            import sidero.base.internal.atomic;
            import core.sys.posix.pthread : pthread_cond_t, pthread_cond_broadcast, pthread_cond_signal,
                pthread_cond_destroy, pthread_cond_timedwait,
                pthread_cond_init, pthread_mutex_init, pthread_mutex_t, pthread_mutex_destroy, pthread_mutex_lock, pthread_mutex_unlock;

            version(linux) {
                import core.sys.linux.timerfd;
                import core.sys.posix.unistd : close;
                import core.sys.posix.sys.time : timeval, gettimeofday;

                int timerHandle;
            }

            Thread timerThread;
            pthread_cond_t timerCondition;
            pthread_mutex_t timerMutex;
            shared(bool) timerThreadInShutdown;
        }
    }
}

@safe nothrow @nogc:

bool startUpCleanupTimer() @trusted {
    import sidero.eventloop.internal.event_waiting;
    import core.stdc.errno;

    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(logger && !logger.isNull)
        return true;

    logger = Logger.forName(String_UTF8(__MODULE__));
    if(!logger)
        return false;
    logger.setLevel = LogLevel.Warning;

    version(Windows) {
        // unfortunately there can be a case where sockets need to be re-triggered at a later date
        // so lets use a waitable timer object to retrigger it

        timerHandle = CreateWaitableTimerW(null, false, null);
        if(timerHandle is null) {
            logger.warning("Error occured while attempting to create a waitable timer for retrying read/write ", WSAGetLastError());
            shutdownCleanupTimer;
            return false;
        }

        // Wait 1 seconds and then reactive every 1 seconds.
        // This use to be 15 seconds, but that is too long for pipes and HCI reasons.
        LARGE_INTEGER dueTime;
        dueTime.QuadPart = -10000000;

        if(SetWaitableTimer(timerHandle, &dueTime, 1_000, null, null, false) == 0) {
            logger.warning("Error occured while attempting to set time timer for retrying read/write ", WSAGetLastError());
            shutdownCleanupTimer;
            return false;
        }

        addEventWaiterHandle(timerHandle, &onTimerFunction, null);

    } else version(linux) {
        timerHandle = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
        if(timerHandle < 0) {
            logger.error("Could not create Linux cleanup timer ", errno);
            shutdownCleanupTimer;
            return false;
        }

        // reactivate every 5 seconds
        itimerspec spec;
        spec.it_value.tv_sec = 5;
        spec.it_interval.tv_sec = 5;

        timerfd_settime(timerHandle, 0, &spec, null);
        addEventWaiterHandle(cast(void*)timerHandle, &onTimerFunction, null);
    } else version(Posix) {
        atomicStore(timerThreadInShutdown, false);

        int err = pthread_cond_init(&timerCondition, null);
        if(err != 0) {
            logger.error("Failed to initialize Posix cleanup timer rearming condition ", err);
            shutdownCleanupTimer;
            return false;
        }

        err = pthread_mutex_init(&timerMutex, null);
        if(err != 0) {
            logger.error("Failed to initialize Posix cleanup timer rearming mutex ", err);
            shutdownCleanupTimer;
            return false;
        }

        auto gotThread = Thread.create(&timerThreadProc);
        if(!gotThread) {
            logger.error(gotThread);
            shutdownCleanupTimer;
            return false;
        }
        timerThread = gotThread;
    } else
        assert(0);

    logger.notice("Initialized Cleanup timer succesfully");
    return true;
}

pragma(crt_destructor) extern (C) void shutdownCleanupTimer() @trusted {
    import sidero.eventloop.internal.event_waiting;

    if(!logger || logger.isNull)
        return;

    socketRetryQueue = typeof(socketRetryQueue).init;

    version(Windows) {
        if(timerHandle !is null) {
            import sidero.eventloop.internal.event_waiting;

            removeEventWaiterHandle(timerHandle);
            CloseHandle(timerHandle);
        }

    } else version(linux) {
        removeEventWaiterHandle(cast(void*)timerHandle);
        close(timerHandle);
        timerHandle = 0;
    } else version(Posix) {
        atomicStore(timerThreadInShutdown, true);
        pthread_cond_broadcast(&timerCondition);
    } else
        assert(0);

    logger.notice("Shutdown cleanup timer");
}

void addSocketToRetrigger(Socket socket) @trusted {
    import sidero.base.internal.logassert;

    logAssert(startUpCleanupTimer, "Could not initialize cleanup timer");

    version(Windows) {
        socketRetryQueue.push(socket);
    } else
        assert(0);
}

void addProcessToList(Process process) @trusted {
    import sidero.base.internal.logassert;

    logAssert(startUpCleanupTimer, "Could not initialize cleanup timer");

    version(Posix) {
        processList ~= process;
    } else
        assert(0);
}

void addReadPipeToList(ReadPipe pipe) @trusted {
    import sidero.base.internal.logassert;

    logAssert(startUpCleanupTimer, "Could not initialize cleanup timer");
    toReadPipeList ~= pipe;
}

private:

void onTimerFunction(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    whenReady();
}

void timerThreadProc() @trusted {
    version(Posix) {
        import sidero.base.internal.atomic;

        logger.debug_("Posix cleanup rearm thread start");

        while(!atomicLoad(timerThreadInShutdown)) {
            pthread_mutex_lock(&timerMutex);
            bool doneOne;

            while(socketRetryQueue.empty && (processList.length == 0 || (processList.length > 0 && !doneOne)) &&
                    !atomicLoad(timerThreadInShutdown)) {
                doneOne = true;

                timeval now;
                gettimeofday(&now, null);

                timespec next;
                next.tv_sec = now.tv_sec + 5;
                pthread_cond_timedwait(&timerCondition, &timerMutex, &next);
            }

            logger.debug_("Posix cleanup rearm triggered");

            if(atomicLoad(timerThreadInShutdown)) {
                pthread_mutex_unlock(&timerMutex);
                pthread_cond_broadcast(&timerCondition);
                timerThread = Thread.init;

                logger.debug_("Socket rearm thread end");
                return;
            }

            pthread_mutex_unlock(&timerMutex);

            whenReady;
        }
    } else
        assert(0);
}

void whenReady() @trusted {
    logger.debug_("Cleanup timer start");

    size_t handledSockets, handlesProcesses;

    while(!socketRetryQueue.empty) {
        auto got = socketRetryQueue.pop;
        if(got) {
            handledSockets++;
            got.state.haveBeenRetriggered(got.state);
        }
    }

    version(Windows) {
        foreach(readPipe; toReadPipeList) {
            assert(readPipe);
            auto handle = readPipe.unsafeGetHandle();

            if(handle.isNull) {
                toReadPipeList.remove(readPipe);
                continue;
            }

            readPipe.state.guard(() @trusted {
                bool didRead = readPipe.state.rawReading.tryRead(readPipe.state);
                didRead = readPipe.state.rawReading.attemptRead(readPipe.state);

                if (readPipe.state.reading.tryFulfillRequest(readPipe.state)) {
                    toReadPipeList.remove(readPipe);
                }
            });
        }
    }

    version(Posix) {
        import sidero.eventloop.tasks.future_completion;
        import core.sys.posix.sys.wait : waitpid, WNOHANG, WIFEXITED, WEXITSTATUS, WIFSIGNALED, WTERMSIG;
        import core.stdc.errno : errno;

        foreach(process; processList) {
            assert(process);

            auto id = process.id;

            if(id == ProcessID.init) {
                processList.remove(process);
                handlesProcesses++;
            } else {
                int status;
                auto child = waitpid(id, &status, WNOHANG);

                logger.trace("Got child ", child, " for ", process, " with status ", status);

                if(child == id) {
                    int exitCode;

                    if(WIFEXITED(status)) {
                        exitCode = WEXITSTATUS(status);
                    } else if(WIFSIGNALED(status)) {
                        exitCode = -WTERMSIG(status);
                    }

                    logger.trace("Got child exit code ", exitCode, " for process ", process);

                    if(process.state.resultStorage !is null) {
                        auto error = trigger(process.state.resultStorage, exitCode);

                        if(!error)
                            logger.info("Could not trigger result for process ", process, " with error ", error);

                        process.state.resultStorage = null;
                    }

                    processList.remove(process);
                    handlesProcesses++;
                } else if(child < 0) {
                    // error
                    logger.info("Could not wait for result for process ", process, " with error ", errno);

                    auto error = trigger(process.state.resultStorage, UnknownPlatformBehaviorException("Failed to wait on process"));

                    if(!error)
                        logger.info("Could not trigger result for process ", process, " with error ", error);

                    process.state.resultStorage = null;
                    processList.remove(process);
                    handlesProcesses++;
                }
            }
        }
    }

    logger.debug_("Cleanup timer handled ", handledSockets, " sockets, ", handlesProcesses, " processes");
}
