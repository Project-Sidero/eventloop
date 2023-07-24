module sidero.eventloop.internal.windows.iocp;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.threads;
import sidero.base.logger;
import sidero.base.text;

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import sidero.eventloop.networking.internal.state;
    import core.sys.windows.windows : HANDLE;

    private __gshared {
        LoggerReference logger;
        HANDLE completionPort;
        ubyte shutdownByte;
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
        import core.sys.windows.windows : CreateIoCompletionPort, INVALID_HANDLE_VALUE, GetLastError;

        logger = Logger.forName(String_UTF8(__MODULE__));
        if (!logger || logger.isNull)
            return false;

        requiredWorkers = cast(uint)numberOfWorkers;
        completionPort = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, requiredWorkers);

        if (completionPort is null) {
            logger.error("Failed to initialize IOCP context ", GetLastError());
            return false;
        }

        logger.notice("Initialized IOCP context for workers succesfully");
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
                logger.error("IOCP worker shutdown message posting failed ", GetLastError());
            }

            Thread.yield;
        }

        CloseHandle(completionPort);
        logger.notice("Shutdown IOCP context for workers successfully");
    }

    bool associateWithIOCP(Socket socket) @trusted {
        import core.sys.windows.windows : CreateIoCompletionPort, INVALID_HANDLE_VALUE, WSAGetLastError, HANDLE;

        socket.state.iocpWork.key = cast(ubyte[4])"SOCK";
        socket.state.iocpWork.ptr = socket.state;

        HANDLE completionPort2 = CreateIoCompletionPort(cast(void*)socket.state.handle, completionPort,
                cast(size_t)&socket.state.iocpWork, 0);

        if (completionPort2 !is completionPort) {
            logger.debug_("Could not associate socket with IOCP with code ", WSAGetLastError(), " for socket ", socket.state.handle);
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
            logger.info("Stopping IOCP worker ", Thread.self);
        }

        logger.info("Starting IOCP worker ", Thread.self);

        for (;;) {
            DWORD numberOfBytesTransferred;
            ULONG_PTR completionKey;
            OVERLAPPED* overlapped;
            auto result = GetQueuedCompletionStatus(completionPort, &numberOfBytesTransferred, &completionKey, &overlapped, INFINITE);

            logger.debug_("IOCP worker thread got ", result, " ", Thread.self);

            if (result == 0) {
                const errorCode = GetLastError();
                if (errorCode == WAIT_TIMEOUT) {
                } else if (overlapped is null) {
                    logger.warning("IOCP worker GetQueuedCompletionStatus did not complete ", errorCode, " ", Thread.self);
                } else {
                    logger.warning("IOCP worker GetQueuedCompletionStatus failed ", errorCode, " ", Thread.self);
                    return;
                }
            } else if (overlapped is null && completionKey is cast(ULONG_PTR)&shutdownByte) {
                logger.debug_("Stopping a IOCP worker procedure cleanly ", Thread.self);
                return;
            } else {
                logger.debug_("Got IOCP work ", numberOfBytesTransferred, " ", completionKey, " ", result, " ", Thread.self);

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
                return;
            } else if (error == WSAENOTSOCK) {
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
            socket.state.rawReadingState.dataWasReceived(transferredBytes);
            socket.state.readingState.tryFulfillRequest(socket.state);
        }
    }

    void handleSocketWrite(Socket socket) @trusted {
        import core.sys.windows.windows : DWORD, GetLastError;
        import core.atomic : atomicLoad;

        DWORD transferredBytes, flags;
        auto result = WSAGetOverlappedResult(socket.state.handle, &socket.state.writeOverlapped, &transferredBytes, false, &flags);

        if (result == 0) {
            auto error = GetLastError();
            if (error == WSA_IO_INCOMPLETE) {
                // no data?
                logger.debug_("WSA wrote no data ", socket, " on ", Thread.self);
                return;
            } else if (error == WSAENOTSOCK) {
                logger.debug_("Handle not a socket message ", socket.state.handle, " on ", Thread.self);
                // ok just in case lets just unpin it
                socket.state.unpin;
                return;
            } else {
                logger.warning("Unknown write socket error with code ", error, " ", socket.state.handle, " ", Thread.self);
                return;
            }
        } else {
            logger.debug_("Written on socket ", transferredBytes, " with flags ", flags, " for ", socket.state.handle, " on ", Thread.self);

            socket.state.rawWritingState.protect(() {
                socket.state.rawWritingState.complete(transferredBytes);
                if (socket.state.rawWritingState.haveData)
                    socket.state.triggerWrite(socket.state);
                return true;
            });
        }
    }
}
