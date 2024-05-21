module sidero.eventloop.internal.event_waiting.threaded.api;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.threads;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.map.hashmap;
import sidero.base.containers.map.concurrenthashmap;
import sidero.base.logger;
import sidero.base.internal.logassert;
import sidero.base.attributes;
import sidero.base.errors;
import sidero.base.text;

export @safe nothrow @nogc:

version (Windows) {
    import sidero.eventloop.internal.event_waiting.threaded.windows;
} else version (Posix) {
    import sidero.eventloop.internal.event_waiting.threaded.posix;
} else
    static assert(0, "Unimplemented");

struct UserEventHandler {
    UserEventProc proc;
    void* user;
}

// minimal demonstration of what is required
version (none) {
    struct EventWaiterThread {
        Thread thread;

        shared(bool) isAlive;

        DynamicArray!(void*) nextEventHandles, eventHandles;
        DynamicArray!(UserEventHandler) nextEventProcs, eventProcs;

    @safe nothrow @nogc:

        this(return scope ref EventWaiterThread other) scope {
            this.tupleof = other.tupleof;
        }

        void ourProc() nothrow {
        }
    }

    bool initializePlatformEventWaiting() {
        return false;
    }

    size_t maximumNumberOfHandlesPerEventWaiter() {
        return 0;
    }

    void triggerUpdatesOnThreads(size_t oldThreadCount) {
    }

    void shutdownEventWaiterThreadsMechanism() {
    }
}

__gshared {
    package(sidero.eventloop.internal.event_waiting.threaded) {
        ConcurrentHashMap!(ulong, EventWaiterThread) eventWaiterThreads;
        HashMap!(void*, UserEventHandler) allEventHandles;
    }

    private {
        LoggerReference logger;
    }
}

void initializeThreadedEventWaiting() @trusted {
    logger = Logger.forName(String_UTF8(__MODULE__));
    logAssert(cast(bool)logger, "Could not initialize threaded event waiting logger", logger.getError());
    logAssert(cast(bool)initializePlatformEventWaiting(), "Could not initialize threaded event waiting platform support");
}

void addEventWaiterHandleStrategy(void* handleToWaitOn, UserEventProc proc, void* user) {
    assert(handleToWaitOn !is null);
    assert(proc !is null);

    guardEventWaiting(() {
        if(handleToWaitOn !in allEventHandles) {
            logger.trace("Adding handle to wait on events for ", handleToWaitOn, " for proc ", proc, " with user ", user, " on thread ", Thread.self);
            allEventHandles[handleToWaitOn] = UserEventHandler(proc, user);
            updateEventWaiterThreads;
        } else {
            logger.debug_("Adding handle to wait on events already exists for ", handleToWaitOn, " on thread ", Thread.self);
        }
    });
}

void removeEventWaiterHandleStrategy(scope void* handleToNotWaitOn) {
    guardEventWaiting(() {
        allEventHandles.remove(handleToNotWaitOn);
        updateEventWaiterThreads;
    });
}

alias shutdownEventWaiterThreadsStrategy = shutdownEventWaiterThreadsMechanism;

private @hidden:

void updateEventWaiterThreads() @trusted {
    import sidero.base.internal.atomic;

    logger.debug_("Updating event waiter thread handles");
    const maxEventHandles = maximumNumberOfHandlesPerEventWaiter();

    {
        // step one: cleanup old threads that are no longer alive
        foreach(threadState; eventWaiterThreads) {
            assert(threadState);
            if(!atomicLoad(threadState.isAlive) || !threadState.thread.isRunning) {
                logger.debug_("Removing dead event waiter thread ", threadState.thread);
                eventWaiterThreads.remove(threadState.thread.toHash());
            }
        }
    }

    DynamicArray!(void*) tempHandles;
    DynamicArray!UserEventHandler tempProcs;

    {
        // step two: construct the arrays that'll be passed to the threads
        logger.debug_("Have ", allEventHandles.length, " event handles to wait for");

        tempHandles.length = allEventHandles.length;
        tempProcs.length = allEventHandles.length;
        assert(tempHandles.length == allEventHandles.length);
        assert(tempProcs.length == allEventHandles.length);
        assert(tempHandles.length == tempProcs.length);

        size_t offset;
        foreach(handle, proc; allEventHandles) {
            assert(handle);
            assert(proc);

            cast(void)(tempHandles[offset] = handle.assumeOkay);
            cast(void)(tempProcs[offset] = proc.assumeOkay);
            offset++;
        }

        logger.trace("Have set ", offset, " event handles to wait for");
    }

    {
        // step three: give each waiter thread its new handles
        foreach(threadState; eventWaiterThreads) {
            assert(threadState);

            if(tempHandles.length > maxEventHandles) {
                logger.trace("Consuming ", maxEventHandles, " of ", tempHandles.length, " event handles to wait for");

                assert(tempHandles.length == tempProcs.length);
                threadState.nextEventHandles = tempHandles[0 .. maxEventHandles];
                threadState.nextEventProcs = tempProcs[0 .. maxEventHandles];
                assert(threadState.nextEventHandles.length == threadState.nextEventProcs.length);

                tempHandles = tempHandles[maxEventHandles .. $];
                tempProcs = tempProcs[maxEventHandles .. $];
                assert(tempHandles.length == tempProcs.length);
            } else {
                logger.trace("Consuming ", tempHandles.length, " event handles to wait for");

                assert(tempHandles.length == tempProcs.length);
                threadState.nextEventHandles = tempHandles;
                threadState.nextEventProcs = tempProcs;
                assert(threadState.nextEventHandles.length == threadState.nextEventProcs.length);

                tempHandles = typeof(tempHandles).init;
                tempProcs = typeof(tempProcs).init;
            }
        }
    }

    {
        // step four: start up new threads to complete the handles

        while(tempHandles.length > 0) {
            DynamicArray!(void*) currentHandles;
            DynamicArray!UserEventHandler currentProcs;

            if(tempHandles.length > maxEventHandles) {
                logger.trace("Consuming ", maxEventHandles, " of ", tempHandles.length, " event handles to wait for");

                assert(tempHandles.length == tempProcs.length);
                currentHandles = tempHandles[0 .. maxEventHandles];
                currentProcs = tempProcs[0 .. maxEventHandles];
                assert(currentHandles.length == currentProcs.length);

                tempHandles = tempHandles[maxEventHandles .. $];
                tempProcs = tempProcs[maxEventHandles .. $];
                assert(tempHandles.length == tempProcs.length);
            } else {
                logger.trace("Consuming ", tempHandles.length, " event handles to wait for");

                assert(tempHandles.length == tempProcs.length);
                currentHandles = tempHandles;
                currentProcs = tempProcs;
                assert(currentHandles.length == currentProcs.length);

                tempHandles = typeof(tempHandles).init;
                tempProcs = typeof(tempProcs).init;
                assert(tempHandles.length == tempProcs.length);
            }

            auto gotThread = Thread.create(&threadStartProc, currentHandles, currentProcs);
            if(!gotThread) {
                logger.warning("Thread failed to be created, stopping event waiting updating ", gotThread.getError());
                break;
            }
        }
    }

    triggerUpdatesOnThreads(eventWaiterThreads.length);
    logger.debug_("Updated event waiting threads and handles");
}

void threadStartProc(DynamicArray!(void*) tempHandles, DynamicArray!UserEventHandler tempProcs) @trusted {
    Thread self = Thread.self;
    ResultReference!EventWaiterThread threadState;

    guardEventWaiting(() {
        const key = self.toHash();

        logger.debug_("Event waiting thread starting ", self);

        eventWaiterThreads[key] = EventWaiterThread.init;
        threadState = eventWaiterThreads[key];
        assert(threadState);

        threadState.thread = self;
        threadState.nextEventHandles = tempHandles;
        threadState.nextEventProcs = tempProcs;

    });

    scope(exit) {
        logger.debug_("Event waiting thread finished ", self);
    }

    threadState.ourProc();
}
