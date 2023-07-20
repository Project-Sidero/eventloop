module sidero.eventloop.internal.windows.iocp;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.threads;
import sidero.base.logger;
import sidero.base.text;

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import sidero.eventloop.networking.internal.state;
    import core.sys.windows.windows : HANDLE;

    __gshared {
        LoggerReference logger;
        HANDLE completionPort;
        ubyte shutdownByte;
        uint requiredWorkers;
    }

    shared(ptrdiff_t) runningWorkers;
    shared(ptrdiff_t) startedWorkers;

    struct IOCPwork {
        ubyte[4] key; //sock
        void* ptr;
    }

@safe nothrow @nogc:

    bool initializeWorkerMechanism(size_t numberOfWorkers) @trusted {
        import core.sys.windows.windows : CreateIoCompletionPort, INVALID_HANDLE_VALUE, GetLastError;

        logger = Logger.forName(String_UTF8(__MODULE__));
        if (!logger || logger.isNull)
            return false;

        requiredWorkers = cast(uint)numberOfWorkers;
        completionPort = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, requiredWorkers);

        if (completionPort is null) {
            logger.error("Error occured while creating IOCP ", GetLastError());
            return false;
        } else {
            logger.trace("IOCP initialized successfully");
        }

        return true;
    }

    void shutdownWorkerMechanism() @trusted {
        import core.atomic : atomicLoad;
        import core.sys.windows.windows : PostQueuedCompletionStatus, ULONG_PTR, GetLastError, CloseHandle;

        ULONG_PTR shutdownKey = cast(ULONG_PTR)&shutdownByte;

        while (atomicLoad(startedWorkers) != requiredWorkers) {
            Thread.yield;
        }

        while (atomicLoad(runningWorkers) > 0) {
            auto result = PostQueuedCompletionStatus(completionPort, 0, shutdownKey, null);

            if (result == 0) {
                logger.error("PostQueuedCompletionStatus failed ", GetLastError());
            }

            Thread.yield;
        }

        CloseHandle(completionPort);
    }

    bool associateWithIOCP(Socket socket) @trusted {
        import core.sys.windows.windows : CreateIoCompletionPort, INVALID_HANDLE_VALUE, WSAGetLastError, HANDLE;

        socket.state.iocpWork.key = cast(ubyte[4])"SOCK";
        socket.state.iocpWork.ptr = socket.state;

        HANDLE completionPort2 = CreateIoCompletionPort(cast(void*)socket.state.handle, completionPort,
                cast(size_t)&socket.state.iocpWork, 0);

        if (completionPort2 !is completionPort) {
            logger.error("Error could not associate socket with IOCP with code ", WSAGetLastError());
            return false;
        }

        return true;
    }

    void workerProc() @trusted {
        import core.atomic : atomicOp, atomicLoad;
        import core.sys.windows.windows : GetQueuedCompletionStatus, DWORD, ULONG_PTR, OVERLAPPED, INFINITE, GetLastError, WAIT_TIMEOUT;

        atomicOp!"+="(startedWorkers, 1);
        atomicOp!"+="(runningWorkers, 1);
        scope (exit) {
            atomicOp!"-="(runningWorkers, 1);
            logger.trace("Stopping IOCP worker");
        }

        logger.trace("Starting IOCP worker");

        for (;;) {
            DWORD numberOfBytesTransferred;
            ULONG_PTR completionKey;
            OVERLAPPED* overlapped;
            auto result = GetQueuedCompletionStatus(completionPort, &numberOfBytesTransferred, &completionKey, &overlapped, INFINITE);

            logger.trace("IOCP worker thread got ", result, " ", Thread.self);

            if (!result) {
                if (GetLastError() == WAIT_TIMEOUT) {
                } else {
                    logger.error("IOCP worker GetQueuedCompletionStatus failed ", GetLastError(), " ", Thread.self());
                    return;
                }
            } else if (overlapped is null && completionKey is cast(ULONG_PTR)&shutdownByte) {
                logger.trace("Stopping a IOCP worker procedure cleanly ", Thread.self());
                return;
            } else {
                logger.trace("Got IOCP work ", numberOfBytesTransferred, " ", completionKey, " ", result, " ", Thread.self());

                IOCPwork* work = cast(IOCPwork*)completionKey;

                if (work.key == cast(ubyte[4])"SOCK") {
                    Socket socket;
                    socket.state = cast(SocketState*)work.ptr;
                    socket.state.rc(true);

                    if (numberOfBytesTransferred > 0) {
                        if (overlapped is &socket.state.writeOverlapped)
                            handleSocketWrite(socket);
                        if (overlapped is &socket.state.readOverlapped)
                            handleSocketRead(socket);
                    }

                    if (atomicLoad(socket.state.isShutdown) && socket.state.rawWritingState.protect(() {
                            return !socket.state.rawWritingState.haveData;
                        }) && !socket.state.readingState.inProgress)
                        socket.state.platform.forceClose();
                }
            }
        }
    }

    void handleSocketRead(Socket socket) @trusted {
        import core.sys.windows.windows : DWORD, GetLastError;
        import core.atomic : atomicLoad;

        DWORD transferredBytes, flags;
        auto result = WSAGetOverlappedResult(socket.state.handle, &socket.state.readOverlapped, &transferredBytes, false, &flags);

        if (!result) {
            auto error = GetLastError();
            if (error == WSA_IO_INCOMPLETE) {
                // no data?
                logger.trace("WSA received no data ", socket, " ", Thread.self());
                return;
            } else {
                logger.error("Error unknown read socket error with code ", error, " ", socket, " ", Thread.self());
                return;
            }
        } else {
            logger.trace("Read from socket ", transferredBytes, flags, socket, Thread.self());
            socket.state.rawReadingState.dataWasReceived(transferredBytes);
            if (atomicLoad(socket.state.isAlive))
                socket.state.readingState.tryFulfillRequest(socket.state);
        }
    }

    void handleSocketWrite(Socket socket) @trusted {
        import core.sys.windows.windows : DWORD, GetLastError;
        import core.atomic : atomicLoad;

        DWORD transferredBytes, flags;
        auto result = WSAGetOverlappedResult(socket.state.handle, &socket.state.writeOverlapped, &transferredBytes, false, &flags);

        if (!result) {
            auto error = GetLastError();
            if (error == WSA_IO_INCOMPLETE) {
                // no data?
                logger.trace("WSA wrote no data ", socket, " ", Thread.self());
                return;
            } else {
                logger.error("Error unknown write socket error with code ", error, " ", socket, " ", Thread.self());
                return;
            }
        } else {
            logger.trace("Written from socket ", transferredBytes, " ", flags, " ", socket, " ", Thread.self());

            socket.state.rawWritingState.protect(() {
                socket.state.rawWritingState.complete(transferredBytes);
                if (socket.state.rawWritingState.haveData && atomicLoad(socket.state.isAlive))
                    socket.state.triggerWrite(socket.state);
                return true;
            });
        }
    }
}
