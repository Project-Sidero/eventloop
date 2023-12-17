module sidero.eventloop.networking.internal.windows.socketserver;
import sidero.eventloop.networking.internal.windows.mechanism;
import sidero.eventloop.networking.internal.windows.socketclient;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.internal.windows.bindings;
import sidero.eventloop.threads;
import sidero.eventloop.certificates;
import sidero.eventloop.closure.callable;
import sidero.base.path.networking;
import sidero.base.path.hostname;
import sidero.base.errors;
import sidero.base.allocators;
import sidero.base.text;
import sidero.base.typecons : Optional;
import sidero.base.datetime.duration;

@safe nothrow @nogc:

alias PlatformListenSocketKey = void*;

struct PlatformListenSocket {
    version (Windows) {
        SOCKET handle;
        WSAEVENT eventHandle;
    }

    shared(ptrdiff_t) isAlive;
    NetworkAddress address;

@safe nothrow @nogc:

    this(return scope ref PlatformListenSocket other) scope {
        this.tupleof = other.tupleof;
    }
}

void forceClose(scope PlatformListenSocket* socketState) scope @trusted {
    version (Windows) {
        closesocket(socketState.handle);
    } else
        assert(0);
}

void cleanup(scope PlatformListenSocket* socketState) scope @trusted {
    version (Windows) {
        CloseHandle(socketState.eventHandle);
    } else
        assert(0);
}

bool listenOnAddress(scope ListenSocketState* listenSocketState, bool reuseAddr, Optional!Duration keepAlive) @trusted {
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

private:

bool listenOnSpecificAddress(ListenSocketState* listenSocketState, NetworkAddress address, bool reuseAddr, Optional!Duration keepAlive) @trusted {
    version (Windows) {
        import sidero.eventloop.internal.event_waiting;
        import sidero.base.internal.atomic;

        enum SockAddress4Size = sockaddr_in.sizeof;
        enum SockAddress6Size = sockaddr_in6.sizeof;
        enum SockAddressMaxSize = SockAddress6Size > SockAddress4Size ? SockAddress6Size : SockAddress4Size;

        ubyte[SockAddressMaxSize] serverAddressBuffer;
        int serverAddressSize;
        short addressFamily, socketType, socketProtocol;

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
                saPtr.sin6_addr.Word = value;
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
            }, (scope Hostname hostname) {
                assert(0); // already resolved
            }, () {
                assert(0); // what?
            });
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

        {
            platformListenSocket.handle = WSASocketW(addressFamily, socketType, socketProtocol, null, 0, WSA_FLAG_OVERLAPPED);

            if (platformListenSocket.handle == INVALID_SOCKET) {
                logger.notice("Error could not open socket ", address, " as ", addressFamily, " ", socketType, " ",
                        socketProtocol, " with error ", WSAGetLastError(), " on ", Thread.self);
                return false;
            } else {
                logger.debug_("Listen socket created successfully ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        if (reuseAddr && setsockopt(platformListenSocket.handle, SOL_SOCKET, SO_REUSEADDR, cast(char*)&reuseAddr, 1) != 0) {
            logger.notice("Error could not set SO_REUSEADDR ", platformListenSocket.handle, " with error ",
                    WSAGetLastError(), " on ", Thread.self);
            closesocket(platformListenSocket.handle);
            return false;
        }

        if (keepAlive) {
            // keepAlive is in milliseconds
            uint keepAliveValue = cast(uint)keepAlive.get.totalSeconds;

            if(setsockopt(platformListenSocket.handle, SOL_SOCKET, SO_KEEPALIVE, cast(uint*)&keepAliveValue, 4) != 0) {
                logger.notice("Could not set SO_KEEPALIVE ", platformListenSocket.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(socketState.handle);
                return ErrorResult(UnknownPlatformBehaviorException("Could not set keep alive status to socket"));
            }
        }

        {
            if (bind(platformListenSocket.handle, cast(sockaddr*)serverAddressBuffer.ptr, serverAddressSize) == SOCKET_ERROR) {
                logger.notice("Error could not bind on port ", platformListenSocket.handle, " with error ",
                        WSAGetLastError(), " on ", Thread.self);
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.debug_("Bound on port successfully ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        {
            if (listen(platformListenSocket.handle, SOMAXCONN) == SOCKET_ERROR) {
                logger.notice("Error could not listen on port ", platformListenSocket.handle, " with error ",
                        WSAGetLastError(), " on ", Thread.self);
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.debug_("Listening on port ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        {
            platformListenSocket.eventHandle = WSACreateEvent();

            if (platformListenSocket.eventHandle is WSA_INVALID_EVENT) {
                logger.notice("Error occured while creating the accept/close event ", platformListenSocket.handle,
                        " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.debug_("WSA accept/close event created ", platformListenSocket.handle, " on ", Thread.self);
            }

            if (WSAEventSelect(platformListenSocket.handle, platformListenSocket.eventHandle, FD_ACCEPT | FD_CLOSE) == SOCKET_ERROR) {
                logger.notice("Error could not associated on accept/close event with listen socket accept event ",
                        platformListenSocket.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(platformListenSocket.handle);
                CloseHandle(platformListenSocket.eventHandle);
                return false;
            } else {
                logger.debug_("Associated accept/close event with listen socket on port ", platformListenSocket.handle,
                        " on ", Thread.self);
            }
        }

        platformListenSocket.address = address;
        atomicStore(platformListenSocket.isAlive, true);

        listenSocketState.platformSockets[platformListenSocket.eventHandle] = platformListenSocket;
        addEventWaiterHandle(platformListenSocket.eventHandle, &handleListenSocketEvent, listenSocketState);
        return true;
    } else
        assert(0);
}

void handleListenSocketEvent(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version (Windows) {
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
                logger.notice("Error could not enumerate WSA network listen socket events with code ",
                        perSockState.handle, " with error ", error, " on ", Thread.self);
            }
        } else if ((wsaEvent.lNetworkEvents & FD_ACCEPT) == FD_ACCEPT && wsaEvent.iErrorCode[FD_ACCEPT_BIT] == 0) {
            onAccept(listenSocketState, perSockState);
        } else if ((wsaEvent.lNetworkEvents & FD_CLOSE) == FD_CLOSE && wsaEvent.iErrorCode[FD_CLOSE_BIT] == 0) {
            logger.debug_("Socket closing cleanly ", perSockState.handle, " on ", Thread.self);
            closesocket(perSockState.handle);
            listenSocketState.unpin();
        }
    } else
        assert(0);
}

void onAccept(ListenSocketState* listenSocketState, ResultReference!PlatformListenSocket perSockState) @trusted {
    import sidero.eventloop.networking.internal.windows.socketclient;
    import sidero.eventloop.tasks.workers : registerAsTask;
    import sidero.eventloop.internal.windows.iocp;
    import sidero.eventloop.internal.event_waiting;
    import sidero.base.bitmanip : bigEndianToNative, nativeToBigEndian;

    version (Windows) {
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
                logger.error("Did not recognize network address type for accept ", perSockState.address, " for ",
                        perSockState.handle, " on ", Thread.self);
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
            logger.error("Error could not create accepted socket with error ", perSockState.handle, " for ",
                    perSockState.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
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
                logger.notice("Error could not accept socket with error ", perSockState.handle, " for ",
                        perSockState.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(acceptedSocket);
                return;
            } else {
                logger.debug_("Accepted a socket ", acceptedSocket, " for ", perSockState.handle, " on ", Thread.self);

                sockaddr_in* localAddressPtr = cast(sockaddr_in*)buffer.ptr,
                    remoteAddressPtr = cast(sockaddr_in*)&buffer[SockAddressMaxSize + 16];
                NetworkAddress localAddress, remoteAddress;

                {
                    if (localAddressPtr.sin_family == AF_INET) {
                        sockaddr_in* localAddress4 = localAddressPtr;
                        localAddress = NetworkAddress.fromIPv4(localAddress4.sin_port, localAddress4.sin_addr.s_addr, true, true);
                    } else if (localAddressPtr.sin_family == AF_INET6) {
                        sockaddr_in6* localAddress6 = cast(sockaddr_in6*)localAddressPtr;
                        localAddress = NetworkAddress.fromIPv6(localAddress6.sin6_port, localAddress6.sin6_addr.Word, true, true);
                    }

                    if (remoteAddressPtr.sin_family == AF_INET) {
                        sockaddr_in* remoteAddress4 = remoteAddressPtr;
                        remoteAddress = NetworkAddress.fromIPv4(remoteAddress4.sin_port, remoteAddress4.sin_addr.s_addr, true, true);
                    } else if (remoteAddressPtr.sin_family == AF_INET6) {
                        sockaddr_in6* remoteAddress6 = cast(sockaddr_in6*)remoteAddressPtr;
                        remoteAddress = NetworkAddress.fromIPv6(remoteAddress6.sin6_port, remoteAddress6.sin6_addr.Word, true, true);
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
                        logger.notice("Did not recognize an IP address for accepted socket ", acceptedSocket, " local ",
                                localAddress, " remote ", remoteAddress, " for ", perSockState.handle, " on ", Thread.self);
                        closesocket(acceptedSocket);
                        return;
                    } else {
                        logger.debug_("Accepted socket addresses ", acceptedSocket, " local ", localAddress,
                                " remote ", remoteAddress, " for ", perSockState.handle, " on ", Thread.self);
                    }
                }

                Socket acquiredSocket = Socket.fromListen(listenSocketState.protocol, localAddress, remoteAddress);
                acquiredSocket.state.handle = acceptedSocket;
                acquiredSocket.state.onCloseEvent = WSACreateEvent();
                acquiredSocket.state.cameFromServer = true;

                if (acquiredSocket.state.onCloseEvent is WSA_INVALID_EVENT) {
                    logger.notice("Error occured while creating the on close event with code ", acceptedSocket,
                            " for ", perSockState.handle, " with error ", GetLastError(), " on ", Thread.self);
                    return;
                } else {
                    logger.debug_("WSA on close event created ", acceptedSocket, " on ", Thread.self);
                }

                if (WSAEventSelect(acceptedSocket, acquiredSocket.state.onCloseEvent, FD_CLOSE) == SOCKET_ERROR) {
                    logger.notice("Could not associated on close event with accepted socket ", acceptedSocket, " for ",
                            perSockState.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                    closesocket(acceptedSocket);
                    return;
                } else {
                    logger.debug_("Associated on close event on accepted socket ", acceptedSocket, " on ", Thread.self);
                }

                if (!associateWithIOCP(acquiredSocket)) {
                    closesocket(acceptedSocket);
                    return;
                } else {
                    logger.debug_("Associated connection with IOCP ", acceptedSocket, " on ", Thread.self);
                }

                if (!listenSocketState.fallbackCertificate.isNull) {
                    if (!acquiredSocket.state.encryption.addEncryption(acquiredSocket.state, Hostname.init,
                            listenSocketState.fallbackCertificate, Closure!(Certificate, String_UTF8).init,
                            listenSocketState.encryption, listenSocketState.validateCertificates)) {
                        logger.notice("Could not initialize encryption on socket ", acceptedSocket, " for ",
                                perSockState.handle, " on ", Thread.self);
                        closesocket(acceptedSocket);
                        return;
                    }
                }

                addEventWaiterHandle(acquiredSocket.state.onCloseEvent, &handleSocketEvent, acquiredSocket.state);
                acquiredSocket.state.pin();

                auto acceptSocketCO = listenSocketState.onAccept.makeInstance(RCAllocator.init, acquiredSocket);
                registerAsTask(acceptSocketCO);
            }
        }
    } else
        assert(0);
}
