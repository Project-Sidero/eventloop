module sidero.eventloop.internal.event_waiting.api;
import sidero.eventloop.threads;
import sidero.base.synchronization.system.lock;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.internal.logassert;
import sidero.base.containers.map.hashmap;

export @safe nothrow @nogc:

__gshared {
    HashMap!(void*, UserEventHandler) allEventHandles;

    private {
        LoggerReference logger;
        SystemLock eventWaiterMutex;

        bool useThreaded, useLinux;
    }
}

struct UserEventHandler {
    UserEventProc proc;
    void* user;
}

alias UserEventProc = void function(void* handle, void* user, scope void* eventResponsePtr) @safe nothrow @nogc;

void addEventWaiterHandle(void* handleToWaitOn, UserEventProc proc, void* user) @trusted {
    assert(handleToWaitOn !is null);
    assert(proc !is null);

    bool needToAdd;

    if (guardEventWaiting(() {
            if (handleToWaitOn !in allEventHandles) {
                logger.trace("Adding handle to wait on events for ", handleToWaitOn, " for proc ", proc, " with user ",
                user, " on thread ", Thread.self);
                allEventHandles[handleToWaitOn] = UserEventHandler(proc, user);
                needToAdd = true;
            } else {
                logger.debug_("Adding handle to wait on events already exists for ", handleToWaitOn, " on thread ", Thread.self);
            }
        })) {

        if (!needToAdd)
            return;

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
    if (guardEventWaiting(() {
            logger.trace("Removing handle to wait on events for ", handleToNotWaitOn, " on thread ", Thread.self);
            allEventHandles.remove(handleToNotWaitOn);
        })) {
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

        allEventHandles = typeof(allEventHandles).init;
    }
}

package(sidero.eventloop.internal) {
    bool guardEventWaiting(Del)(scope Del del) @trusted {
        import linuxeventwait = sidero.eventloop.internal.event_waiting.linux;
        import threadedeventwait = sidero.eventloop.internal.event_waiting.threaded.api;

        import sidero.eventloop.internal.workers.api : startWorkers, usesKernelWait;
        import sidero.base.system : operatingSystem, OperatingSystem;

        auto lockError = eventWaiterMutex.lock;
        logAssert(cast(bool)lockError, null, lockError.getError());

        scope (exit)
            eventWaiterMutex.unlock;

        if (!logger || logger.isNull) {
            logger = Logger.forName(String_UTF8(__MODULE__));
            if (!logger)
                return false;

            if (linuxeventwait.initializeLinuxEventWaiting())
                useLinux = true;
            else if (threadedeventwait.initializeThreadedEventWaiting())
                useThreaded = true;
            else
                logAssert(false, "Could not setup event waiting mechanism for an unknown platform");
        }

        static if (!is(Del == typeof(null))) {
            if (del !is null)
                del();
        }

        return true;
    }
}
