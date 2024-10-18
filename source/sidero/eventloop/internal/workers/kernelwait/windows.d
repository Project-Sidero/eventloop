module sidero.eventloop.internal.workers.kernelwait.windows;
import sidero.eventloop.internal.workers;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.internal.filesystem.state;
import sidero.eventloop.sockets;
import sidero.eventloop.threads;
import sidero.eventloop.filesystem.file;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.internal.atomic;
import sidero.base.errors;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import sidero.eventloop.internal.filesystem.windows;
    import sidero.eventloop.internal.networking.windows.socketserver;

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
    ubyte[5] key; //(l)sock/file

    union {
        struct {
            SocketState* socketState;
            ListenSocketState* listenSocketState;
            ResultReferenceAlternative!PlatformListenSocket perSocket;
        }

        FileState* fileState;
    }

@safe nothrow @nogc:

    this(return scope ref IOCPwork other) scope @trusted {
        this.tupleof = other.tupleof;
    }

    enum : ubyte[5] {
        Socket = cast(ubyte[5])"SOCK\0",
        ListenSocket = cast(ubyte[5])"LSOCK",
        File = cast(ubyte[5])"FILE\0",
    }
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
        logger.debug_("Posting coroutine work with key ", coroutineKey, " times ", count, " on ", Thread.self);

        foreach(_; 0 .. count) {
            auto result = PostQueuedCompletionStatus(completionPort, 0, coroutineKey, null);

            if(result == 0) {
                logger.warning("IOCP worker could not send coroutine execution message ", GetLastError(), " on ", Thread.self);
                return;
            }
        }
    } else
        assert(0);
}

bool associateWithIOCP(Socket socket) @trusted {
    version(Windows) {
        logger.debug_("Associated socket with IOCP for socket ", socket.state.handle, " using key ",
                cast(size_t)&socket.state.iocpWork, " on ", Thread.self);

        socket.state.iocpWork.key = IOCPwork.Socket;
        socket.state.iocpWork.socketState = socket.state;

        HANDLE completionPort2 = CreateIoCompletionPort(cast(void*)socket.state.handle, completionPort,
                cast(size_t)&socket.state.iocpWork, 0);

        if(completionPort2 !is completionPort) {
            logger.debug_("Could not associate socket with IOCP with code ", GetLastError(), " for socket ",
                    socket.state.handle, " on ", Thread.self);
            return false;
        }

        return true;
    } else
        assert(0);
}

bool associateWithIOCP(File file) @trusted {
    version(Windows) {
        logger.debug_("Associated file with IOCP for file ", file.state.handle, " using key ",
                cast(size_t)&file.state.iocpWork, " on ", Thread.self);

        file.state.iocpWork.key = IOCPwork.File;
        file.state.iocpWork.fileState = file.state;

        HANDLE completionPort2 = CreateIoCompletionPort(cast(void*)file.state.handle, completionPort,
                cast(size_t)&file.state.iocpWork, 0);

        if(completionPort2 !is completionPort) {
            logger.debug_("Could not associate file with IOCP with code ", GetLastError(), " for file ",
                    file.state.handle, " on ", Thread.self);
            return false;
        }

        return true;
    } else
        assert(0);
}

bool associateWithIOCP(ListenSocketPair listenSocketPair) @trusted {
    version(Windows) {
        assert(listenSocketPair.perSocket);
        logger.debug_("Associated socket with IOCP for socket ", listenSocketPair.perSocket.handle, " using key ",
                cast(size_t)&listenSocketPair.perSocket.iocpWork, " on ", Thread.self);

        listenSocketPair.perSocket.iocpWork.key = IOCPwork.ListenSocket;
        listenSocketPair.perSocket.iocpWork.listenSocketState = listenSocketPair.listenSocket.state;
        listenSocketPair.perSocket.iocpWork.perSocket = listenSocketPair.perSocket.asAlternative;

        HANDLE completionPort2 = CreateIoCompletionPort(cast(void*)listenSocketPair.perSocket.handle, completionPort,
                cast(size_t)&listenSocketPair.perSocket.iocpWork, 0);

        if(completionPort2 !is completionPort) {
            logger.debug_("Could not associate listen socket with IOCP with code ", WSAGetLastError(), " for socket ",
                    listenSocketPair.perSocket.handle, " on ", Thread.self);
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
            checkForMoreThreadsToSpinUp;

            DWORD numberOfBytesTransferred;
            ULONG_PTR completionKey;
            OVERLAPPED* overlapped;
            auto result = GetQueuedCompletionStatus(completionPort, &numberOfBytesTransferred, &completionKey, &overlapped, INFINITE);

            logger.debug_("IOCP worker thread got ", result, " on ", Thread.self);

            if(result == 0) {
                const errorCode = WSAGetLastError();

                if(errorCode == WAIT_TIMEOUT) {
                } else if(overlapped is null) {
                    logger.warning("IOCP worker GetQueuedCompletionStatus did not complete with error ", errorCode, " on ", Thread.self);
                } else {
                    IOCPwork* work = cast(IOCPwork*)completionKey;

                    if(work !is null) {
                        seeError(work, overlapped, errorCode);
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
                IOCPwork* work = cast(IOCPwork*)completionKey;

                if(work !is null) {
                    seeWork(work, numberOfBytesTransferred, overlapped);
                }
            }
        }
    } else
        assert(0);
}

void seeError(IOCPwork* work, OVERLAPPED* overlapped, int errorCode) @trusted {
    version(Windows) {
        logger.debug_("Got IOCP error for key: ", work.key, ", with error ", errorCode, ", with overlapped ",
                overlapped, ", on ", Thread.self);

        if(work.key == IOCPwork.Socket) {
            Socket socket;
            socket.state = work.socketState;
            socket.state.rc(true);

            logger.debug_("Seeing IOCP error for socket ", socket.state.handle, " as overlapped read ",
                    &socket.state.readOverlapped, " as overlapped write ", &socket.state.writeOverlapped, " as overlapped accept ",
                    &socket.state.acceptOverlapped, " as overlapped always reading ",
                    &socket.state.alwaysReadingOverlapped, " on ", Thread.self);

            if(overlapped is &socket.state.alwaysReadingOverlapped) {
                socket.state.unpinExtra;

                DWORD transferred;
                DWORD flags;

                const wasError = WSAGetOverlappedResult(socket.state.handle, &socket.state.alwaysReadingOverlapped,
                        &transferred, false, &flags);
                errorCode = WSAGetLastError();

                switch(errorCode) {
                case WSA_OPERATION_ABORTED:
                    // This is completely ok, it is normal operation!
                    return;

                default:
                    // Ugh oh...
                    break;
                }
            } else {
                socket.state.unpinExtra;
                socket.state.unpin;
            }
        } else if(work.key == IOCPwork.ListenSocket) {
            assert(work.perSocket);

            ListenSocket listenSocket;
            listenSocket.state = work.listenSocketState;
            listenSocket.state.rc(true);

            forceClose(&work.perSocket.get());
            listenSocket.state.unpin;
        } else if(work.key == IOCPwork.File) {
            assert(work.fileState);

            File file;
            file.state = work.fileState;
            file.state.rc(true);

            logger.debug_("Seeing IOCP error for file ", file.state.handle, " as overlapped read ", &file.state.readOverlapped,
                    " as overlapped write ", &file.state.writeOverlapped, " as overlapped always reading ",
                    &file.state.alwaysReadingOverlapped, " on ", Thread.self);

            if(overlapped is &file.state.alwaysReadingOverlapped) {
                file.state.unpinExtra;

                DWORD transferred;

                const wasError = GetOverlappedResult(file.state.handle, &file.state.alwaysReadingOverlapped, &transferred, false);
                errorCode = GetLastError();

                switch(errorCode) {
                case ERROR_HANDLE_EOF:
                case ERROR_OPERATION_ABORTED:
                    // This is completely ok, it is normal operation!
                    break;

                default:
                    // Ugh oh...
                    break;
                }

                file.state.guard(() { file.state.performReadWrite; });
            } else if(overlapped is &file.state.readOverlapped) {
                file.state.unpinExtra;

                DWORD transferred;

                const wasError = GetOverlappedResult(file.state.handle, &file.state.readOverlapped, &transferred, false);
                errorCode = GetLastError();

                switch(errorCode) {
                case ERROR_HANDLE_EOF:
                    file.state.guard(() {
                        file.state.reading.rawReadFailed(file.state, true);
                        file.state.rawReading.complete(file.state, 0);
                    });
                    break;

                default:
                    // Ugh oh...
                    break;
                }

                file.state.guard(() { file.state.performReadWrite; });
            } else {
                file.state.unpinExtra;
                file.state.unpin;
                file.state.forceClose();
            }
        } else {
            logger.warning("Unknown work type ", work.key, " on ", Thread.self);
        }
    }
}

void seeWork(IOCPwork* work, DWORD numberOfBytesTransferred, OVERLAPPED* overlapped) @trusted {
    version(Windows) {
        import sidero.eventloop.internal.networking.windows.socketserver : uponSocketAccept;

        logger.debug_("Got IOCP work: ", work.key, ", number of bytes transferred: ", numberOfBytesTransferred,
                ", overlapped: ", overlapped, ", on ", Thread.self);

        if(work.key == IOCPwork.Socket) {
            Socket socket;
            socket.state = work.socketState;
            socket.state.rc(true);
            socket.state.unpinExtra;

            logger.debug_("Seeing IOCP work for socket ", socket.state.handle, " on ", Thread.self);

            socket.state.guard(() {
                if(overlapped is &socket.state.writeOverlapped)
                    socket.state.rawWriting.complete(socket.state, numberOfBytesTransferred);
                else if(overlapped is &socket.state.readOverlapped)
                    handleSocketReadNotification(socket, numberOfBytesTransferred);
                else if(overlapped is &socket.state.acceptOverlapped)
                    uponSocketAccept(socket);

                socket.state.performReadWrite;
            });
        } else if(work.key == IOCPwork.ListenSocket) {
            assert(work.perSocket);

            ListenSocket listenSocket;
            listenSocket.state = work.listenSocketState;
            listenSocket.state.rc(true);

            auto socket = work.perSocket.overlappedToBeAcceptSockets[overlapped];

            if(socket) {
                logger.debug_("Seeing IOCP work for listen socket ", work.perSocket.handle, " with socket ",
                        socket.state.handle, " on ", Thread.self);

                work.perSocket.overlappedToBeAcceptSockets.remove(overlapped);
                uponSocketAccept(socket);
            } else {
                logger.debug_("Seeing IOCP work for listen socket ", work.perSocket.handle, " on ", Thread.self);
            }
        } else if(work.key == IOCPwork.File) {
            assert(work.fileState);

            File file;
            file.state = work.fileState;
            file.state.rc(true);
            file.state.unpinExtra;

            logger.debug_("Seeing IOCP work for file ", file.state.handle, " on ", Thread.self);

            file.state.guard(() {
                if(overlapped is &file.state.writeOverlapped)
                    file.state.rawWriting.complete(file.state, numberOfBytesTransferred);
                else if(overlapped is &file.state.readOverlapped)
                    handleFileReadNotification(file, numberOfBytesTransferred);

                file.state.performReadWrite;
            });
        } else {
            logger.warning("Unknown work type ", cast(char[5])work.key, " on ", Thread.self);
        }
    } else
        assert(0);
}

void handleSocketReadNotification(Socket socket, DWORD transferredBytes) @trusted {
    version(Windows) {
        import core.sys.windows.winbase : GetLastError;

        if(transferredBytes == 0) {
            // peer closed connection
            logger.debug_("Peer closed socket ", socket.state.handle, " on ", Thread.self);
            // ok just in case lets just unpin it
            socket.state.unpinGuarded;
        } else {
            logger.debug_("Read from socket ", transferredBytes, " for ", socket.state.handle, " on ", Thread.self);
        }

        socket.state.rawReading.complete(socket.state, transferredBytes);
    } else
        assert(0);
}

void handleFileReadNotification(File file, DWORD transferredBytes) @trusted {
    version(Windows) {
        import core.sys.windows.winbase : GetLastError;

        logger.debug_("Read from file ", transferredBytes, " for ", file.state.handle, " on ", Thread.self);

        file.state.guard(() {
            file.state.rawReading.complete(file.state, transferredBytes);
        });
    } else
        assert(0);
}
