module sidero.eventloop.internal.networking.windows.old_socketclient;
import sidero.eventloop.internal.networking.windows.mechanism;
import sidero.eventloop.internal.networking.state.socket;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.internal.workers.kernelwait.windows;
import sidero.eventloop.internal.windows.bindings;
import sidero.eventloop.sockets;
import sidero.eventloop.threads;
import sidero.base.containers.readonlyslice;
import sidero.base.errors;
import sidero.base.path.networking;
import sidero.base.path.hostname;
import sidero.base.typecons : Optional;
import sidero.base.datetime.duration;
import sidero.base.allocators;
__EOF__
@safe nothrow @nogc:

struct PlatformSocket {
    version(Windows) {
        SOCKET handle;
        WSAEVENT onCloseEvent;
        OVERLAPPED readOverlapped, writeOverlapped, acceptOverlapped;
        IOCPwork iocpWork;
    }

    shared(bool) isClosed;
    bool isWaitingForRetrigger;
    bool havePendingAlwaysWaitingRead, havePendingRead;
    bool isDelayedAccept;

    //enum keepAReadAlwaysGoing = false;
    enum keepAReadAlwaysGoing = true;

    ubyte[(SockAddressMaxSize * 2) + 32] addressBuffer;

@safe nothrow @nogc:

     ~this() scope {
    }

    // NOTE: needs to be guarded
    private void needToBeRetriggered(scope SocketState* socketState) scope @trusted {
        import sidero.eventloop.internal.cleanup_timer;
        import sidero.base.internal.atomic : atomicLoad;

        if(isWaitingForRetrigger || atomicLoad(isClosed))
            return;

        Socket socket;
        socket.state = socketState;
        socket.state.rc(true);

        isWaitingForRetrigger = true;
        addSocketToRetrigger(socket);
    }

    private bool acquireAddresses(scope SocketState* socketState) scope @trusted {
        version(Windows) {
            ubyte[SockAddressMaxSize] addressBuffer;
            sockaddr_in* addressPtr = cast(sockaddr_in*)addressBuffer.ptr;

            int addressSize = SockAddressMaxSize;
            bool haveError;

            NetworkAddress handle(int result) {
                if(result != 0) {
                    logger.notice("Error could not acquire network address for socket client ", socketState.handle,
                            " with error ", WSAGetLastError(), " on ", Thread.self);
                    haveError = true;
                    return NetworkAddress.init;
                }

                NetworkAddress address;

                if(addressPtr.sin_family == AF_INET) {
                    sockaddr_in* localAddress4 = addressPtr;
                    address = NetworkAddress.fromIPv4(localAddress4.sin_port, localAddress4.sin_addr.s_addr, true, true);
                } else if(addressPtr.sin_family == AF_INET6) {
                    sockaddr_in6* localAddress6 = cast(sockaddr_in6*)addressPtr;
                    address = NetworkAddress.fromIPv6(localAddress6.sin6_port, localAddress6.sin6_addr.Word, true, true);
                }

                bool notRecognized;

                address.onNetworkOrder((value) {
                    // ipv4
                }, (value) {
                    // ipv6
                }, () {
                    // any4
                    notRecognized = true;
                }, () {
                    // any6
                    notRecognized = true;
                }, (scope String_ASCII) {
                    // hostname
                    notRecognized = true;
                }, () {
                    // invalid
                    notRecognized = true;
                });

                if(notRecognized) {
                    logger.notice("Did not recognize an IP address for socket client local ", address, " remote ",
                            address, " for ", socketState.handle, " on ", Thread.self);
                    haveError = true;
                    return NetworkAddress.init;
                } else
                    return address;
            }

            addressSize = SockAddressMaxSize;
            socketState.localAddress = handle(getsockname(this.handle, cast(sockaddr*)addressBuffer.ptr, &addressSize));
            addressSize = SockAddressMaxSize;
            socketState.remoteAddress = handle(getpeername(this.handle, cast(sockaddr*)addressBuffer.ptr, &addressSize));

            return !haveError;
        } else
            assert(0);
    }

    package(sidero.eventloop.internal) {
        // NOTE: must not be guarded
        void haveBeenRetriggered(scope SocketState* socketState) scope {
            isWaitingForRetrigger = false;

            socketState.guard(&socketState.performReadWrite);
        }

        // needs guarding
        void uponAccept(Socket socket) scope @trusted {
            version(Windows) {
                import sidero.eventloop.internal.networking.windows.old_socketserver : checkForAccepts;
                import sidero.eventloop.tasks.workers : registerAsTask;

                logger.debug_("Received accept for socket ", socket.state.handle, " on ", Thread.self);

                if(socket.state.isDelayedAccept)
                    socket.state.rc(false);

                if(socket.state.listenSocketPair.isNull)
                    return;

                checkForAccepts(socket.state.listenSocketPair);

                assert(socket.state.listenSocketPair.perSocket);
                auto result = setsockopt(this.handle, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT,
                        &socket.state.listenSocketPair.perSocket.handle, SOCKET.sizeof);

                if(result == SOCKET_ERROR) {
                    logger.debug_("Failed to configure accepted socket for listen socket with error ", WSAGetLastError(), " for ",
                            this.handle, " for listen ", socket.state.listenSocketPair.perSocket.handle, " on ", Thread.self);
                    socket.state.unpinGuarded;
                    return;
                }

                if(!this.acquireAddresses(socket.state)) {
                    socket.state.unpinGuarded;
                    return;
                }

                if(socket.state.isDelayedAccept) {
                    socket.state.rc(false);

                    auto acceptSocketCO = socket.state.listenSocketPair.listenSocket.state.onAccept.makeInstance(RCAllocator.init, socket);
                    registerAsTask(acceptSocketCO);
                }

                static if(socket.state.keepAReadAlwaysGoing) {
                    socket.state.initiateAConstantlyRunningReadRequest(socket.state);
                } else {
                    addEventWaiterHandle(socket.state.onCloseEvent, &handleSocketEvent, socket.state);
                }
            } else
                assert(0);
        }
    }

    void initiateAConstantlyRunningReadRequest(scope SocketState* socketState) scope @trusted {
        version(Windows) {
            import sidero.base.internal.atomic : atomicLoad;

            if(atomicLoad(socketState.isShutdown) || this.havePendingAlwaysWaitingRead || this.havePendingRead)
                return;

            this.readOverlapped = OVERLAPPED.init;
            this.havePendingAlwaysWaitingRead = true;

            logger.debug_("Starting a constantly running read request for ", socketState.handle, " on ", Thread.self);

            DWORD flags;

            ubyte[1] buf;
            WSABUF wsaBuffer;
            wsaBuffer.buf = buf.ptr;

            auto result = WSARecv(socketState.handle, &wsaBuffer, 1, null, &flags, &this.readOverlapped, null);

            if(result == 0) {
                // completed, IOCP will be notified of completion
                logger.trace("Immediate completion of read ", socketState.handle, " on ", Thread.self);
            } else {
                const errorCode = WSAGetLastError();

                switch(errorCode) {
                case WSA_OPERATION_ABORTED:
                case WSAETIMEDOUT:
                case WSAESHUTDOWN:
                case WSAENOTSOCK:
                case WSAENOTCONN:
                case WSAENETRESET:
                case WSAENETDOWN:
                case WSAEINVAL:
                case WSAEINTR:
                case WSAEDISCON:
                case WSAECONNRESET:
                case WSAECONNABORTED:
                case WSANOTINITIALISED:
                case WSAEMSGSIZE:
                case WSAEFAULT:
                case WSAEINPROGRESS:
                case WSAEOPNOTSUPP:
                    havePendingAlwaysWaitingRead = false;

                    // these are all failure modes for a socket
                    // we must make sure to tell the socket that we are no longer connected
                    logger.info("Failed to read initiate closing ", errorCode, " for ", socketState.handle, " on ", Thread.self);
                    socketState.unpin;
                    return;

                case WSAEWOULDBLOCK, WSA_IO_PENDING:
                    // this is okay, its delayed via IOCP
                    logger.debug_("Reading delayed via IOCP for ",
                            socketState.handle, " on ", Thread.self);
                    return;

                default:
                    havePendingAlwaysWaitingRead = false;
                    logger.notice("Unknown error while reading ", errorCode, " for ", socketState.handle, " on ", Thread.self);
                    return;
                }
            }
        } else
            assert(0);
    }

    void notifiedOfReadComplete(scope SocketState* socketState) scope @trusted {
        this.havePendingAlwaysWaitingRead = false;
        this.havePendingRead = false;
    }
}

ErrorResult connectToSpecificAddress(Socket socket, NetworkAddress address) @trusted {
    version(Windows) {
        SocketState* socketState = socket.state;

        ubyte[SockAddressMaxSize] localAddressBuffer, remoteAddressBuffer;
        int localAddressSize = SockAddressMaxSize, remoteAddressSize;
        short addressFamily, socketType, socketProtocol;

        {
            bool validAddress;

            address.onNetworkOrder((uint value) @trusted {
                //ipv4
                addressFamily = AF_INET;
                remoteAddressSize = SockAddress4Size;

                sockaddr_in* saPtr = cast(sockaddr_in*)remoteAddressBuffer.ptr;
                saPtr.sin_family = AF_INET;
                saPtr.sin_addr.s_addr = value;
                saPtr.sin_port = address.networkOrderPort();
                validAddress = true;
            }, (ushort[8] value) @trusted {
                // ipv6
                addressFamily = AF_INET6;
                remoteAddressSize = SockAddress6Size;

                sockaddr_in6* saPtr = cast(sockaddr_in6*)remoteAddressBuffer.ptr;
                saPtr.sin6_family = AF_INET6;
                saPtr.sin6_addr.Word = value;
                saPtr.sin6_port = address.networkOrderPort();
                validAddress = true;
            }, () @trusted {
                // any ipv4
            }, () @trusted {
                // any ipv6
            }, (scope Hostname hostname) {
                // needs to be have been already resolved
            }, () {});

            if(!validAddress)
                return ErrorResult(MalformedInputException("Not a valid network address, must be resolved ip/port"));
        }

        final switch(socketState.protocol) {
        case Socket.Protocol.TCP:
            socketType = SOCK_STREAM;
            socketProtocol = IPPROTO_TCP;
            break;
        case Socket.Protocol.UDP:
            socketType = SOCK_DGRAM;
            socketProtocol = IPPROTO_UDP;
            break;
        }

        {
            socketState.handle = WSASocketW(addressFamily, socketType, socketProtocol, null, 0, WSA_FLAG_OVERLAPPED);

            if(socketState.handle == INVALID_SOCKET) {
                logger.notice("Could not open socket ", address, " with error ", WSAGetLastError(), " on ", Thread.self);
                return ErrorResult(UnknownPlatformBehaviorException("Could not create socket"));
            } else {
                logger.debug_("Socket created successfully ", socketState.handle, " at ", address, " on ", Thread.self);
            }
        }

        {
            if(connect(socketState.handle, cast(sockaddr*)remoteAddressBuffer.ptr, remoteAddressSize) == SOCKET_ERROR) {
                logger.notice("Could not connect to address on port ", socketState.handle, " with error ",
                        WSAGetLastError(), " on ", Thread.self);
                closesocket(socketState.handle);
                return ErrorResult(UnknownPlatformBehaviorException("Could not connect socket to address"));
            } else {
                logger.debug_("Connected to port successfully ", socketState.handle, " on ", Thread.self);
            }
        }

        if(!socketState.keepAReadAlwaysGoing) {
            socketState.onCloseEvent = WSACreateEvent();

            if(socketState.onCloseEvent is WSA_INVALID_EVENT) {
                logger.notice("Error occured while creating the close event ", socketState.handle, " with error ",
                        WSAGetLastError(), " on ", Thread.self);
                closesocket(socketState.handle);
                return ErrorResult(UnknownPlatformBehaviorException("Could not create on close event for socket"));
            } else {
                logger.debug_("WSA close event created ", socketState.handle, " on ", Thread.self);
            }

            if(WSAEventSelect(socketState.handle, socketState.onCloseEvent, FD_CLOSE) == SOCKET_ERROR) {
                logger.notice("Error could not associated on close event with socket accept event ",
                        socketState.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(socketState.handle);
                CloseHandle(socketState.onCloseEvent);
                return ErrorResult(UnknownPlatformBehaviorException("Could not associate on close event for socket"));
            } else {
                logger.debug_("Associated close event with socket on port ", socketState.onCloseEvent, " for ",
                        socketState.handle, " on ", Thread.self);
            }
        }

        if(!associateWithIOCP(socket)) {
            closesocket(socketState.handle);
            CloseHandle(socketState.onCloseEvent);
            return ErrorResult(UnknownPlatformBehaviorException("Could not associate socket with IOCP workers"));
        } else {
            logger.debug_("Associated connection with IOCP ", socketState.handle, " on ", Thread.self);
        }

        {
            NetworkAddress localAddress;
            sockaddr_in* localAddressPtr = cast(sockaddr_in*)localAddressBuffer.ptr;

            if(getsockname(socketState.handle, cast(sockaddr*)localAddressBuffer.ptr, &localAddressSize) != 0) {
                logger.notice("Error could not acquire local network address for socket client ", socketState.handle,
                        " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(socketState.handle);
                CloseHandle(socketState.onCloseEvent);
                return ErrorResult(UnknownPlatformBehaviorException("Could not associate on close event for socket"));
            }

            if(localAddressPtr.sin_family == AF_INET) {
                sockaddr_in* localAddress4 = localAddressPtr;
                localAddress = NetworkAddress.fromIPv4(localAddress4.sin_port, localAddress4.sin_addr.s_addr, true, true);
            } else if(localAddressPtr.sin_family == AF_INET6) {
                sockaddr_in6* localAddress6 = cast(sockaddr_in6*)localAddressPtr;
                localAddress = NetworkAddress.fromIPv6(localAddress6.sin6_port, localAddress6.sin6_addr.Word, true, true);
            }

            bool notRecognized;

            localAddress.onNetworkOrder((value) {
                // ipv4
            }, (value) {
                // ipv6
            }, () {
                // any4
                notRecognized = true;
            }, () {
                // any6
                notRecognized = true;
            }, (scope String_ASCII) {
                // hostname
                notRecognized = true;
            }, () {
                // invalid
                notRecognized = true;
            });

            if(notRecognized) {
                logger.notice("Did not recognize an IP address for socket client local ", localAddress, " remote ",
                        address, " for ", socketState.handle, " on ", Thread.self);
                closesocket(socketState.handle);
                CloseHandle(socketState.onCloseEvent);
                return ErrorResult(UnknownPlatformBehaviorException("Could not acquire local address for client socket"));
            } else {
                logger.debug_("Connected socket addresses local ", localAddress, " remote ", address, " for ",
                        socketState.handle, " on ", Thread.self);
            }

            socketState.localAddress = localAddress;
            socketState.remoteAddress = address;
        }

        if(!socketState.keepAReadAlwaysGoing)
            addEventWaiterHandle(socketState.onCloseEvent, &handleSocketEvent, socketState);

        socketState.pin();

        if(socketState.keepAReadAlwaysGoing)
            socketState.initiateAConstantlyRunningReadRequest(socketState);

        return ErrorResult.init;
    } else
        assert(0);
}

void shutdown(scope SocketState* socketState, bool haveReferences = true) @trusted {
    version(Windows) {
        import sidero.base.internal.atomic;
        import core.sys.windows.winsock2 : shutdown;

        if(cas(socketState.isShutdown, false, true)) {
            logger.info("Shutting down socket ", socketState.handle, " on ", Thread.self);
            socketState.performReadWrite();
            shutdown(socketState.handle, SD_SEND);

            if(socketState.onCloseEvent !is null) {
                logger.info("Removing on close event ", socketState.handle, " on ", Thread.self);
                removeEventWaiterHandle(socketState.onCloseEvent);
                CloseHandle(socketState.onCloseEvent);
                socketState.onCloseEvent = null;
            }

            if(socketState.rawReading.inProgress) {
                CancelIoEx(socketState.handle, &socketState.readOverlapped);
            }

            socketState.reading.cleanup();
            socketState.performReadWrite();
            forceClose(socketState);
        }
    } else
        assert(0);
}

void forceClose(scope SocketState* socketState) @trusted {
    version(Windows) {
        import sidero.base.internal.atomic;
        import core.sys.windows.winsock2 : closesocket;

        if(cas(socketState.isClosed, false, true)) {
            logger.debug_("Forcing closed socket ", socketState.handle);
            closesocket(socketState.handle);
        }
    } else
        assert(0);
}

bool tryWriteMechanism(scope SocketState* socketState, ubyte[] buffer) @trusted {
    version(Windows) {
        if(socketState.haveBeenShutdown())
            return false;

        socketState.writeOverlapped = OVERLAPPED.init;

        WSABUF wsaBuffer;
        wsaBuffer.buf = buffer.ptr;
        wsaBuffer.len = cast(uint)buffer.length;

        DWORD transferredBytes;
        DWORD flags;
        auto result = WSASend(socketState.handle, &wsaBuffer, 1, &transferredBytes, flags, &socketState.writeOverlapped, null);

        if(result == 0) {
            // completed, transferredBytes will have the amount of data that was sent
            logger.debug_("Immediate completion of write ", socketState.handle, " on ", Thread.self);
            //socketState.rawWriting.complete(socketState, transferredBytes);
            return true;
        } else {
            const errorCode = WSAGetLastError();

            switch(errorCode) {
            case WSAECONNABORTED:
            case WSAECONNRESET:
            case WSAEFAULT:
            case WSAEINTR:
            case WSAEINPROGRESS:
            case WSAEINVAL:
            case WSAEMSGSIZE:
            case WSAENETDOWN:
            case WSAENETRESET:
            case WSAENOBUFS:
            case WSAENOTCONN:
            case WSAENOTSOCK:
            case WSAEOPNOTSUPP:
            case WSAESHUTDOWN:
            case WSANOTINITIALISED:
            case WSA_OPERATION_ABORTED:
                // these are all failure modes for a socket
                // we must make sure to tell the socket that we are no longer connected
                logger.info("Failed to write initiate closing ", errorCode, " for ", socketState.handle, " on ", Thread.self);
                socketState.unpinGuarded;
                break;

            case WSAEWOULDBLOCK:
                // we cannot write right now, so we'll say none is written and attempt again later
                socketState.needToBeRetriggered(socketState);
                logger.debug_("Writing failed as it would block, try again later for ", socketState.handle, " on ", Thread.self);
                break;

            case WSA_IO_PENDING:
                // this is okay, its delayed via IOCP
                logger.debug_("Writing delayed via IOCP for ", socketState.handle, " on ", Thread.self);
                return true;

            default:
                logger.notice("Unknown error while writing ", errorCode, " for ", socketState.handle, " on ", Thread.self);
                break;
            }

            return false;
        }
    } else
        assert(0);
}

bool tryReadMechanism(scope SocketState* socketState, ubyte[] buffer) @trusted {
    version(Windows) {
        if(socketState.haveBeenShutdown())
            return false;

        if(socketState.havePendingAlwaysWaitingRead) {
            CancelIoEx(socketState.handle, &socketState.readOverlapped);
            socketState.havePendingAlwaysWaitingRead = false;
        }

        socketState.havePendingRead = true;
        socketState.readOverlapped = OVERLAPPED.init;

        DWORD flags;
        WSABUF wsaBuffer;
        wsaBuffer.buf = buffer.ptr;
        wsaBuffer.len = cast(uint)buffer.length;

        auto result = WSARecv(socketState.handle, &wsaBuffer, 1, null, &flags, &socketState.readOverlapped, null);

        if(result == 0) {
            // completed, IOCP will be notified of completion
            logger.debug_("Immediate completion of read ", socketState.handle, " on ", Thread.self);
            return true;
        } else {
            const errorCode = WSAGetLastError();

            switch(errorCode) {
            case WSA_OPERATION_ABORTED:
            case WSAETIMEDOUT:
            case WSAESHUTDOWN:
            case WSAENOTSOCK:
            case WSAENOTCONN:
            case WSAENETRESET:
            case WSAENETDOWN:
            case WSAEINVAL:
            case WSAEINTR:
            case WSAEDISCON:
            case WSAECONNRESET:
            case WSAECONNABORTED:
            case WSANOTINITIALISED:
            case WSAEMSGSIZE:
            case WSAEFAULT:
            case WSAEINPROGRESS:
            case WSAEOPNOTSUPP:
                // these are all failure modes for a socket
                // we must make sure to tell the socket that we are no longer connected
                logger.info("Failed to read initiate closing ", errorCode, " for ", socketState.handle, " on ", Thread.self);
                socketState.unpinGuarded;
                break;

            case WSAEWOULDBLOCK:
                // we cannot read right now, so we'll say none is read and attempt again later
                socketState.needToBeRetriggered(socketState);
                logger.debug_("Reading failed as it would block, try again later for ", socketState.handle, " on ", Thread.self);
                break;

            case WSA_IO_PENDING:
                // this is okay, its delayed via IOCP
                logger.debug_("Reading delayed via IOCP for ", socketState.handle, " on ", Thread.self);
                return true;

            default:
                logger.notice("Unknown error while reading ", errorCode, " for ", socketState.handle, " on ", Thread.self);
                break;
            }

            return false;
        }
    } else
        assert(0);
}

void handleSocketEvent(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version(Windows) {
        SocketState* socketState = cast(SocketState*)user;
        WSANETWORKEVENTS wsaEvent;

        if(socketState.onCloseEvent !is null) {
            if(WSAEnumNetworkEvents(socketState.handle, socketState.onCloseEvent, &wsaEvent) != 0) {
                auto error = WSAGetLastError();

                if(error == WSAENOTSOCK) {
                    logger.debug_("Handle not socket message for ", socketState.handle, " on ", Thread.self);
                    // ok just in case lets just unpin it
                    socketState.unpin;
                } else {
                    logger.error("Error could not enumerate WSA network socket events with code ", error, " for ",
                            socketState.handle, " on ", Thread.self);
                }
            } else if((wsaEvent.lNetworkEvents & FD_CLOSE) == FD_CLOSE && wsaEvent.iErrorCode[FD_CLOSE_BIT] == 0) {
                logger.debug_("Socket closed ", socketState.handle, " on ", Thread.self);
                socketState.unpin;
            } else {
                logger.info("Unknown socket event ", wsaEvent, " for ", socketState.handle, " on ", Thread.self);
            }
        } else {
            logger.debug_("Socket got network event and shouldn't have (may indicate a bug) ", socketState.handle, " on ", Thread.self);
        }
    } else
        assert(0);
}
