module sidero.eventloop.internal.event_waiting.api;
import sidero.base.synchronization.system.lock;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.internal.logassert;

export @safe nothrow @nogc:

private {
    __gshared {
        LoggerReference logger;
        SystemLock eventWaiterMutex;

        bool useThreaded, useLinux;
    }
}

alias UserEventProc = void function(void* handle, void* user, scope void* eventResponsePtr) @safe nothrow @nogc;

void addEventWaiterHandle(void* handleToWaitOn, UserEventProc proc, void* user) @trusted {
    assert(handleToWaitOn !is null);
    assert(proc !is null);

    if (guardEventWaiting(null)) {
        version (linux) {
            if (useLinux) {
                import sidero.eventloop.internal.event_waiting.linux;

                addEventWaiterHandleStrategy(handleToWaitOn, proc, user);
                return;
            }
        }

        {
            import sidero.eventloop.internal.event_waiting.threaded.api;

            addEventWaiterHandleStrategy(handleToWaitOn, proc, user);
        }
    }
}

void removeEventWaiterHandle(scope void* handleToNotWaitOn) @trusted {
    if (guardEventWaiting(null)) {
        version (linux) {
            if (useLinux) {
                import sidero.eventloop.internal.event_waiting.linux;

                removeEventWaiterHandleStrategy(handleToNotWaitOn);
                return;
            }
        }

        {
            import sidero.eventloop.internal.event_waiting.threaded.api;

            removeEventWaiterHandleStrategy(handleToNotWaitOn);
        }
    }
}

void shutdownEventWaiterThreads() @trusted {
    if (guardEventWaiting(null)) {
        import sidero.eventloop.internal.cleanup_timer;

        shutdownCleanupTimer();

        version (linux) {
            if (useLinux) {
                import sidero.eventloop.internal.event_waiting.linux;

                shutdownEventWaiterThreadsStrategy();
                return;
            }
        }

        {
            import sidero.eventloop.internal.event_waiting.threaded.api;

            shutdownEventWaiterThreadsStrategy();
        }
    }
}

package(sidero.eventloop.internal.event_waiting) {
    bool guardEventWaiting(Del)(scope Del del) @trusted {
        import sidero.base.system : operatingSystem, OperatingSystem;

        auto lockError = eventWaiterMutex.lock;
        logAssert(cast(bool)lockError, null, lockError.getError());

        scope (exit)
            eventWaiterMutex.unlock;

        if (!logger || logger.isNull) {
            logger = Logger.forName(String_UTF8(__MODULE__));
            if (!logger)
                return false;

            useThreaded = true;
            useLinux = false;

            {
                version (linux) {
                    OperatingSystem os = operatingSystem();

                    // EPOLLEXCLUSIVE was added in 4.5
                    // epoll_create1 was added in 2.6.27 (we'll splify that to 2.7 as there are other bugs)

                    // TODO: not implemented currently
                    /+if (os.major > 4 || (os.major == 4 && os.minor >= 5))
                        useLinux = true;+/
                }
            }

            logAssert(useThreaded || useLinux, "Could not setup event waiting mechanism for unknown platform");

            if (useLinux) {
                import sidero.eventloop.internal.event_waiting.linux;

                initializeLinuxEventWaiting();
            } else if (useThreaded) {
                import sidero.eventloop.internal.event_waiting.threaded.api;

                initializeThreadedEventWaiting();
            }
        }

        static if (!is(Del == typeof(null))) {
            if (del !is null)
                del();
        }

        return true;
    }
}
