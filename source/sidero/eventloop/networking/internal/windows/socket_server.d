module sidero.eventloop.networking.internal.windows.socket_server;
import sidero.eventloop.networking.internal.windows.mechanism;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.networking.sockets;
import sidero.base.path.networking;
import sidero.base.text;
import sidero.base.errors;

@safe nothrow @nogc:

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;

    bool listenOnAddress(ListenSocketState* listenSocketState, bool reuseAddr, bool keepAlive) @trusted {
        if (listenSocketState.address.type == NetworkAddress.Type.Hostname) {
            auto resolved = listenSocketState.address.resolve();

            uint gotOne;

            foreach (address; resolved) {
                if (listenOnSpecificAddress(listenSocketState, address, reuseAddr, keepAlive))
                    gotOne++;
            }

            if (gotOne > 0) {
                listenSocketState.pin(gotOne);
                return true;
            }
        } else if (listenSocketState.address.type != NetworkAddress.Type.Invalid) {
            if (listenOnSpecificAddress(listenSocketState, listenSocketState.address, reuseAddr, keepAlive)) {
                listenSocketState.pin(1);
                return true;
            }
        }

        return false;
    }

    private bool listenOnSpecificAddress(ListenSocketState* listenSocketState, NetworkAddress address, bool reuseAddr, bool keepAlive) @trusted {
        import sidero.base.bitmanip : swapEndian;
        import core.atomic : atomicStore;
        import core.sys.windows.windows : AF_INET, AF_INET6, SOCK_STREAM, SOCK_DGRAM, INVALID_SOCKET, WSAGetLastError,
            sockaddr_in, sockaddr_in6, INADDR_ANY, IN6ADDR_ANY, bind, SOCKET_ERROR, closesocket, listen, sockaddr,
            SOL_SOCKET, SO_REUSEADDR, setsockopt, SO_KEEPALIVE, CloseHandle, GetLastError;

        enum SockAddress4Size = sockaddr_in.sizeof;
        enum SockAddress6Size = sockaddr_in6.sizeof;
        enum SockAddressMaxSize = SockAddress6Size > SockAddress4Size ? SockAddress6Size : SockAddress4Size;

        ubyte[SockAddressMaxSize] serverAddressBuffer;
        int serverAddressSize;
        short addressFamily, socketType;

        PlatformListenSocket platformListenSocket;

        {
            address.onNetworkOrder((uint value) @trusted {
                //ipv4
                addressFamily = AF_INET;
                serverAddressSize = SockAddress4Size;

                sockaddr_in* saPtr = cast(sockaddr_in*)serverAddressBuffer.ptr;
                saPtr.sin_family = AF_INET;
                saPtr.sin_addr.s_addr = value;
                saPtr.sin_port = address.networkOrderPort();
            }, (ushort[8] value) @trusted {
                // ipv6
                addressFamily = AF_INET6;
                serverAddressSize = SockAddress6Size;

                sockaddr_in6* saPtr = cast(sockaddr_in6*)serverAddressBuffer.ptr;
                saPtr.sin6_family = AF_INET6;
                saPtr.sin6_addr.s6_addr16 = value;
                saPtr.sin6_port = address.networkOrderPort();
            }, () @trusted {
                // any ipv4
                addressFamily = AF_INET;
                serverAddressSize = SockAddress4Size;

                sockaddr_in* saPtr = cast(sockaddr_in*)serverAddressBuffer.ptr;
                saPtr.sin_family = AF_INET;
                saPtr.sin_addr.s_addr = INADDR_ANY;
                saPtr.sin_port = address.networkOrderPort();
            }, () @trusted {
                // any ipv6
                addressFamily = AF_INET6;
                serverAddressSize = SockAddress6Size;

                sockaddr_in6* saPtr = cast(sockaddr_in6*)serverAddressBuffer.ptr;
                saPtr.sin6_family = AF_INET6;
                saPtr.sin6_addr = IN6ADDR_ANY;
                saPtr.sin6_port = address.networkOrderPort();
            }, (scope String_ASCII hostname) {
                assert(0); // already resolved
            }, () {
                assert(0); // what?
            });
        }

        final switch (listenSocketState.protocol) {
        case Socket.Protocol.TCP:
            socketType = SOCK_STREAM;
            break;
        case Socket.Protocol.UDP:
            socketType = SOCK_DGRAM;
            break;
        }

        {
            platformListenSocket.handle = WSASocketW(addressFamily, socketType, 0, null, 0, WSA_FLAG_OVERLAPPED);

            if (platformListenSocket.handle == INVALID_SOCKET) {
                logger.error("Error could not open socket", address, WSAGetLastError());
                return false;
            } else {
                logger.trace("Listen socket created successfully");
            }
        }

        {
            if (reuseAddr && setsockopt(platformListenSocket.handle, SOL_SOCKET, SO_REUSEADDR, cast(char*)&reuseAddr, 1) != 0) {
                logger.error("Error could not set SO_REUSEADDR", address, WSAGetLastError());
                closesocket(platformListenSocket.handle);
                return false;
            }

            if (keepAlive && setsockopt(platformListenSocket.handle, SOL_SOCKET, SO_KEEPALIVE, cast(char*)&keepAlive, 1) != 0) {
                logger.error("Error could not set SO_KEEPALIVE", address, WSAGetLastError());
                closesocket(platformListenSocket.handle);
                return false;
            }
        }

        {
            if (bind(platformListenSocket.handle, cast(sockaddr*)serverAddressBuffer.ptr, serverAddressSize) == SOCKET_ERROR) {
                logger.error("Error could not bind on port", address, WSAGetLastError());
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.trace("Bound on port successfully", address);
            }
        }

        {
            if (listen(platformListenSocket.handle, SOMAXCONN) == SOCKET_ERROR) {
                logger.error("Error could not listen on port", address, WSAGetLastError());
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.trace("Listening on port", address);
            }
        }

        {
            platformListenSocket.eventHandle = WSACreateEvent();

            if (platformListenSocket.eventHandle is WSA_INVALID_EVENT) {
                logger.error("Error occured while creating the accept/close event with code", address, GetLastError());
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.trace("WSA accept/close event created", address);
            }

            if (WSAEventSelect(platformListenSocket.handle, platformListenSocket.eventHandle, FD_ACCEPT | FD_CLOSE) == SOCKET_ERROR) {
                logger.error("Error could not associated on accept/close event with listen socket accept event", address, GetLastError());
                closesocket(platformListenSocket.handle);
                CloseHandle(platformListenSocket.eventHandle);
                return false;
            } else {
                logger.trace("Associated accept/close event with listen socket on port", address);
            }
        }

        platformListenSocket.address = address;
        atomicStore(platformListenSocket.isAlive, true);

        listenSocketState.platformSockets[platformListenSocket.eventHandle] = platformListenSocket;
        addEventWaiterHandle(platformListenSocket.eventHandle, &handleListenSocketEvent, listenSocketState);
        return true;
    }

    void handleListenSocketEvent(void* handle, void* user) @trusted {
        import core.atomic : atomicStore;
        import core.sys.windows.windows : closesocket, GetLastError, WSAENOTSOCK;

        ListenSocketState* listenSocketState = cast(ListenSocketState*)user;
        auto perSockState = listenSocketState.platformSockets[cast(PlatformListenSocketKey)handle];
        assert(perSockState);

        WSANETWORKEVENTS wsaEvent;

        if (WSAEnumNetworkEvents(perSockState.handle, perSockState.eventHandle, &wsaEvent) != 0) {
            auto error = GetLastError();

            if (error == WSAENOTSOCK) {
                // ok just in case lets just unpin it
                listenSocketState.unpin;
            } else {
                logger.error("Error could not enumerate WSA network listen socket events with code", perSockState.handle, error);
            }
        } else if ((wsaEvent.lNetworkEvents & FD_ACCEPT) == FD_ACCEPT && wsaEvent.iErrorCode[FD_ACCEPT_BIT] == 0) {
            onAccept(listenSocketState, perSockState);
        } else if ((wsaEvent.lNetworkEvents & FD_CLOSE) == FD_CLOSE && wsaEvent.iErrorCode[FD_CLOSE_BIT] == 0) {
            logger.trace("Socket closing cleanly", perSockState.handle);
            closesocket(perSockState.handle);
            listenSocketState.unpin();
        }
    }

    void onAccept(ListenSocketState* listenSocketState, ResultReference!PlatformListenSocket perSockState) @trusted {
        import sidero.eventloop.internal.windows.iocp;
        import sidero.eventloop.networking.internal.windows.socket_client;
        import sidero.base.bitmanip : bigEndianToNative, nativeToBigEndian;
        import core.sys.windows.windows : GetLastError, socket, INVALID_SOCKET, closesocket, AF_INET, AF_INET6,
            SOCK_STREAM, SOCK_DGRAM, IPPROTO_TCP, IPPROTO_UDP, sockaddr_in, sockaddr_in6, WSAGetLastError, ERROR_IO_PENDING, SOCKET_ERROR;

        assert(perSockState);
        short addressFamily, socketType, socketProtocol;

        {
            bool notRecognized;

            perSockState.address.onNetworkOrder((uint value) @trusted {
                //ipv4
                addressFamily = AF_INET;
            }, (ushort[8] value) @trusted {
                // ipv6
                addressFamily = AF_INET6;
            }, () @trusted {
                // any ipv4
                addressFamily = AF_INET;
            }, () @trusted {
                // any ipv6
                addressFamily = AF_INET6;
            }, (scope String_ASCII) {
                // hostname
                notRecognized = true;
            }, () {
                // error
                notRecognized = true;
            });

            if (notRecognized) {
                logger.error("Did not recognize network address type for accept", perSockState.address);
                return;
            }
        }

        final switch (listenSocketState.protocol) {
        case Socket.Protocol.TCP:
            socketType = SOCK_STREAM;
            socketProtocol = IPPROTO_TCP;
            break;
        case Socket.Protocol.UDP:
            socketType = SOCK_DGRAM;
            socketProtocol = IPPROTO_UDP;
            break;
        }

        SOCKET acceptedSocket = WSASocketA(addressFamily, socketType, socketProtocol, null, 0, WSA_FLAG_OVERLAPPED);

        if (acceptedSocket == INVALID_SOCKET) {
            logger.error("Error could not create accepted socket with error", perSockState.handle, WSAGetLastError());
        } else {
            enum SockAddress4Size = sockaddr_in.sizeof;
            enum SockAddress6Size = sockaddr_in6.sizeof;
            enum SockAddressMaxSize = SockAddress6Size > SockAddress4Size ? SockAddress6Size : SockAddress4Size;

            ubyte[(SockAddressMaxSize * 2) + 32] buffer;
            DWORD received;
            OVERLAPPED overlapped;

            auto result = AcceptEx(perSockState.handle, acceptedSocket, buffer.ptr, 0, SockAddressMaxSize + 16,
                    SockAddressMaxSize + 16, &received, &overlapped);

            if (result != 0 && result != ERROR_IO_PENDING) {
                logger.error("Error could not accept socket with error", perSockState.handle, WSAGetLastError());
                closesocket(acceptedSocket);
                return;
            } else {
                logger.trace("Accepted a socket", acceptedSocket, perSockState.handle);

                sockaddr_in* localAddressPtr = cast(sockaddr_in*)buffer.ptr,
                    remoteAddressPtr = cast(sockaddr_in*)&buffer[SockAddressMaxSize + 16];
                NetworkAddress localAddress, remoteAddress;

                {
                    if (localAddressPtr.sin_family == AF_INET) {
                        sockaddr_in* localAddress4 = localAddressPtr;
                        localAddress = NetworkAddress.fromIPv4(localAddress4.sin_port, localAddress4.sin_addr.s_addr, true, true);
                    } else if (localAddressPtr.sin_family == AF_INET6) {
                        sockaddr_in6* localAddress6 = cast(sockaddr_in6*)localAddressPtr;
                        localAddress = NetworkAddress.fromIPv6(localAddress6.sin6_port, localAddress6.sin6_addr.s6_addr16, true, true);
                    }

                    if (remoteAddressPtr.sin_family == AF_INET) {
                        sockaddr_in* remoteAddress4 = remoteAddressPtr;
                        remoteAddress = NetworkAddress.fromIPv4(remoteAddress4.sin_port, remoteAddress4.sin_addr.s_addr, true, true);
                    } else if (remoteAddressPtr.sin_family == AF_INET6) {
                        sockaddr_in6* remoteAddress6 = cast(sockaddr_in6*)remoteAddressPtr;
                        remoteAddress = NetworkAddress.fromIPv6(remoteAddress6.sin6_port, remoteAddress6.sin6_addr.s6_addr16, true, true);
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

                    remoteAddress.onNetworkOrder((value) {
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

                    if (notRecognized) {
                        logger.error("Did not recognize an IP address for accepted socket", localAddress,
                                remoteAddress, acceptedSocket, perSockState.handle);
                        closesocket(acceptedSocket);
                        return;
                    } else {
                        logger.trace("Accepted socket addresses", localAddress, remoteAddress, acceptedSocket, perSockState.handle);
                    }
                }

                Socket acquiredSocket = Socket.fromListen(listenSocketState.protocol, localAddress, remoteAddress);
                acquiredSocket.state.handle = acceptedSocket;
                acquiredSocket.state.onCloseEvent = WSACreateEvent();
                acquiredSocket.state.cameFromServer = true;

                if (acquiredSocket.state.onCloseEvent is WSA_INVALID_EVENT) {
                    logger.error("Error occured while creating the on close event with code", acceptedSocket,
                            perSockState.handle, GetLastError());
                    return;
                } else {
                    logger.trace("WSA on close event created", acceptedSocket, perSockState.handle);
                }

                if (WSAEventSelect(acceptedSocket, acquiredSocket.state.onCloseEvent, FD_CLOSE) == SOCKET_ERROR) {
                    logger.error("Error could not associated on close event with accepted socket", acceptedSocket,
                            perSockState.handle, GetLastError());
                    closesocket(acceptedSocket);
                    return;
                } else {
                    logger.trace("Associated on close event on accepted socket", acceptedSocket, perSockState.handle);
                }

                if (!associateWithIOCP(acquiredSocket)) {
                    closesocket(acceptedSocket);
                    return;
                } else {
                    logger.trace("Associated connection with IOCP", acceptedSocket, perSockState.handle);
                }

                if (!listenSocketState.certificate.isNull) {
                    if (!acquiredSocket.state.encryptionState.addEncryption(acquiredSocket.state,
                            listenSocketState.certificate, listenSocketState.encryption, listenSocketState.validateCertificates)) {
                        logger.error("Error could not initialize encryption on socket ", acceptedSocket, perSockState.handle);
                        closesocket(acceptedSocket);
                        return;
                    }
                }

                addEventWaiterHandle(acquiredSocket.state.onCloseEvent, &handleSocketEvent, acquiredSocket.state);
                acquiredSocket.state.pin();
                listenSocketState.onAcceptHandler(acquiredSocket);
            }
        }
    }
}
