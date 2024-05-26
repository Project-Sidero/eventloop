module sidero.eventloop.internal.workers.kernelwait.linux;
import sidero.eventloop.internal.workers.api;
import sidero.eventloop.internal.event_waiting.api;
import sidero.eventloop.threads;
import sidero.base.internal.atomic;
import sidero.base.logger;
import sidero.base.text;

version (Posix) {
    import core.sys.linux.epoll;
    import core.sys.linux.sys.eventfd;
    import core.stdc.errno;

    private {
        __gshared {
            LoggerReference logger;
            int epollContext, workFd;
            uint requiredWorkers;
        }

        shared(bool) isInProcessOfDieing;
        shared(ptrdiff_t) runningWorkers;
        shared(ptrdiff_t) startedWorkers;
    }
}

// epoll_create1 was added in 2.6.27 (we'll splify that to 2.7 as there are other bugs)

@safe nothrow @nogc:

bool initializeWorkerPlatformMechanism(size_t numberOfWorkers) @trusted {
    import sidero.base.system : operatingSystem, OperatingSystem;

    OperatingSystem os = operatingSystem();

    version (linux) {
        import core.sys.posix.unistd : close;

        atomicStore(isInProcessOfDieing, false);

        // EPOLLEXCLUSIVE was added in 4.5
        if ((os.major < 4 || (os.major == 4 && os.minor < 5)))
            return false;

        {
            logger = Logger.forName(String_UTF8(__MODULE__));
            if (!logger || logger.isNull)
                return false;
            logger.setLevel = LogLevel.Warning;

            requiredWorkers = cast(uint)numberOfWorkers;
        }

        {
            epollContext = epoll_create1(EPOLL_CLOEXEC);

            if (epollContext < 0) {
                const error = errno;

                switch (error) {
                case EINVAL:
                case EMFILE:
                case ENFILE:
                case ENODEV:
                case ENOMEM:
                    logger.notice("Failed to create EPOLL context due to environment ", error, " on thread ", Thread.self);
                    break;

                default:
                    logger.notice("Unknown error during creation of EPOLL context ", error, " on thread ", Thread.self);
                    break;
                }

                return false;
            }
        }

        {
            workFd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);

            if (workFd < 0) {
                const error = errno;

                switch (error) {
                case EINVAL:
                case EMFILE:
                case ENFILE:
                case ENODEV:
                case ENOMEM:
                    logger.notice("Failed to create event FD for EPOLL due to environment with error ", error, " on thread ", Thread.self);
                    break;

                default:
                    logger.notice("Unknown error during creation of event FD for EPOLL ", error, " on thread ", Thread.self);
                    break;
                }

                close(epollContext);
                return false;
            } else if (!addEpollHandleToWaitOn(workFd)) {
                logger.notice("Attempted to initialize EPOLL worker work FD and failed");
                close(workFd);
                close(epollContext);
                return false;
            }
        }

        return true;
    } else
        return false;
}

void shutdownWorkerPlatformMechanism() @trusted {
    version (linux) {
        import core.sys.posix.unistd : close;

        atomicStore(isInProcessOfDieing, true);

        while (atomicLoad(startedWorkers) != requiredWorkers) {
            Thread.yield;
        }

        {
            // This should result in the waits failing, and threads death.
            close(workFd);
            close(epollContext);
        }

        logger.notice("Shutdown EPOLL context for workers successfully");
    } else
        assert(0);
}

void triggerACoroutineMechanism(size_t count) @trusted {
    version (linux) {
        logger.debug_("Posting coroutine work times ", count);

        foreach (_; 0 .. count) {
            int result = eventfd_write(workFd, 1);

            if (result != 0) {
                logger.warning("EPOLL workers could not send coroutine execution message");
                return;
            }
        }
    } else
        assert(0);
}

void workerProc() @trusted {
    version (linux) {
        logger.info("Starting EPOLL worker ", Thread.self);

        atomicIncrementAndLoad(startedWorkers, 1);
        atomicIncrementAndLoad(runningWorkers, 1);
        scope (exit) {
            atomicDecrementAndLoad(runningWorkers, 1);
            logger.info("Stopping EPOLL worker ", Thread.self);
        }

        epoll_event[128] eventBuffer;
        UserEventHandler[128] handlers;

        Loop: for (;;) {
            int result = epoll_wait(epollContext, eventBuffer.ptr, cast(int)eventBuffer.length, -1);
            logger.debug_("EPOLL worker thread got ", result, " ", Thread.self);

            if (result < 0) {
                switch (errno) {
                case EINTR:
                    // signal but that's fine
                    break;

                default:
                    // EBADF or EINVAL would suggest that we are dieing. So die.
                    break Loop;
                }
            } else {
                guardEventWaiting(() {
                    foreach (i, ref ev; eventBuffer[0 .. result]) {
                        if (ev.events != 0) {
                            int handle = eventBuffer[i].data.fd;

                            if (handle != workFd) {
                                auto got = allEventHandles[cast(void*)handle];

                                if (got)
                                    handlers[i] = got;
                                else
                                    ev.events = 0;
                            }
                        }
                    }
                });

                foreach (i, ref ev; eventBuffer[0 .. result]) {
                    if (ev.events != 0) {
                        int handle = eventBuffer[i].data.fd;

                        if (handle == workFd) {
                            if (ev.events & EPOLLRDHUP || ev.events & EPOLLHUP) {
                                break Loop;
                            } else if (ev.events & EPOLLIN || ev.events & EPOLLRDNORM) {
                                logger.debug_("Got coroutine work ", Thread.self);

                                eventfd_t cAndCCommand;
                                result = eventfd_read(handle, &cAndCCommand);
                                if (result < 0)
                                    logger.debug_("Failed to read from C&C work FD EPOLL on thread ", Thread.self);

                                auto workToDo = coroutinesForWorkers.pop;

                                if (workToDo && !workToDo.isNull) {
                                    auto errorResult = workToDo.unsafeResume;
                                    coroutineCompletedTask(workToDo, errorResult);
                                }
                            }

                            ev.events = 0;
                        } else {
                            logger.debug_("Seeing FD work ", handle, " for proc ", handlers[i].proc, " user ",
                                    handlers[i].user, " with events ", ev.events, " on thread ", Thread.self);

                            handlers[i].proc(cast(void*)handle, handlers[i].user, &ev.events);
                            ev.events = 0;
                        }
                    }
                }
            }
        }
    } else
        assert(0);
}

bool addEpollHandleToWaitOn(int handle) @trusted {
    logger.trace("Attempting to add FD handle ", handle, " for EPOLL ", epollContext, " on thread ", Thread.self);

    version (linux) {
        // EPOLLEXCLUSIVE was added in 4.5

        if (atomicLoad(isInProcessOfDieing))
            return false;

        epoll_event event;
        event.events = EPOLLIN | EPOLLHUP | EPOLLERR | EPOLLEXCLUSIVE | EPOLLET;
        event.data.fd = handle;

        const result = epoll_ctl(epollContext, EPOLL_CTL_ADD, handle, &event);
        if (result == 0)
            return true;

        const error = errno;

        switch (error) {
        case EEXIST:
            // ok, ignore it!
            logger.debug_("FD handle to add wait for EPOLL on already exists ", handle, " on thread ", Thread.self);
            break;

        case EPERM:
            // unsupported fd
            logger.warning("FD handle to add wait for EPOLL is not supported ", handle, " on thread ", Thread.self);
            break;

        case EBADF:
        case EINVAL:
        case ELOOP:
        case ENOMEM:
        case ENOSPC:
            // welp something is wrong in environment
            logger.warning("The current environment has erroneous state for EPOLL adding of FD handle to occur ",
                    handle, " with error ", error, " on thread ", Thread.self);
            break;

        default:
            // unknown failure
            logger.info("The current environment has erroneous state for EPOLL adding of FD handle to occur ", handle,
                    " with error ", error, " on thread ", Thread.self);
            break;
        }

        return false;
    } else
        assert(0);
}

void removeEpollHandleToWaitOn(int handle) @trusted {
    logger.trace("Attempting to remove FD handle ", handle, " for EPOLL ", epollContext, " on thread ", Thread.self);

    version (linux) {
        if (atomicLoad(isInProcessOfDieing))
            return;

        int result = epoll_ctl(epollContext, EPOLL_CTL_DEL, handle, null);
        if (result == 0)
            return;

        const error = errno;

        switch (error) {
        case EPERM:
            // not an fd that could be in epoll, already messaged about
            break;

        case EBADF:
        case EINVAL:
        case ENOMEM:
            // welp something is wrong in environment
            if (!atomicLoad(isInProcessOfDieing)) {
                logger.warning("The current environment has erroneous state for EPOLL removing of FD handle to occur ",
                        handle, " with error ", error, " on thread ", Thread.self);
            }
            break;

        default:
            // unknown failure
            logger.info("The current environment has erroneous state for EPOLL removing of FD handle to occur ",
                    handle, " with error ", error, " on thread ", Thread.self);
            break;
        }
    } else
        assert(0);
}
