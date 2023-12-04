module sidero.eventloop.networking.internal.posix.mechanism;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.threads;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.containers.queue.concurrentqueue;

__gshared {
    package(sidero.eventloop.networking.internal.posix) {
        LoggerReference logger;
    }

    private {
        FiFoConcurrentQueue!Socket socketRetryQueue;

        version(linux) {
            import core.sys.linux.timerfd;
            import core.sys.posix.unistd : close;
            import core.sys.posix.sys.time : timeval, gettimeofday;

            int timerHandle;
        }

        version(Posix) {
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

@safe nothrow @nogc:

bool startUpNetworkingMechanism() @trusted {
    version(Posix) {
        logger = Logger.forName(String_UTF8(__MODULE__));
        if(!logger)
            return false;
    }

    version(linux) {
        {
            import sidero.eventloop.internal.event_waiting;

            timerHandle = timerfd_create(CLOCK_REALTIME, TFD_CLOEXEC);

            // reactivate every 15 seconds
            itimerspec spec;
            spec.it_value.tv_sec = time_t.max;
            spec.it_interval.tv_sec = 15;

            timerfd_settime(timerHandle, TFD_NONBLOCK | TFD_CLOEXEC, &spec, null);
            addEventWaiterHandle(cast(void*)timerHandle, &onTimerFunction, null);

            logger.notice("Initialized Linux socket rearming succesfully");
        }
    } else version(Posix) {
        {
            atomicStore(timerThreadInShutdown, false);

            int err = pthread_cond_init(&timerCondition, null);
            if(err != 0) {
                logger.error("Failed to initialize Posix socket rearming condition ", err);
                return false;
            }

            err = pthread_mutex_init(&timerMutex, null);
            if(err != 0) {
                logger.error("Failed to initialize Posix socket rearming mutex ", err);
                return false;
            }

            timerThread = Thread.create(&timerThreadProc);

            logger.notice("Initialized Posix socket rearming succesfully");
        }
    } else
        assert(0);

    return true;
}

void shutdownNetworkingMechanism() @trusted {
    version(linux) {
        import sidero.eventloop.internal.event_waiting;

        removeEventWaiterHandle(cast(void*)timerHandle);
        close(timerHandle);
        timerHandle = 0;

        logger.notice("Shutdown Linux socket rearming");
    } else version(Posix) {
        atomicStore(timerThreadInShutdown, true);
        pthread_cond_broadcast(&timerCondition);
        logger.notice("Shutdown Posix socket rearming");
    } else
        assert(0);
}

void addSocketToRetrigger(Socket socket) @trusted {
    version(Posix) {
        socketRetryQueue.push(socket);
    } else
        assert(0);
}

private:

void onTimerFunction(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version(linux) {
        logger.debug_("Socket timer callback start");
        size_t handled;

        while(!socketRetryQueue.empty) {
            auto got = socketRetryQueue.pop;
            if(got) {
                handled++;
                got.state.haveBeenRetriggered(got.state);
            }
        }

        logger.debug_("Socket timer callback handled ", handled);
    } else
        assert(0);
}

void timerThreadProc() @trusted {
    version(Posix) {
        import sidero.base.internal.atomic;
        logger.debug_("Socket rearm thread start");

        while(!atomicLoad(timerThreadInShutdown)) {
            pthread_mutex_lock(&timerMutex);
            while(socketRetryQueue.empty && !atomicLoad(timerThreadInShutdown)) {
                timeval now;
                gettimeofday(&now, null);

                timespec next;
                next.tv_sec = now.tv_sec + 15;
                pthread_cond_timedwait(&timerCondition, &timerMutex, &next);
            }

            logger.debug_("Socket rearm triggered");

            if(atomicLoad(timerThreadInShutdown)) {
                pthread_mutex_unlock(&timerMutex);
                pthread_cond_broadcast(&timerCondition);
                timerThread = Thread.init;

                logger.debug_("Socket rearm thread end");
                return;
            }

            pthread_mutex_unlock(&timerMutex);

            size_t handled;

            while(!socketRetryQueue.empty) {
                auto got = socketRetryQueue.pop;
                if(got) {
                    handled++;
                    got.state.haveBeenRetriggered(got.state);
                }
            }

            logger.debug_("Socket rearm thread handled ", handled);
        }
    }
}
