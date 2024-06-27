module sidero.eventloop.internal.workers.kernelwait.windows;
import sidero.eventloop.internal.workers;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.sockets;
import sidero.eventloop.threads;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.internal.atomic;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;

    private __gshared {
        LoggerReference logger;
        HANDLE completionPort;
        ubyte shutdownByte, coroutineByte;
        uint requiredWorkers;

        shared(ptrdiff_t) runningWorkers;
        shared(ptrdiff_t) startedWorkers;
    }
} else {
    alias DWORD = uint;
}

struct IOCPwork {
    ubyte[4] key; //sock
    void* ptr;
}

@safe nothrow @nogc:

bool initializeWorkerPlatformMechanism(size_t numberOfWorkers) @trusted {
    version(Windows) {
        logger = Logger.forName(String_UTF8(__MODULE__));
        if(!logger || logger.isNull)
            return false;
        logger.setLevel = LogLevel.Warning;

        requiredWorkers = cast(uint)numberOfWorkers;

        // the reason we ignore the required number of workers for IOCP allowed to keep awake is because
        //  it won't actually benefit us to have more threads than cpu cores + HT.
        // it would only increase the number of context switches and kill performance
        // see: programming server-side applications for Microsoft Windows 2000 page 57 and 61.
        completionPort = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);

        if(completionPort is null) {
            logger.error("Failed to initialize IOCP context ", GetLastError());
            return false;
        }

        logger.notice("Initialized IOCP context for workers succesfully");
        return true;
    } else
        return false;
}

void shutdownWorkerPlatformMechanism() @trusted {
    version(Windows) {
        ULONG_PTR shutdownKey = cast(ULONG_PTR)&shutdownByte;

        while(atomicLoad(startedWorkers) != requiredWorkers) {
            Thread.yield;
        }

        while(atomicLoad(runningWorkers) > 0) {
            auto result = PostQueuedCompletionStatus(completionPort, 0, shutdownKey, null);

            if(result == 0) {
                logger.error("IOCP worker shutdown message posting failed ", GetLastError());
            }

            Thread.yield;
        }

        CloseHandle(completionPort);
        logger.notice("Shutdown IOCP context for workers successfully");
    } else
        assert(0);
}

void triggerACoroutineMechanism(size_t count) @trusted {
    version(Windows) {
        ULONG_PTR coroutineKey = cast(ULONG_PTR)&coroutineByte;
        logger.debug_("Posting coroutine work with key ", coroutineKey, " times ", count);

        foreach(_; 0 .. count) {
            auto result = PostQueuedCompletionStatus(completionPort, 0, coroutineKey, null);

            if(result == 0) {
                logger.warning("IOCP worker could not send coroutine execution message ", GetLastError());
                return;
            }
        }
    } else
        assert(0);
}

bool associateWithIOCP(Socket socket) @trusted {
    version(Windows) {
        logger.debug_("Associated socket with IOCP for socket ", socket.state.handle, " using key ", cast(size_t)&socket.state.iocpWork);

        socket.state.iocpWork.key = cast(ubyte[4])"SOCK";
        socket.state.iocpWork.ptr = socket.state;

        HANDLE completionPort2 = CreateIoCompletionPort(cast(void*)socket.state.handle, completionPort,
                cast(size_t)&socket.state.iocpWork, 0);

        if(completionPort2 !is completionPort) {
            logger.debug_("Could not associate socket with IOCP with code ", WSAGetLastError(), " for socket ", socket.state.handle);
            return false;
        }

        return true;
    } else
        assert(0);
}

void workerProc() @trusted {
    version(Windows) {
        atomicIncrementAndLoad(startedWorkers, 1);
        atomicIncrementAndLoad(runningWorkers, 1);
        scope(exit) {
            atomicDecrementAndLoad(runningWorkers, 1);
            logger.info("Stopping IOCP worker ", Thread.self);
        }

        logger.info("Starting IOCP worker ", Thread.self);

        for(;;) {
            DWORD numberOfBytesTransferred;
            ULONG_PTR completionKey;
            OVERLAPPED* overlapped;
            auto result = GetQueuedCompletionStatus(completionPort, &numberOfBytesTransferred, &completionKey, &overlapped, INFINITE);

            logger.debug_("IOCP worker thread got ", result, " on ", Thread.self);

            if(result == 0) {
                const errorCode = WSAGetLastError();

                if(errorCode == WAIT_TIMEOUT) {
                } else if(errorCode == ERROR_OPERATION_ABORTED) {
                    // ok, explicitly cancelled event
                } else if(overlapped is null) {
                    logger.warning("IOCP worker GetQueuedCompletionStatus did not complete with error ", errorCode, " on ", Thread.self);
                } else {
                    IOCPwork* work = cast(IOCPwork*)completionKey;

                    if(work !is null && work.key == cast(ubyte[4])"SOCK") {
                        // Well we know what to do here!

                        Socket socket;
                        socket.state = cast(SocketState*)work.ptr;
                        socket.state.rc(true);

                        handleSocketReadNotification(socket, numberOfBytesTransferred);

                        socket.state.guard(&socket.state.performReadWrite);
                    } else {
                        logger.warning("IOCP worker GetQueuedCompletionStatus failed with error ", errorCode, " with transferred bytes ",
                                numberOfBytesTransferred, " with overlapped ", overlapped, " with key ",
                                completionKey, " on ", Thread.self);
                    }
                }
            } else if(overlapped is null && completionKey is cast(ULONG_PTR)&shutdownByte) {
                logger.debug_("Stopping a IOCP worker procedure cleanly ", Thread.self);
                return;
            } else if(overlapped is null && completionKey is cast(ULONG_PTR)&coroutineByte) {
                logger.debug_("Got coroutine work ", Thread.self);

                auto workToDo = coroutinesForWorkers.pop;

                if(workToDo && !workToDo.isNull) {
                    auto errorResult = workToDo.unsafeResume;
                    coroutineCompletedTask(workToDo, errorResult);
                }
            } else {
                logger.debug_("Got IOCP work ", numberOfBytesTransferred, " ", completionKey, " ", result, " ", Thread.self);

                IOCPwork* work = cast(IOCPwork*)completionKey;

                if(work.key == cast(ubyte[4])"SOCK") {
                    Socket socket;
                    socket.state = cast(SocketState*)work.ptr;
                    socket.state.rc(true);

                    logger.debug_("Seeing IOCP work for socket ", socket.state.handle, " on ", Thread.self);

                    socket.state.guard(() {
                        if(overlapped is &socket.state.writeOverlapped)
                            socket.state.rawWriting.complete(socket.state, numberOfBytesTransferred);
                        else if(overlapped is &socket.state.readOverlapped)
                            handleSocketReadNotification(socket, numberOfBytesTransferred);

                        socket.state.performReadWrite;
                    });
                }
            }
        }
    } else
        assert(0);
}

void handleSocketReadNotification(Socket socket, DWORD transferredBytes) @trusted {
    version(Windows) {
        import core.sys.windows.winbase : GetLastError;

        bool wasAccepted;

        if(socket.state.hasJustBeenAccepted) {
            logger.debug_("Peer socket has been accepted ", socket.state.handle, " on ", Thread.self);
            // its now accepted!!!

            socket.state.uponAccept(socket.state);

            socket.state.hasJustBeenAccepted = false;
            wasAccepted = true;
        }

        if(transferredBytes == 0) {
            if(!wasAccepted) {
                // peer closed connection
                logger.debug_("Peer closed socket ", socket.state.handle, " on ", Thread.self);
                // ok just in case lets just unpin it
                socket.state.unpinGuarded;
            }
        } else {
            logger.debug_("Read from socket ", transferredBytes, " for ", socket.state.handle, " on ", Thread.self);
            socket.state.rawReading.complete(socket.state, transferredBytes);
        }
    } else
        assert(0);
}
