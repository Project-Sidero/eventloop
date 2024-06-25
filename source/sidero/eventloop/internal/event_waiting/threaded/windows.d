module sidero.eventloop.internal.event_waiting.threaded.windows;
import sidero.eventloop.internal.event_waiting.threaded.api;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.threads;
import sidero.base.containers.dynamicarray;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.internal.atomic;

export @safe nothrow @nogc:

private __gshared {
    LoggerReference logger;
}

struct EventWaiterThread {
    Thread thread;
    void* threadHandle;

    shared(bool) isAlive;

    DynamicArray!(void*) nextEventHandles, eventHandles;
    DynamicArray!(UserEventHandler) nextEventProcs, eventProcs;

@safe nothrow @nogc:

    this(return scope ref EventWaiterThread other) scope {
        this.tupleof = other.tupleof;
    }

    void opAssign(return scope EventWaiterThread other) scope {
        this.destroy;
        this.__ctor(other);
    }

    void ourProc() @trusted {
        version(Windows) {
            import core.sys.windows.winbase : SleepEx, INFINITE, DuplicateHandle, GetCurrentProcess, GetCurrentThread,
                WaitForMultipleObjectsEx, WAIT_OBJECT_0, WAIT_IO_COMPLETION, WAIT_FAILED, GetLastError, MAXIMUM_WAIT_OBJECTS, CloseHandle;
            import core.sys.windows.winnt : DUPLICATE_SAME_ACCESS, WAIT_TIMEOUT, ERROR_INVALID_HANDLE, HANDLE;

            logger.info("Starting event waiter thread ", thread);
            atomicStore(isAlive, true);

            scope(exit) {
                atomicStore(isAlive, false);
                logger.info("Ending event waiter thread ", thread);
            }

            if(DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &this.threadHandle, 0,
                    false, DUPLICATE_SAME_ACCESS) == 0) {
                logger.warning("Failed to arquire a thread handle for an event waiting thread with code ", GetLastError());
                return;
            } else {
                logger.debug_("Acquired thread handle for an event waiting thread ", thread);
            }

            scope(exit)
                CloseHandle(this.threadHandle);

            while(atomicLoad(this.isAlive)) {
                if(this.eventHandles.length == 0) {
                    auto result = SleepEx(INFINITE, true);

                    logger.debug_("Got event waiting thread event from sleep with code ", result, " on ", thread);

                    switch(result) {
                    case WAIT_IO_COMPLETION:
                        break;
                    default:
                        break;
                    }
                } else {
                    auto result = WaitForMultipleObjectsEx(cast(uint)this.eventHandles.length,
                            cast(HANDLE*)this.eventHandles.ptr, false, INFINITE, true);

                    switch(result) {
                    case WAIT_TIMEOUT:
                        logger.debug_("Event waiter timeout ", thread);
                        break;
                    case WAIT_IO_COMPLETION:
                        logger.debug_("Event waiter got event io completion ", thread);
                        break;
                    case WAIT_FAILED:
                        const errorCode = GetLastError();

                        switch(errorCode) {
                        case ERROR_INVALID_HANDLE:
                            // its probably ok, we'll handle this later, make sure APC's run via sleeping
                            SleepEx(0, true);
                            break;
                        default:
                            logger.warning("Failed to wait on event wait thread with code ", errorCode, " on ", thread);
                            return;
                        }
                        break;

                    case WAIT_OBJECT_0: .. case WAIT_OBJECT_0 + MAXIMUM_WAIT_OBJECTS:
                        const handleIndex = result - WAIT_OBJECT_0;
                        auto gotHandle = eventHandles[handleIndex];
                        auto gotUserProc = eventProcs[handleIndex];

                        if(!gotHandle) {
                            logger.warning("Failed to get event handle data ", handleIndex, " on ", thread);
                            return;
                        }

                        if(!gotUserProc) {
                            logger.warning("Failed to get event user proc data ", handleIndex, " on ", thread);
                            return;
                        }

                        logger.debug_("Got event for event handle ", gotHandle, " with procedure ", gotUserProc, " on ", thread);
                        gotUserProc.proc(gotHandle, gotUserProc.user, null);
                        break;
                    default:
                        logger.debug_("Got unknown event from wait ", result, " on ", thread);
                        break;
                    }
                }
            }
        } else
            assert(0);
    }
}

bool initializePlatformEventWaiting() @trusted {
    version(Windows) {
        logger = Logger.forName(String_UTF8(__MODULE__));
        return cast(bool)logger;
    } else
        return false;
}

size_t maximumNumberOfHandlesPerEventWaiter() {
    version(Windows) {
        import core.sys.windows.winbase : MAXIMUM_WAIT_OBJECTS;

        return MAXIMUM_WAIT_OBJECTS;
    } else
        assert(0);
}

void triggerUpdatesOnThreads(size_t oldThreadCount) @trusted {
    version(Windows) {
        import core.sys.windows.winbase : QueueUserAPC, GetLastError;
        import core.sys.windows.basetsd : ULONG_PTR;

        extern (Windows) static void updateHandlesProc(ULONG_PTR state) {
            guardEventWaiting(() {
                auto threadState = cast(EventWaiterThread*)state;
                logger.debug_("Updating event waiter thread handles as lengths handles ", threadState.nextEventHandles.length,
                    " procedures ", threadState.nextEventProcs.length, " for ", threadState.thread);

                threadState.eventHandles = threadState.nextEventHandles;
                threadState.eventProcs = threadState.nextEventProcs;

                threadState.nextEventHandles = typeof(threadState.nextEventHandles).init;
                threadState.nextEventProcs = typeof(threadState.nextEventProcs).init;
            });
        }

        // step five: wake up threads and set the handles to the new ones
        foreach(threadState; eventWaiterThreads) {
            assert(threadState);
            if(threadState.nextEventHandles.isNull)
                continue;

            if(QueueUserAPC(&updateHandlesProc, threadState.threadHandle, cast(size_t)&threadState.get()) == 0) {
                logger.warning("Failed to send stop waiting APC with code ", GetLastError(), " to ", threadState.thread);
            } else {
                logger.debug_("Triggered update handles APC handles ", threadState.nextEventHandles.length,
                        " procedures ", threadState.nextEventProcs.length, " to ", threadState.thread);
            }
        }
    } else
        assert(0);
}

void shutdownEventWaiterThreadsMechanism() @trusted {
    version(Windows) {
        import sidero.base.datetime.duration;
        import core.sys.windows.basetsd : ULONG_PTR;
        import core.sys.windows.winbase : QueueUserAPC, GetLastError, MAXIMUM_WAIT_OBJECTS;

        extern (Windows) static void stopAcceptingProc(ULONG_PTR) {
        }

        guardEventWaiting(() {
            foreach(threadState; eventWaiterThreads) {
                assert(threadState);
                atomicStore(threadState.isAlive, false);

                if(QueueUserAPC(&stopAcceptingProc, threadState.threadHandle, 0) == 0) {
                    logger.warning("Failed to send shutdown APC with code ", GetLastError(), " to ", threadState.thread);
                } else {
                    logger.debug_("Triggered shutdown APC for accept thread ", threadState.thread);
                }
            }
        });

        foreach(threadState; eventWaiterThreads) {
            assert(threadState);
            cast(void)threadState.thread.join();
        }

        eventWaiterThreads = typeof(eventWaiterThreads).init;
    } else
        assert(0);
}
