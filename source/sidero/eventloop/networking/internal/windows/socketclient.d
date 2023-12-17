module sidero.eventloop.networking.internal.windows.socketclient;
import sidero.eventloop.networking.internal.windows.mechanism;
import sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.internal.windows.iocp;
import sidero.eventloop.internal.windows.bindings;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.threads;
import sidero.base.containers.readonlyslice;
import sidero.base.errors;
import sidero.base.path.networking;
import sidero.base.path.hostname;
import sidero.base.typecons : Optional;
import sidero.base.datetime.duration;

@safe nothrow @nogc:

struct PlatformSocket {
    version(Windows) {
        SOCKET handle;
        WSAEVENT onCloseEvent;
        OVERLAPPED readOverlapped, writeOverlapped;
        IOCPwork iocpWork;
    }

    shared(bool) isClosed;
    bool isWaitingForRetrigger;

@safe nothrow @nogc:

    // NOTE: needs to be guarded
    private void needToBeRetriggered(scope SocketState* socketState) scope @trusted {
        if(isWaitingForRetrigger)
            return;

        Socket socket;
        socket.state = socketState;
        socket.state.rc(true);

        isWaitingForRetrigger = true;
        addSocketToRetrigger(socket);
    }

    // NOTE: must not be guarded
    package(sidero.eventloop.networking.internal.windows) {
        void haveBeenRetriggered(scope SocketState* socketState) scope {
            isWaitingForRetrigger = false;

            socketState.guard(&socketState.performReadWrite);
        }
    }
}

ErrorResult connectToSpecificAddress(Socket socket, NetworkAddress address, Optional!uint keepAlive) @trusted {
    version(Windows) {
        SocketState* socketState = socket.state;

        enum SockAddress4Size = sockaddr_in.sizeof;
        enum SockAddress6Size = sockaddr_in6.sizeof;
        enum SockAddressMaxSize = SockAddress6Size > SockAddress4Size ? SockAddress6Size : SockAddress4Size;

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

        if (keepAlive) {
            // keepAlive is in milliseconds
            uint keepAliveValue = cast(uint)keepAlive.get.totalSeconds;

            if(setsockopt(socketState.handle, SOL_SOCKET, SO_KEEPALIVE, cast(uint*)&keepAliveValue, 4) != 0) {
                logger.notice("Could not set SO_KEEPALIVE ", socketState.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(socketState.handle);
                return ErrorResult(UnknownPlatformBehaviorException("Could not set keep alive status to socket"));
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

        {
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

        addEventWaiterHandle(socketState.onCloseEvent, &handleSocketEvent, socketState);
        socketState.pin();
        return ErrorResult.init;
    } else
        assert(0);
}

void shutdown(scope SocketState* socketState, bool haveReferences = true) @trusted {
    version(Windows) {
        import sidero.base.internal.atomic;
        import core.sys.windows.windows : shutdown;

        if(cas(socketState.isShutdown, false, true)) {
            logger.notice("Shutting down socket ", socketState.handle, " on ", Thread.self);
            socketState.performReadWrite();
            shutdown(socketState.handle, SD_SEND);

            if(socketState.onCloseEvent !is null) {
                logger.info("Removing on close event ", socketState.handle, " on ", Thread.self);
                removeEventWaiterHandle(socketState.onCloseEvent);
                CloseHandle(socketState.onCloseEvent);
                socketState.onCloseEvent = null;
            }

            if (socketState.rawReading.inProgress) {
                CancelIoEx(socketState.handle, &socketState.readOverlapped);
            }

            socketState.reading.cleanup();
            socketState.performReadWrite();
        }
    } else
        assert(0);
}

void forceClose(scope SocketState* socketState) @trusted {
    version(Windows) {
        import sidero.base.internal.atomic;
        import core.sys.windows.windows : closesocket;

        if(cas(socketState.isClosed, false, true)) {
            logger.debug_("Forcing closed socket ", socketState.handle);
            closesocket(socketState.handle);
        }
    } else
        assert(0);
}

bool tryWriteMechanism(scope SocketState* socketState, ubyte[] buffer) @trusted {
    version(Windows) {
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
        socketState.readOverlapped = OVERLAPPED.init;

        WSABUF wsaBuffer;
        wsaBuffer.buf = buffer.ptr;
        wsaBuffer.len = cast(uint)buffer.length;

        DWORD transferredBytes;
        DWORD flags;
        auto result = WSARecv(socketState.handle, &wsaBuffer, 1, &transferredBytes, &flags, &socketState.readOverlapped, null);

        if(result == 0) {
            // completed, transferredBytes will have the amount of data that was copied in
            logger.debug_("Immediate completion of read ", socketState.handle, " on ", Thread.self);
            //socketState.rawReading.complete(socketState, transferredBytes);
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
                socketState.unpin;
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
                socketState.unpin();
            } else {
                logger.info("Unknown socket event ", wsaEvent, " for ", socketState.handle, " on ", Thread.self);
            }
        } else {
            logger.debug_("Socket got network event and shouldn't have (may indicate a bug) ", socketState.handle, " on ", Thread.self);
        }
    } else
        assert(0);
}
