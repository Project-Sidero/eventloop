module sidero.eventloop.internal.event_waiting.threaded.posix;
import sidero.eventloop.internal.event_waiting.threaded.api;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.threads;
import sidero.base.containers.dynamicarray;
import sidero.base.logger;
import sidero.base.text;

version (Posix) {
    import core.sys.posix.unistd;
}

export @safe nothrow @nogc:

private __gshared {
    LoggerReference logger;
}

struct EventWaiterThread {
    Thread thread;

    shared(bool) isAlive;

    DynamicArray!(void*) nextEventHandles, eventHandles;
    DynamicArray!(UserEventHandler) nextEventProcs, eventProcs;

    version (Posix) {
        import core.sys.posix.poll;

        int[2] candcPipes;
        pollfd[128] pollfds;
    }

@safe nothrow @nogc:

    this(return scope ref EventWaiterThread other) scope {
        this.tupleof = other.tupleof;
    }

    void opAssign(return scope EventWaiterThread other) scope {
        this.destroy;
        this.__ctor(other);
    }

    void handleReSet() scope {
        version (Posix) {
            assert(this.nextEventHandles.length == this.nextEventProcs.length);

            this.eventHandles = this.nextEventHandles;
            this.eventProcs = this.nextEventProcs;

            this.nextEventHandles = typeof(this.nextEventHandles).init;
            this.nextEventProcs = typeof(this.nextEventProcs).init;

            foreach (i, eh; this.eventHandles) {
                pollfds[i + 1].fd = cast(int)eh;
                pollfds[i + 1].events = short.max;
                pollfds[i + 1].revents = 0;
            }
        }
    }

    void ourProc() scope @trusted {
        version (Posix) {
            import sidero.base.internal.atomic;
            import core.sys.posix.fcntl;

            logger.info("Starting event waiter thread ", thread);
            atomicStore(isAlive, true);

            scope (exit) {
                atomicStore(isAlive, false);

                if (candcPipes[0] != 0) {
                    close(candcPipes[0]);
                    close(candcPipes[1]);
                }

                candcPipes[0] = 0;
                candcPipes[1] = 0;

                logger.info("Ending event waiter thread ", thread);
            }

            {
                const err = pipe(candcPipes);
                if (err != 0)
                    return;

                fcntl(candcPipes[0], F_SETFL, O_NONBLOCK | FD_CLOEXEC);
                fcntl(candcPipes[1], F_SETFL, O_NONBLOCK | FD_CLOEXEC);

                pollfds[0].fd = candcPipes[0];
                pollfds[0].events = short.max;

                foreach (i, eh; this.eventHandles) {
                    pollfds[i + 1].fd = cast(int)eh;
                    pollfds[i + 1].events = short.max;
                }
            }

            while (atomicLoad(this.isAlive)) {
                logger.debug_("Event waiter poll starting ", pollfds[0 .. eventHandles.length + 1]);
                const err = poll(pollfds.ptr, eventHandles.length + 1, -1);
                logger.debug_("Event waiter poll complete ", err, " ", pollfds[0 .. eventHandles.length + 1]);

                switch (err) {
                default:
                    assert(err > 0);
                    // check for revents member

                    foreach (i, ref pfd; pollfds[1 .. eventHandles.length + 1]) {
                        auto eventProc = this.eventProcs[i];
                        assert(eventProc);

                        if (pfd.revents != 0) {
                            logger.debug_("Got event for event handle ", cast(void*)pfd.fd, " with procedure ",
                            eventProc.proc, " and user ", eventProc.user, " on ", thread);

                            int revent = pfd.revents;
                            eventProc.proc(cast(void*)pfd.fd, eventProc.user, &revent);

                            pfd.revents = 0;
                        }
                    }

                    if (pollfds[0].revents != 0) {
                        // need to rehandle setting

                        if ((pollfds[0].revents & POLLIN) == POLLIN) {
                            int dummy;
                            auto result = read(candcPipes[0], &dummy, 4);
                            handleReSet();
                        }

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

bool initializePlatformEventWaiting() @trusted {
    version (Posix) {
        logger = Logger.forName(String_UTF8(__MODULE__));
        if (!logger)
            return false;

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

void triggerUpdatesOnThreads(size_t oldThreadCount) @trusted {
    version (Posix) {
        import sidero.base.internal.atomic;
        import core.stdc.errno;

        // step five: wake up threads and set the handles to the new ones
        foreach (threadState; eventWaiterThreads) {
            assert(threadState);
            assert(threadState.nextEventHandles.length == threadState.nextEventProcs.length);

            if (threadState.nextEventHandles.isNull || !atomicLoad(threadState.isAlive))
                continue;

            while (atomicLoad(threadState.isAlive) && threadState.candcPipes[1] == 0) {
                Thread.yield;
            }

            int dummy;
            if (write(threadState.candcPipes[1], &dummy, 4) < 4) {
                logger.info("Failed to trigger update by writing to ", threadState.thread, " with error ", errno);
            } else {
                logger.debug_("Triggered update handles for handles ", threadState.nextEventHandles.length,
                        " procedures ", threadState.nextEventProcs.length, " to ", threadState.thread);
            }
        }
    } else
        assert(0);
}

void shutdownEventWaiterThreadsMechanism() @trusted {
    version (Posix) {
        import sidero.base.internal.atomic;

        guardEventWaiting(() {
            foreach (threadState; eventWaiterThreads) {
                assert(threadState);
                atomicStore(threadState.isAlive, false);

                // we don't care if the event loop cycles just at the right time
                // to make this write fail.
                // in that scenario it still did its job
                if (threadState.candcPipes[1] != 0) {
                    int dummy = 1;
                    write(threadState.candcPipes[1], &dummy, 4);
                    logger.debug_("Triggered shutdown write for accept thread ", threadState.thread);
                }
            }
        });

        foreach (threadState; eventWaiterThreads) {
            assert(threadState);
            auto got = threadState.thread.join();
            if (!got)
                logger.error("Failed to join event waiter thread ", threadState.thread, " ", got);
        }

        eventWaiterThreads = typeof(eventWaiterThreads).init;
        logger.notice("Shutdown all event waiter threads");
    } else
        assert(0);
}
