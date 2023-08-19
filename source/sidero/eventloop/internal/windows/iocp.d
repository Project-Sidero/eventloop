module sidero.eventloop.internal.windows.iocp;
import sidero.eventloop.internal.workers;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.threads;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.internal.atomic;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import sidero.eventloop.networking.internal.state;
    import core.sys.windows.windows : HANDLE;

    private __gshared {
        LoggerReference logger;
        HANDLE completionPort;
        ubyte shutdownByte, coroutineByte;
        uint requiredWorkers;

        shared(ptrdiff_t) runningWorkers;
        shared(ptrdiff_t) startedWorkers;
    }

    struct IOCPwork {
        ubyte[4] key; //sock
        void* ptr;
    }

@safe nothrow @nogc:

    bool initializeWorkerMechanism(size_t numberOfWorkers) @trusted {
        import sidero.eventloop.internal.windows.bindings;

        logger = Logger.forName(String_UTF8(__MODULE__));
        if(!logger || logger.isNull)
            return false;

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
    }

    void shutdownWorkerMechanism() @trusted {
        import sidero.eventloop.internal.windows.bindings;

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
    }

    void triggerACoroutineMechanism(size_t count) @trusted {
        import sidero.eventloop.internal.windows.bindings;

        ULONG_PTR coroutineKey = cast(ULONG_PTR)&coroutineByte;
        logger.debug_("Posting coroutine work with key ", coroutineKey, " times ", count);

        foreach(_; 0 .. count) {
            auto result = PostQueuedCompletionStatus(completionPort, 0, coroutineKey, null);

            if(result == 0) {
                logger.warning("IOCP worker could not send coroutine execution message ", GetLastError());
                return;
            }
        }
    }

    bool associateWithIOCP(Socket socket) @trusted {
        import sidero.eventloop.internal.windows.bindings;

        socket.state.iocpWork.key = cast(ubyte[4])"SOCK";
        socket.state.iocpWork.ptr = socket.state;

        HANDLE completionPort2 = CreateIoCompletionPort(cast(void*)socket.state.handle, completionPort,
                cast(size_t)&socket.state.iocpWork, 0);

        if(completionPort2 !is completionPort) {
            logger.debug_("Could not associate socket with IOCP with code ", WSAGetLastError(), " for socket ", socket.state.handle);
            return false;
        }

        return true;
    }

    void workerProc() @trusted {
        import sidero.eventloop.internal.windows.bindings;

        atomicIncrementAndLoad(startedWorkers, 1);
        atomicIncrementAndLoad(runningWorkers, 1);
        scope(exit) {
            atomicDecrementAndLoad(runningWorkers, 1);
            logger.info("Stopping IOCP worker ", Thread.self);
        }

        logger.setLevel = LogLevel.Trace;
        logger.info("Starting IOCP worker ", Thread.self);

        for(;;) {
            DWORD numberOfBytesTransferred;
            ULONG_PTR completionKey;
            OVERLAPPED* overlapped;
            auto result = GetQueuedCompletionStatus(completionPort, &numberOfBytesTransferred, &completionKey, &overlapped, INFINITE);

            logger.debug_("IOCP worker thread got ", result, " ", Thread.self);

            if(result == 0) {
                const errorCode = GetLastError();
                if(errorCode == WAIT_TIMEOUT) {
                } else if(overlapped is null) {
                    logger.warning("IOCP worker GetQueuedCompletionStatus did not complete ", errorCode, " ", Thread.self);
                } else {
                    logger.warning("IOCP worker GetQueuedCompletionStatus failed ", errorCode, " ", Thread.self);
                    return;
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

                    if(numberOfBytesTransferred > 0) {
                        if(overlapped is &socket.state.writeOverlapped)
                            handleSocketWrite(socket);
                        if(overlapped is &socket.state.readOverlapped)
                            handleSocketRead(socket);
                    }
                }
            }
        }
    }

    void handleSocketRead(Socket socket) @trusted {
        import core.sys.windows.windows : DWORD, GetLastError;

        DWORD transferredBytes, flags;
        auto result = WSAGetOverlappedResult(socket.state.handle, &socket.state.readOverlapped, &transferredBytes, false, &flags);

        if(!result) {
            auto error = GetLastError();
            if(error == WSA_IO_INCOMPLETE) {
                // no data?
                return;
            } else if(error == WSAENOTSOCK) {
                logger.debug_("Handle not a socket message ", socket.state.handle, " on ", Thread.self);
                // ok just in case lets just unpin it
                socket.state.unpin;
                return;
            } else {
                logger.warning("Unknown read socket error with code ", error, " for ", socket.state.handle, " on ", Thread.self);
                return;
            }
        } else {
            logger.debug_("Read from socket ", transferredBytes, " with flags ", flags, " for ", socket.state.handle, " on ", Thread.self);
            socket.state.guard(() {
                socket.state.rawReading.complete(socket.state, transferredBytes);
                socket.state.performReadWrite();
            });
        }
    }

    void handleSocketWrite(Socket socket) @trusted {
        import core.sys.windows.windows : DWORD, GetLastError;

        DWORD transferredBytes, flags;
        auto result = WSAGetOverlappedResult(socket.state.handle, &socket.state.writeOverlapped, &transferredBytes, false, &flags);

        if(result == 0) {
            auto error = GetLastError();
            if(error == WSA_IO_INCOMPLETE) {
                // no data?
                logger.debug_("WSA wrote no data ", socket, " on ", Thread.self);
                return;
            } else if(error == WSAENOTSOCK) {
                logger.debug_("Handle not a socket message ", socket.state.handle, " on ", Thread.self);
                // ok just in case lets just unpin it
                socket.state.unpin;
                return;
            } else {
                logger.warning("Unknown write socket error with code ", error, " ", socket.state.handle, " ", Thread.self);
                return;
            }
        } else {
            logger.debug_("Written on socket ", transferredBytes, " with flags ", flags, " for ",
                    socket.state.handle, " on ", Thread.self);

            version(none) {
                socket.state.rawWritingState.protect(() {
                    socket.state.rawWritingState.complete(transferredBytes);
                    if(socket.state.rawWritingState.haveData)
                        socket.state.triggerWrite(socket.state);
                    return true;
                });
            } else {
                socket.state.guard(() { socket.state.rawWriting.complete(socket.state, transferredBytes); });
            }
        }
    }
}
