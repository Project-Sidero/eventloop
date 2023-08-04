module sidero.eventloop.networking.internal.windows.mechanism;
import sidero.eventloop.networking.internal.state;
import sidero.base.text;
import sidero.base.logger;
import sidero.base.path.networking;
import sidero.base.internal.atomic;

@safe nothrow @nogc:

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import sidero.eventloop.internal.windows.iocp;

    package(sidero.eventloop.networking.internal.windows) __gshared {
        LoggerReference logger;
    }

    bool startUpNetworkingMechanism() @trusted {
        import sidero.eventloop.networking.internal.windows.encryption;
        import core.sys.windows.windows : MAKEWORD, GetLastError, NO_ERROR;
        import core.sys.windows.winsock2;

        logger = Logger.forName(String_UTF8(__MODULE__));
        if(!logger)
            return false;
        else if(!setupWinCryptEncryption)
            return false;

        enum WSAVersion = MAKEWORD(2, 2);

        WSADATA wsaData;
        int nResult = WSAStartup(WSAVersion, &wsaData);

        if(nResult != NO_ERROR) {
            logger.warning("Error occured while executing WSAStartup with code", GetLastError(), " ", nResult);
            return false;
        } else {
            logger.info("WSA initialized successfully");
        }

        return true;
    }

    void shutdownNetworkingMechanism() @trusted {
        import core.sys.windows.winsock2 : WSACleanup;

        WSACleanup;
        logger.info("WSA uninitialized");
    }

    alias PlatformListenSocketKey = WSAEVENT;

    struct PlatformListenSocket {
        SOCKET handle;
        WSAEVENT eventHandle;

        NetworkAddress address;
        shared(bool) isAlive;

    @safe nothrow @nogc:
        this(return scope ref PlatformListenSocket other) scope {
            this.tupleof = other.tupleof;
        }

        void forceClose() scope {
            import core.sys.windows.windows : closesocket;

            closesocket(handle);
        }

        void shutdown() scope {
            import core.sys.windows.windows : shutdown, SD_BOTH;

            shutdown(handle, SD_BOTH);
        }

        void cleanup() scope @trusted {
            import core.sys.windows.windows : CloseHandle;

            CloseHandle(eventHandle);
        }
    }

    struct PlatformSocket {
        SOCKET handle;
        WSAEVENT onCloseEvent;
        OVERLAPPED readOverlapped, writeOverlapped;
        IOCPwork iocpWork;

        shared(bool) isShutdown, isClosed;

    @safe nothrow @nogc:

        void forceClose(scope SocketState* socketState) scope @trusted {
            import sidero.eventloop.tasks.future_completion;
            import sidero.eventloop.networking.sockets : Socket;
            import core.sys.windows.windows : closesocket;

            if(cas(isClosed, false, true)) {
                logger.debug_("Forcing closed socket ", this.handle);
                closesocket(handle);
                socketState.readingState.cleanup;
            }
        }

        void shutdown(scope SocketState* socketState, bool haveReferences = true) scope @trusted {
            import sidero.eventloop.internal.event_waiting;
            import core.sys.windows.windows : CloseHandle, SD_BOTH, shutdown;

            if(cas(isShutdown, false, true)) {
                logger.notice("Shutting down socket socket ", this.handle);
                onShutdownReadWriteEverything(socketState, haveReferences);
                shutdown(handle, SD_BOTH);

                if(onCloseEvent !is null) {
                    logger.info("Removing on close event ", this.handle);
                    removeEventWaiterHandle(onCloseEvent);
                    CloseHandle(onCloseEvent);
                    onCloseEvent = null;
                }
            }
        }

        void onShutdownReadWriteEverything(scope SocketState* socketState, bool haveReferences) scope @trusted {
            import sidero.eventloop.networking.sockets : Socket;
            import core.sys.windows.windows : ERROR_IO_PENDING, SOCKET_ERROR, WSAESHUTDOWN;

            if(atomicLoad(isShutdown))
                return;

            logger.debug_("On socket shutdown, trying to read and write everything before closing ", this.handle);

            bool somethingChanged = true;
            bool notLikelyToRead = !haveReferences, notLikelyToWrite;

            while(somethingChanged) {
                somethingChanged = false;

                // we need to do blocking reads and writes
                //  this will consume this thread (either event waiter or IOCP).
                // It isn't ideal, but the purpose is to guarantee that when we close a socket
                //  everything that we want read, and everything we want written has been read and written if able.

                {
                    // writes
                    somethingChanged = socketState.rawWritingState.protect(() @trusted nothrow @nogc {
                        bool didSomething;

                        while(socketState.rawWritingState.toSend.length > 0 && socketState.rawWritingState.waitingOnDataToSend == 0) {
                            auto firstItem = socketState.rawWritingState.toSend[0];
                            assert(firstItem);

                            // ok we can send this
                            WSABUF[1] buffers;
                            buffers[0].buf = cast(ubyte*)firstItem.ptr;

                            if(firstItem.length > uint.max)
                                buffers[0].len = uint.max;
                            else
                                buffers[0].len = cast(uint)firstItem.length;

                            DWORD amountSent, flags;
                            auto result = WSASend(this.handle, &buffers[0], 1, &amountSent, flags, null, null);

                            if(result == 0) {
                                // ok sent
                                logger.debug_("Socket has had data written to it ", this.handle);
                                socketState.rawWritingState.complete(amountSent);
                                didSomething = true;
                            } else {
                                auto error = GetLastError();

                                if(error == ERROR_IO_PENDING) {
                                    // ok this isn't too good, it means we probably won't send any more data.
                                    logger.debug_("Waiting for data written to complete via IOCP ", this.handle);
                                    socketState.rawWritingState.waitingOnDataToSend = amountSent;
                                    notLikelyToWrite = true;
                                    return true;
                                } else if(error == WSAENOTSOCK || error == WSAESHUTDOWN) {
                                    notLikelyToWrite = true;
                                    return false;
                                } else {
                                    logger.warning("Failed to write data to socket with error code ", error, " ", this.handle);
                                    return false;
                                }
                            }
                        }

                        return didSomething;
                    });
                }

                // if we are not in progress, don't waste memory and hence time
                if(!notLikelyToRead) {
                    logger.debug_("Reading is in progress, attempting to resolve ", this.handle);

                    // reads
                    socketState.rawReadingState.protectTriggeringOfRead(() @trusted {
                        const uint bufferNeeded = cast(uint)socketState.encryptionState.amountNeedToBeRead(socketState);
                        socketState.rawReadingState.prepareBufferFor(bufferNeeded);

                        logger.debug_("Preparing raw read with bytes ", bufferNeeded, " ", this.handle);

                        uint bufferLength = bufferNeeded;
                        if(socketState.rawReadingState.bufferToReadInto.length > bufferNeeded)
                            bufferLength = cast(uint)socketState.rawReadingState.bufferToReadInto.length;

                        WSABUF[1] buffers;

                        buffers[0].len = bufferLength;
                        buffers[0].buf = socketState.rawReadingState.bufferToReadInto.ptr +
                            socketState.rawReadingState.currentlyAvailableData.length;

                        DWORD received, flags;
                        auto result = WSARecv(this.handle, &buffers[0], 1, &received, &flags, null, null);

                        if(result == 0) {
                            // ok data has been acquired, excellant that was what we wanted
                            logger.debug_("Triggering read without delay ", this.handle);
                            socketState.rawReadingState.dataWasReceived(received);
                            somethingChanged = true;
                            return false;
                        } else if(result == SOCKET_ERROR) {
                            auto error = GetLastError();

                            if(error == ERROR_IO_PENDING) {
                                logger.debug_("Triggering read with delay in IOCP ", this.handle);
                                // ok this isn't too good, it means we probably won't receive any more data.
                                notLikelyToRead = true;
                                return false;
                            } else if(error == WSAENOTSOCK || error == WSAESHUTDOWN) {
                                notLikelyToRead = true;
                                return false;
                            } else {
                                logger.warning("Error failed to read on socket with error code ", error, " ", this.handle);
                            }
                        } else {
                            logger.warning("Error failed to read on socket with code ", result, " ", this.handle);
                        }

                        return false;
                    });

                    socketState.readingState.tryFulfillRequest(socketState);
                }
            }
        }

        bool triggerRead(SocketState* socketState, bool tryToFulfill = true) scope @trusted {
            import core.sys.windows.windows : ERROR_IO_PENDING, SOCKET_ERROR, GetLastError;

            if(tryToFulfill && socketState.readingState.tryFulfillRequest(socketState))
                return true;

            if(!atomicLoad(socketState.isAlive))
                return false;

            bool ret;
            socketState.rawReadingState.protectTriggeringOfRead(() @trusted {
                const uint bufferNeeded = cast(uint)socketState.encryptionState.amountNeedToBeRead(socketState);
                socketState.rawReadingState.prepareBufferFor(bufferNeeded);

                uint bufferLength = bufferNeeded;
                if(socketState.rawReadingState.bufferToReadInto.length > bufferNeeded)
                    bufferLength = cast(uint)socketState.rawReadingState.bufferToReadInto.length;

                WSABUF[1] buffers;

                buffers[0].len = bufferLength;
                buffers[0].buf = socketState.rawReadingState.bufferToReadInto.ptr +
                    socketState.rawReadingState.currentlyAvailableData.length;

                DWORD received, flags;

                // the read action goes through the IOCP handler

                this.readOverlapped = OVERLAPPED.init;
                auto result = WSARecv(this.handle, &buffers[0], 1, &received, &flags, &this.readOverlapped, null);

                if(result == 0) {
                    // ok, we have data DANGIT, this isn't supposed to happen!
                    // it should however still go through IOCP so don't worry about handling it
                    logger.debug_("Triggering read without delay ", this.handle);
                    ret = true;
                    return false;
                } else if(result == SOCKET_ERROR) {
                    auto error = GetLastError();

                    if(error == ERROR_IO_PENDING) {
                        logger.debug_("Triggering read with delay in IOCP ", this.handle);
                        // ok all good, this is what is expected (callback).
                        ret = true;
                        return true;
                    } else {
                        logger.warning("Error failed to read on socket with error code ", error, " ", this.handle);
                    }
                } else {
                    logger.warning("Error failed to read on socket with code ", result, " ", this.handle);
                }

                return false;
            });

            return ret;
        }

        bool triggerWrite(scope SocketState* socketState) scope @trusted {
            import core.sys.windows.windows : GetLastError, ERROR_IO_PENDING;

            if(!atomicLoad(socketState.isAlive))
                return false;

            return socketState.rawWritingState.protect(() @trusted nothrow @nogc {
                bool didSomething;

                while(socketState.rawWritingState.toSend.length > 0 && socketState.rawWritingState.waitingOnDataToSend == 0) {
                    auto firstItem = socketState.rawWritingState.toSend[0];
                    assert(firstItem);

                    // ok we can send this
                    WSABUF[1] buffers;
                    buffers[0].buf = cast(ubyte*)firstItem.ptr;

                    if(firstItem.length > uint.max)
                        buffers[0].len = uint.max;
                    else
                        buffers[0].len = cast(uint)firstItem.length;

                    DWORD amountSent, flags;
                    socketState.writeOverlapped = OVERLAPPED.init;

                    auto result = WSASend(this.handle, &buffers[0], 1, &amountSent, flags, &socketState.writeOverlapped, null);

                    if(result == 0) {
                        // ok sent
                        logger.debug_("Socket has had data written to it ", this.handle);
                        socketState.rawWritingState.complete(amountSent);
                        didSomething = true;
                    } else {
                        auto error = GetLastError();

                        if(error == ERROR_IO_PENDING) {
                            // ok
                            logger.debug_("Waiting for data written to complete via IOCP ", this.handle);
                            socketState.rawWritingState.waitingOnDataToSend = amountSent;
                            return true;
                        } else if(error == WSAENOTSOCK) {
                            // ok
                            logger.info("Socket has closed, cannot write data to it ", this.handle);
                            return false;
                        } else {
                            logger.warning("Failed to write data to socket with error code ", error, " ", this.handle);
                            return false;
                        }
                    }
                }

                return didSomething;
            });
        }
    }
}
