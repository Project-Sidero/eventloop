module sidero.eventloop.internal.posix.event_waiting;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.threads;
import sidero.base.containers.dynamicarray;

@safe nothrow @nogc:

struct EventWaiterThread {
    Thread thread;

    shared(bool) isAlive;

    DynamicArray!(void*) nextEventHandles, eventHandles;
    DynamicArray!(UserEventHandler) nextEventProcs, eventProcs;

    version(Posix) {
        import core.sys.posix.poll;
        import core.sys.posix.unistd;

        int[2] candcPipes;
        pollfd[128] pollfds;
    }

@safe nothrow @nogc:

    this(return scope ref EventWaiterThread other) scope {
        this.tupleof = other.tupleof;
    }

    void handleReSet() scope {
        version(Posix) {
            this.eventHandles = this.nextEventHandles;
            this.eventProcs = this.nextEventProcs;

            foreach(i, eh; this.eventHandles) {
                pollfds[i + 1].fd = eh;
                pollfds[i + 1].events = int.max;
                pollfds[i + 1].revents = 0;
            }
        }
    }

    void ourProc() scope @trusted {
        version(Posix) {
            import sidero.base.internal.atomic;
            import core.sys.posix.fcntl;

            const err = pipe(candcPipes);
            if(err != 0)
                return;
            fcntl(candcPipes[0], F_SETFL, O_NONBLOCK | FD_CLOEXEC);

            scope(exit) {
                close(candcPipes[0]);
                close(candcPipes[1]);
                candcPipes[0] = null;
                candcPipes[1] = null;

                atomicStore(this.isAlive, false);
            }

            while(atomicLoad(this.isAlive)) {
                if(!this.nextEventHandles.isNull)
                    handleReSet();

                const err = poll(pollfds.ptr, eventHandles.length + 1, -1);

                switch(err) {
                default:
                    assert(err > 0);
                    // check for revents member

                    foreach(i, ref pfd; pollfds[1 .. eventHandles.length]) {
                        auto eventProc = this.eventProcs[i];
                        assert(eventProc);

                        int revent = pfd.revents;
                        eventProc.proc(pfd.handle, eventProc.user, &revent);

                        pfd.revents = 0;
                    }

                    if(pollfds[0].revents != 0) {
                        // need to rehandle setting

                        int dummy;
                        read(candcPipes[0], &dummy, 4);

                        handleReSet();
                        pollfds[0].revents = 0;
                    }
                    break;

                case 0:
                    // ok, timeout (not used)
                    break;

                case -1:
                    // some unknown error, ughhh
                    break;
                }
            }
        }
    }
}

bool initializePlatformEventWaiting() {
    version(Posix) {
        return true;
    } else
        return false;
}

size_t maximumNumberOfHandlesPerEventWaiter() {
    // We'll keep this number fairly small, but larger than what Windows offers.
    // Poll is typically implemented under the hood quite linearly, so a large number is pretty bad.
    // It will also need to be - 1, due to one handle assigned to C&C.
    return 128 - 1;
}

void triggerUpdatesOnThreads(size_t oldThreadCount) {
    version(Posix) {
        // step five: wake up threads and set the handles to the new ones
        foreach(threadState; eventWaiterThreads) {
            assert(threadState);
            if(threadState.nextEventHandles.isNull || threadState.candcPipes[1] is null)
                continue;

            int dummy;
            write(threadState.candcPipes[1], &dummy, 4);
        }
    } else
        assert(0);
}

void shutdownEventWaiterThreadsMechanism() {
    version(Posix) {
        import sidero.base.internal.atomic;

        auto lockError = eventWaiterMutex.lock;
        assert(lockError);

        foreach(threadState; eventWaiterThreads) {
            assert(threadState);
            atomicStore(threadState.isAlive, false);

            // we don't care if the event loop cycles just at the right time
            // to make this write fail.
            // in that scenario it still did its job
            if(threadState.candcPipes[1]!is null) {
                int dummy = 1;
                write(threadState.candcPipes[1], &dummy, 4);
            }
        }

        foreach(threadState; eventWaiterThreads) {
            assert(threadState);
            cast(void)threadState.thread.join();
        }

        eventWaiterThreads = typeof(eventWaiterThreads).init;
        eventWaiterMutex.unlock;
    } else
        assert(0);
}
