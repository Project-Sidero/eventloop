module sidero.eventloop.internal.windows.event_waiting;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.threads;
import sidero.base.containers.dynamicarray;
import sidero.base.attributes;
import sidero.base.text;

@safe nothrow @nogc:

version (Windows) {
    size_t maximumNumberOfHandlesPerEventWaiter() {
        import core.sys.windows.windows : MAXIMUM_WAIT_OBJECTS;

        return MAXIMUM_WAIT_OBJECTS;
    }

    void shutdownEventWaiterThreadsMechanism() @trusted {
        import core.sys.windows.windows : QueueUserAPC, GetLastError, MAXIMUM_WAIT_OBJECTS, ULONG_PTR;
        import core.atomic : atomicStore;

        extern (Windows) static void stopAcceptingProc(ULONG_PTR) {
        }

        auto lockError = eventWaiterMutex.lock;
        assert(lockError);

        foreach (threadState; eventWaiterThreads) {
            assert(threadState);
            atomicStore(threadState.isAlive, false);

            if (QueueUserAPC(&stopAcceptingProc, threadState.threadHandle, 0) == 0) {
                logger.error("Error failed to send shutdown APC with code", threadState.get, GetLastError());
            } else {
                logger.trace("Triggered shutdown APC for accept thread", threadState.get);
            }
        }

        foreach (threadState; eventWaiterThreads) {
            assert(threadState);
            cast(void)threadState.thread.join;
        }

        eventWaiterThreads = typeof(eventWaiterThreads).init;
        eventWaiterMutex.unlock;
    }

    void triggerUpdatesOnThreads(size_t oldThreadCount) @trusted {
        import core.sys.windows.windows : ULONG_PTR, QueueUserAPC, GetLastError;

        extern (Windows) static void updateHandlesProc(ULONG_PTR state) {
            auto lockError = eventWaiterMutex.lock;
            assert(lockError);

            auto threadState = cast(EventWaiterThread*)state;
            logger.trace("Updating event waiter thread handles as lengths", threadState.thread,
                    threadState.nextEventHandles.length, threadState.nextEventProcs.length);

            threadState.eventHandles = threadState.nextEventHandles;
            threadState.eventProcs = threadState.nextEventProcs;

            threadState.nextEventHandles = typeof(threadState.nextEventHandles).init;
            threadState.nextEventProcs = typeof(threadState.nextEventProcs).init;

            eventWaiterMutex.unlock;
        }

        // step five: wake up threads and set the handles to the new ones
        foreach (threadState; eventWaiterThreads) {
            assert(threadState);
            if (threadState.nextEventHandles.isNull)
                continue;

            if (QueueUserAPC(&updateHandlesProc, threadState.threadHandle, cast(size_t)&threadState.get()) == 0) {
                logger.error("Error failed to send stop waiting APC with code", threadState.get, GetLastError());
            } else {
                logger.trace("Triggered update handles APC", threadState.get, threadState.nextEventHandles.length,
                        threadState.nextEventProcs.length);
            }
        }
    }

    struct EventWaiterThread {
        Thread thread;
        void* threadHandle;
        shared(bool) isAlive = true;

        DynamicArray!(void*) nextEventHandles, eventHandles;
        DynamicArray!(UserEventHandler) nextEventProcs, eventProcs;

    @safe nothrow @nogc:

        this(return scope ref EventWaiterThread other) scope {
            this.tupleof = other.tupleof;
        }

        void ourProc() @trusted {
            import core.atomic : atomicLoad, atomicStore;
            import core.sys.windows.windows : SleepEx, INFINITE, DuplicateHandle, GetCurrentProcess, GetCurrentThread,
                DUPLICATE_SAME_ACCESS,
                WaitForMultipleObjectsEx, WAIT_OBJECT_0, WAIT_TIMEOUT, WAIT_IO_COMPLETION, WAIT_FAILED, GetLastError,
                ERROR_INVALID_HANDLE, HANDLE, MAXIMUM_WAIT_OBJECTS;

            logger.trace("Starting event waiter thread", thread);

            scope (exit) {
                atomicStore(isAlive, false);
                logger.trace("Ending event waiter thread", thread);
            }

            if (DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &this.threadHandle, 0,
                    false, DUPLICATE_SAME_ACCESS) == 0) {
                logger.error("Failed to aquire a thread handle for an event waiting thread with code", GetLastError());
                return;
            } else {
                logger.trace("Acquired thread handle for an event waiting thread", thread);
            }

            while (atomicLoad(this.isAlive)) {
                if (this.eventHandles.length == 0) {
                    auto result = SleepEx(INFINITE, true);

                    logger.trace("Got event waiting thread event from sleep", thread, result);

                    switch (result) {
                    case WAIT_IO_COMPLETION:
                        break;
                    default:
                        break;
                    }
                } else {
                    auto result = WaitForMultipleObjectsEx(cast(uint)this.eventHandles.length,
                            cast(HANDLE*)this.eventHandles.ptr, false, INFINITE, true);

                    switch (result) {
                    case WAIT_TIMEOUT:
                        logger.trace("Event waiter timeout", thread);
                        break;
                    case WAIT_IO_COMPLETION:
                        logger.trace("Event waiter got event io completion", thread);
                        break;
                    case WAIT_FAILED:
                        switch (GetLastError()) {
                        case ERROR_INVALID_HANDLE:
                            // its probably ok, we'll handle this later, make sure APC's run via sleeping
                            SleepEx(0, true);
                            break;
                        default:
                            logger.error("Failed to wait on event wait thread with code", thread, GetLastError());
                            return;
                        }
                        break;

                    case WAIT_OBJECT_0: .. case WAIT_OBJECT_0 + MAXIMUM_WAIT_OBJECTS:
                        auto handleIndex = result - WAIT_OBJECT_0;

                        auto gotHandle = eventHandles[handleIndex];
                        if (!gotHandle) {
                            logger.error("Failed to get event handle data", thread, handleIndex, gotHandle);
                            return;
                        }

                        auto gotUserProc = eventProcs[handleIndex];
                        if (!gotUserProc) {
                            logger.error("Failed to get event user proc data", thread, handleIndex, gotUserProc);
                            return;
                        }

                        logger.trace("Got event for event handle", thread, handleIndex, gotHandle, gotUserProc);

                        gotUserProc.proc(gotHandle, gotUserProc.user);
                        break;
                    default:
                        logger.trace("Got unknown event from wait", thread, result);
                        break;
                    }
                }
            }
        }
    }
}
