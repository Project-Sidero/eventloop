module sidero.eventloop.internal.networking.posix.socketserver;
import sidero.eventloop.internal.networking.posix.mechanism;
import sidero.eventloop.internal.networking.posix.socketclient;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.sockets;
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

version (Posix) {
    import core.sys.posix.netinet.in_;
    import core.sys.posix.sys.socket;
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;
    import core.stdc.errno;
}

@safe nothrow @nogc:

alias PlatformListenSocketKey = void*;

struct PlatformListenSocket {
    version (Posix) {
        union {
            void* handle;
            int fd;
        }
    }

    shared(ptrdiff_t) isAlive;
    NetworkAddress address;

@safe nothrow @nogc:

    this(return scope ref PlatformListenSocket other) scope @trusted {
        this.tupleof = other.tupleof;
    }

    ~this() scope {
    }

    void opAssign(return scope PlatformListenSocket other) scope {
        this.destroy;
        this.__ctor(other);
    }
}

bool listenOnAddress(scope ListenSocketState* listenSocketState, bool reuseAddr, Optional!Duration keepAliveInterval) @trusted {
    if (listenSocketState.address.type == NetworkAddress.Type.Hostname) {
        auto resolved = listenSocketState.address.resolve();

        uint gotOne;

        foreach (address; resolved) {
            if (listenOnSpecificAddress(listenSocketState, address, reuseAddr, keepAliveInterval))
                gotOne++;
        }

        if (gotOne > 0) {
            listenSocketState.pin(gotOne);
            return true;
        }
    } else if (listenSocketState.address.type != NetworkAddress.Type.Invalid) {
        if (listenOnSpecificAddress(listenSocketState, listenSocketState.address, reuseAddr, keepAliveInterval)) {
            listenSocketState.pin(1);
            return true;
        }
    }

    return false;
}

void forceClose(scope PlatformListenSocket* listenSocketState) scope {
    version (Posix) {
        close(listenSocketState.fd);
    } else
        assert(0);
}

void cleanup(scope PlatformListenSocket* listenSocketState) scope {
    version (Posix) {
    } else
        assert(0);
}

private:

bool listenOnSpecificAddress(ListenSocketState* listenSocketState, NetworkAddress address, bool reuseAddr,
        Optional!Duration keepAliveInterval) @trusted {
    version (Posix) {
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

                // for pretty much all targets this is left as init
                //saPtr.sin6_addr = IN6ADDR_ANY_INIT;
                saPtr.sin6_addr = in6_addr.init;

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
            platformListenSocket.fd = socket(addressFamily, socketType, socketProtocol);

            if (platformListenSocket.fd == -1) {
                logger.notice("Error could not open socket ", address, " as ", addressFamily, " ", socketType, " ",
                        socketProtocol, " with error ", errno, " on ", Thread.self);
                return false;
            } else {
                logger.debug_("Listen socket created successfully ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        if (reuseAddr) {
            uint reuseAddrValue = reuseAddr;

            if (setsockopt(platformListenSocket.fd, SOL_SOCKET, SO_REUSEADDR, cast(uint*)&reuseAddrValue, 4) != 0) {
                logger.notice("Error could not set SO_REUSEADDR ", platformListenSocket.handle, " with error ",
                        errno, " on ", Thread.self);
                close(platformListenSocket.fd);
                return false;
            }
        }

        if (keepAliveInterval) {
            uint keepAliveEnabledValue = 1, keepAliveIntervalValue = cast(uint)keepAliveInterval.get.totalSeconds;

            if (setsockopt(platformListenSocket.fd, SOL_SOCKET, SO_KEEPALIVE, cast(uint*)&keepAliveEnabledValue, 4) != 0) {
                logger.notice("Could not set SO_KEEPALIVE ", platformListenSocket.handle, " with error ", errno, " on ", Thread.self);
                close(platformListenSocket.fd);
                return false;
            }

            version (linux) {
                import core.sys.linux.netinet.tcp : TCP_KEEPIDLE;

                if (setsockopt(platformListenSocket.fd, IPPROTO_TCP, TCP_KEEPIDLE, cast(uint*)&keepAliveIntervalValue, 4) != 0) {
                    logger.notice("Could not set TCP_KEEPIDLE ", platformListenSocket.handle, " with error ", errno, " on ", Thread.self);
                    close(platformListenSocket.fd);
                    return false;
                }
            }
        }

        {
            if (bind(platformListenSocket.fd, cast(sockaddr*)serverAddressBuffer.ptr, serverAddressSize) == -1) {
                logger.notice("Error could not bind on port ", platformListenSocket.handle, " with error ", errno, " on ", Thread.self);
                close(platformListenSocket.fd);
                return false;
            } else {
                logger.debug_("Bound on port successfully ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        {
            if (listen(platformListenSocket.fd, SOMAXCONN) == -1) {
                logger.notice("Error could not listen on port ", platformListenSocket.handle, " with error ", errno, " on ", Thread.self);
                close(platformListenSocket.fd);
                return false;
            } else {
                logger.debug_("Listening on port ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        platformListenSocket.address = address;
        atomicStore(platformListenSocket.isAlive, true);

        listenSocketState.platformSockets[platformListenSocket.handle] = platformListenSocket;
        addEventWaiterHandle(platformListenSocket.handle, &handleListenSocketEvent, listenSocketState);
        return true;
    } else
        assert(0);
}

void handleListenSocketEvent(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version (Posix) {
        import core.sys.posix.poll;

        ListenSocketState* listenSocketState = cast(ListenSocketState*)user;
        auto perSockState = listenSocketState.platformSockets[cast(PlatformListenSocketKey)handle];
        assert(perSockState);

        const revent = *cast(int*)eventResponsePtr;

        if (revent != 0) {
            if ((revent & POLLIN) == POLLIN) {
                onAccept(listenSocketState, perSockState);
            } else if ((revent & POLLNVAL) == POLLNVAL || (revent & POLLHUP) == POLLHUP) {
                logger.debug_("Listen socket closed ", perSockState.handle, " on ", Thread.self);
                listenSocketState.unpin();
            } else {
                logger.debug_("Listen socket got network event and shouldn't have (may indicate a bug) ", revent,
                        " with ", perSockState.handle, " on ", Thread.self);
            }
        }
    } else
        assert(0);
}

void onAccept(ListenSocketState* listenSocketState, ResultReference!PlatformListenSocket perSockState) @trusted {
    version (Posix) {
        import sidero.eventloop.tasks.workers : registerAsTask;
        import sidero.eventloop.internal.event_waiting;

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

        enum SockAddress4Size = sockaddr_in.sizeof;
        enum SockAddress6Size = sockaddr_in6.sizeof;
        enum SockAddressMaxSize = SockAddress6Size > SockAddress4Size ? SockAddress6Size : SockAddress4Size;

        int acceptedSocket = accept(perSockState.fd, null, null);
        NetworkAddress localAddress, remoteAddress;

        if (acceptedSocket == -1) {
            logger.error("Error could not accept socket with error ", perSockState.handle, " for ",
                    perSockState.handle, " with error ", errno, " on ", Thread.self);
            return;
        }

        {
            ubyte[SockAddressMaxSize] localBuffer, remoteBuffer;
            socklen_t localAddressSize = localBuffer.length, remoteAddressSize = remoteBuffer.length;

            sockaddr_in* localAddressPtr = cast(sockaddr_in*)localBuffer.ptr, remoteAddressPtr = cast(sockaddr_in*)remoteBuffer.ptr;

            if (getsockname(acceptedSocket, cast(sockaddr*)localBuffer.ptr, &localAddressSize) == -1) {
                logger.notice("Did not recognize a local IP address for accepted socket ", acceptedSocket, " error ",
                        errno, " for ", perSockState.handle, " on ", Thread.self);
                close(acceptedSocket);
                return;
            } else if (getpeername(acceptedSocket, cast(sockaddr*)remoteBuffer.ptr, &remoteAddressSize) == -1) {
                logger.notice("Did not recognize a remote IP address for accepted socket ", acceptedSocket, " error ",
                        errno, " for ", perSockState.handle, " on ", Thread.self);
                close(acceptedSocket);
                return;
            }

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
                logger.notice("Did not recognize an IP address for accepted socket ", acceptedSocket, " local ",
                        localAddress, " remote ", remoteAddress, " for ", perSockState.handle, " on ", Thread.self);
                close(acceptedSocket);
                return;
            } else {
                logger.debug_("Accepted socket addresses ", acceptedSocket, " local ", localAddress, " remote ",
                        remoteAddress, " for ", perSockState.handle, " on ", Thread.self);
            }
        }

        Socket acquiredSocket = Socket.fromListen(listenSocketState.protocol, localAddress, remoteAddress);
        acquiredSocket.state.fd = acceptedSocket;
        acquiredSocket.state.cameFromServer = true;

        if (!listenSocketState.fallbackCertificate.isNull) {
            if (!acquiredSocket.state.encryption.addEncryption(acquiredSocket.state, Hostname.init,
                    listenSocketState.fallbackCertificate, Closure!(Certificate, String_UTF8).init,
                    listenSocketState.encryption, listenSocketState.validateCertificates)) {
                logger.notice("Could not initialize encryption on socket ", acceptedSocket, " for ",
                        perSockState.handle, " on ", Thread.self);
                close(acceptedSocket);
                return;
            }
        }

        {
            const flags = fcntl(acquiredSocket.state.fd, F_GETFL, 0);
            fcntl(acquiredSocket.state.fd, F_SETFL, flags | O_NONBLOCK | O_CLOEXEC);
        }

        addEventWaiterHandle(acquiredSocket.state.handle, &handleSocketEvent, acquiredSocket.state);
        acquiredSocket.state.pin();

        auto acceptSocketCO = listenSocketState.onAccept.makeInstance(RCAllocator.init, acquiredSocket);
        registerAsTask(acceptSocketCO);
    } else
        assert(0);
}
