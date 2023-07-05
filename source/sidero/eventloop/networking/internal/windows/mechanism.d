module sidero.eventloop.networking.internal.windows.mechanism;
import sidero.eventloop.networking.internal.state;
import sidero.base.text;
import sidero.base.logger;
import sidero.base.path.networking;

@safe nothrow @nogc:

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import sidero.eventloop.internal.windows.iocp;

    package(sidero.eventloop.networking.internal.windows) __gshared {
        LoggerReference logger;
    }

    bool startUpNetworkingMechanism() @trusted {
        import core.sys.windows.windows : MAKEWORD, GetLastError, NO_ERROR;
        import core.sys.windows.winsock2;

        logger = Logger.forName(String_UTF8(__MODULE__));
        if (!logger)
            return false;

        enum WSAVersion = MAKEWORD(2, 2);

        WSADATA wsaData;
        int nResult = WSAStartup(WSAVersion, &wsaData);

        if (nResult != NO_ERROR) {
            logger.error("Error occured while executing WSAStartup with code", GetLastError(), nResult);
            return false;
        } else {
            logger.trace("WSA initialized successfully");
        }

        return true;
    }

    void shutdownNetworkingMechanism() {
        import core.sys.windows.winsock2 : WSACleanup;

        WSACleanup;
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

        shared(bool) isShutdown;

    @safe nothrow @nogc:

        void forceClose() scope {
            import core.sys.windows.windows : closesocket;

            closesocket(handle);
        }

        void cleanup() scope {
            import core.sys.windows.windows : shutdown, SD_RECEIVE;
            import core.atomic : atomicStore;

            shutdown(handle, SD_RECEIVE);
            atomicStore(isShutdown, true);
        }

        void shutdown() scope @trusted {
            import sidero.eventloop.internal.event_waiting;
            import core.sys.windows.windows : CloseHandle;

            if (onCloseEvent !is null) {
                removeEventWaiterHandle(onCloseEvent);
                CloseHandle(onCloseEvent);
                onCloseEvent = null;
            }
        }

        bool triggerRead(SocketState* socketState, bool tryToFulfill = true) scope @trusted {
            import core.sys.windows.windows : ERROR_IO_PENDING, SOCKET_ERROR, GetLastError;

            if (tryToFulfill && socketState.readingState.tryFulfillRequest(socketState))
                return true;

            return socketState.rawReadingState.protectTriggeringOfRead(() @trusted {
                const uint bufferNeeded = cast(uint)socketState.encryptionState.amountNeedToBeRead(socketState);
                socketState.rawReadingState.prepareBufferFor(bufferNeeded);

                uint bufferLength = bufferNeeded;
                if (socketState.rawReadingState.bufferToReadInto.length > bufferNeeded)
                    bufferLength = cast(uint)socketState.rawReadingState.bufferToReadInto.length;

                WSABUF[1] buffers;

                buffers[0].len = bufferLength;
                buffers[0].buf = socketState.rawReadingState.bufferToReadInto.ptr +
                    socketState.rawReadingState.currentlyAvailableData.length;

                DWORD received, flags;

                // the read action goes through the IOCP handler

                this.readOverlapped = OVERLAPPED.init;
                auto result = WSARecv(handle, &buffers[0], 1, &received, &flags, &this.readOverlapped, null);

                if (result == 0) {
                    // ok, we have data DANGIT, this isn't supposed to happen!
                    // it should however still go through IOCP so don't worry about handling it
                    logger.trace("Triggering read without delay ", handle);
                    return true;
                } else if (result == SOCKET_ERROR) {
                    auto error = GetLastError();

                    if (error == ERROR_IO_PENDING) {
                        logger.trace("Triggering read with delay in IOCP ", handle);
                        // ok all good, this is what is expected (callback).
                        return true;
                    } else {
                        logger.error("Error failed to read on socket with error code ", error, " ", handle);
                    }
                } else {
                    logger.error("Error failed to read on socket with code ", result, " ", handle);
                }

                return false;
            });
        }

        bool triggerWrite(scope SocketState* state) scope @trusted {
            import core.sys.windows.windows : GetLastError, ERROR_IO_PENDING;

            return state.writing.protect(() @trusted nothrow @nogc {
                bool didSomething;

                while (state.writing.toSend.length == 1) {
                    auto firstItem = state.writing.toSend[0];
                    assert(firstItem);

                    // ok we can send this
                    WSABUF[1] buffers;
                    buffers[0].buf = cast(ubyte*)firstItem.ptr;

                    if (firstItem.length > uint.max)
                        buffers[0].len = uint.max;
                    else
                        buffers[0].len = cast(uint)firstItem.length;

                    DWORD amountSent, flags;
                    state.writeOverlapped = OVERLAPPED.init;

                    auto result = WSASend(state.handle, &buffers[0], 1, &amountSent, flags, &state.writeOverlapped, null);

                    if (result == 0) {
                        // ok sent
                        logger.trace("Socket has had data written to it", handle);
                        state.writing.complete(amountSent);
                        didSomething = true;
                    } else {
                        auto error = GetLastError();

                        if (error == ERROR_IO_PENDING) {
                            // ok
                            logger.trace("Waiting for data written to complete via IOCP", handle);
                            return true;
                        } else {
                            logger.error("Failed to write data to socket with error code", error, handle);
                            return false;
                        }
                    }
                }

                return didSomething;
            });
        }
    }
}
