module sidero.eventloop.networking.internal.windows.socket_client;
import sidero.eventloop.networking.internal.windows.mechanism;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.internal.event_waiting : addEventWaiterHandle;
import sidero.eventloop.networking.sockets;
import sidero.base.path.networking;
import sidero.base.text;
import sidero.base.errors;

@safe nothrow @nogc:

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;

    ErrorResult connectToSpecificAddress(Socket socket, NetworkAddress address, bool keepAlive) @trusted {
        import sidero.eventloop.internal.windows.iocp : associateWithIOCP;
        import core.sys.windows.windows : AF_INET, AF_INET6, SOCK_STREAM, SOCK_DGRAM, INVALID_SOCKET, WSAGetLastError,
            sockaddr_in, sockaddr_in6, INADDR_ANY, IN6ADDR_ANY, connect, SOCKET_ERROR, closesocket, sockaddr,
            SOL_SOCKET, setsockopt, SO_KEEPALIVE, CloseHandle, GetLastError;

        SocketState* socketState = socket.state;

        enum SockAddress4Size = sockaddr_in.sizeof;
        enum SockAddress6Size = sockaddr_in6.sizeof;
        enum SockAddressMaxSize = SockAddress6Size > SockAddress4Size ? SockAddress6Size : SockAddress4Size;

        ubyte[SockAddressMaxSize] localAddressBuffer, remoteAddressBuffer;
        int localAddressSize = SockAddressMaxSize, remoteAddressSize;
        short addressFamily, socketType;

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
                saPtr.sin6_addr.s6_addr16 = value;
                saPtr.sin6_port = address.networkOrderPort();
                validAddress = true;
            }, () @trusted {
                // any ipv4
            }, () @trusted {
                // any ipv6
            }, (scope String_ASCII hostname) {
                // needs to be have been already resolved
            }, () {});

            if(!validAddress)
                return ErrorResult(MalformedInputException("Not a valid network address, must be resolved ip/port"));
        }

        final switch(socketState.protocol) {
        case Socket.Protocol.TCP:
            socketType = SOCK_STREAM;
            break;
        case Socket.Protocol.UDP:
            socketType = SOCK_DGRAM;
            break;
        }

        {
            socketState.handle = WSASocketW(addressFamily, socketType, 0, null, 0, WSA_FLAG_OVERLAPPED);

            if(socketState.handle == INVALID_SOCKET) {
                logger.error("Error could not open socket ", address, " ", WSAGetLastError());
                return ErrorResult(UnknownPlatformBehaviorException("Could not create socket"));
            } else {
                logger.trace("Socket created successfully");
            }
        }

        {
            if(keepAlive && setsockopt(socketState.handle, SOL_SOCKET, SO_KEEPALIVE, cast(char*)&keepAlive, 1) != 0) {
                logger.error("Error could not set SO_KEEPALIVE ", address, " ", WSAGetLastError());
                closesocket(socketState.handle);
                return ErrorResult(UnknownPlatformBehaviorException("Could not set keep alive status to socket"));
            }
        }

        {
            if(connect(socketState.handle, cast(sockaddr*)remoteAddressBuffer.ptr, remoteAddressSize) == SOCKET_ERROR) {
                logger.error("Error could not connect to address on port ", address, " ", WSAGetLastError());
                closesocket(socketState.handle);
                return ErrorResult(UnknownPlatformBehaviorException("Could not connect socket to address"));
            } else {
                logger.trace("Connected to port successfully ", address);
            }
        }

        {
            socketState.onCloseEvent = WSACreateEvent();

            if(socketState.onCloseEvent is WSA_INVALID_EVENT) {
                logger.error("Error occured while creating the close event with code ", address, " ", GetLastError());
                closesocket(socketState.handle);
                return ErrorResult(UnknownPlatformBehaviorException("Could not create on close event for socket"));
            } else {
                logger.trace("WSA close event created ", address);
            }

            if(WSAEventSelect(socketState.handle, socketState.onCloseEvent, FD_CLOSE) == SOCKET_ERROR) {
                logger.error("Error could not associated on close event with socket accept event ", address, " ", GetLastError());
                closesocket(socketState.handle);
                CloseHandle(socketState.onCloseEvent);
                return ErrorResult(UnknownPlatformBehaviorException("Could not associate on close event for socket"));
            } else {
                logger.trace("Associated close event with socket on port ", address);
            }
        }

        if(!associateWithIOCP(socket)) {
            closesocket(socketState.handle);
            CloseHandle(socketState.onCloseEvent);
            return ErrorResult(UnknownPlatformBehaviorException("Could not associate socket with IOCP workers"));
        } else {
            logger.trace("Associated connection with IOCP ", socketState);
        }

        {
            NetworkAddress localAddress;
            sockaddr_in* localAddressPtr = cast(sockaddr_in*)localAddressBuffer.ptr;

            if(getsockname(socketState.handle, cast(sockaddr*)localAddressBuffer.ptr, &localAddressSize) != 0) {
                logger.error("Error could not acquire local network address for socket client ", address, " ", GetLastError());
                closesocket(socketState.handle);
                CloseHandle(socketState.onCloseEvent);
                return ErrorResult(UnknownPlatformBehaviorException("Could not associate on close event for socket"));
            }

            if(localAddressPtr.sin_family == AF_INET) {
                sockaddr_in* localAddress4 = localAddressPtr;
                localAddress = NetworkAddress.fromIPv4(localAddress4.sin_port, localAddress4.sin_addr.s_addr, true, true);
            } else if(localAddressPtr.sin_family == AF_INET6) {
                sockaddr_in6* localAddress6 = cast(sockaddr_in6*)localAddressPtr;
                localAddress = NetworkAddress.fromIPv6(localAddress6.sin6_port, localAddress6.sin6_addr.s6_addr16, true, true);
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
                logger.error("Did not recognize an IP address for socket client ", localAddress, " ", address, " ", socketState.handle);
                closesocket(socketState.handle);
                CloseHandle(socketState.onCloseEvent);
                return ErrorResult(UnknownPlatformBehaviorException("Could not acquire local address for client socket"));
            } else {
                logger.trace("Connected socket addresses ", localAddress, " ", address, " ", socketState.handle);
            }

            socketState.localAddress = localAddress;
            socketState.remoteAddress = address;
        }

        addEventWaiterHandle(socketState.onCloseEvent, &handleSocketEvent, socketState);
        socketState.pin();
        return ErrorResult.init;
    }

    void handleSocketEvent(void* handle, void* user) @trusted {
        import core.sys.windows.windows : closesocket, GetLastError, WSAENOTSOCK;

        SocketState* socketState = cast(SocketState*)user;
        WSANETWORKEVENTS wsaEvent;

        if (socketState.onCloseEvent !is null) {
            if (WSAEnumNetworkEvents(socketState.handle, socketState.onCloseEvent, &wsaEvent) != 0) {
                auto error = GetLastError();

                if (error == WSAENOTSOCK) {
                    logger.trace("Handle not socket message ", socketState.handle);
                    // ok just in case lets just unpin it
                    socketState.unpin;
                } else {
                    logger.error("Error could not enumerate WSA network socket events with code ", error, " ", socketState.handle);
                }
            } else if ((wsaEvent.lNetworkEvents & FD_CLOSE) == FD_CLOSE && wsaEvent.iErrorCode[FD_CLOSE_BIT] == 0) {
                socketState.onShutdownReadWriteEverything(socketState);

                logger.trace("Socket closed ", socketState.handle);
                socketState.unpin();
            } else {
                logger.error("Error unknown socket event ", wsaEvent, socketState.handle);
            }
        } else {
            logger.info("Socket got network event and shouldn't have (may indicate a bug) ", socketState.handle);
        }
    }
}
