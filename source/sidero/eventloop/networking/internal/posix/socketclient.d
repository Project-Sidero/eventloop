module sidero.eventloop.networking.internal.posix.socketclient;
import sidero.eventloop.networking.internal.posix.mechanism;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.threads;
import sidero.base.errors;
import sidero.base.path.networking;
import sidero.base.path.hostname;

@safe nothrow @nogc:

version (Posix) {
    import core.sys.posix.netinet.in_;
    import core.sys.posix.sys.socket;
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;
    import core.stdc.errno;
}

struct PlatformSocket {
    union {
        void* handle; // is a file descriptor and can be passed to addEventWaiterHandle directly
        int fd;
    }

    shared(bool) isClosed;
    bool isWaitingForRetrigger;

@safe nothrow @nogc:

    // NOTE: needs to be guarded
    private bool needToBeRetriggered(scope SocketState* socketState) scope @trusted {
        if (isWaitingForRetrigger)
            return false;

        Socket socket;
        socket.state = socketState;
        socket.state.rc(true);

        isWaitingForRetrigger = true;
        addSocketToRetrigger(socket);
        return true;
    }

    // NOTE: must not be guarded
    package(sidero.eventloop.networking.internal.posix) {
        void haveBeenRetriggered(scope SocketState* socketState) scope {
            isWaitingForRetrigger = false;

            socketState.guard(&socketState.performReadWrite);
        }
    }
}

ErrorResult connectToSpecificAddress(Socket socket, NetworkAddress address, bool keepAlive) @trusted {
    version (Posix) {
        SocketState* socketState = socket.state;

        enum SockAddress4Size = sockaddr_in.sizeof;
        enum SockAddress6Size = sockaddr_in6.sizeof;
        enum SockAddressMaxSize = SockAddress6Size > SockAddress4Size ? SockAddress6Size : SockAddress4Size;

        ubyte[SockAddressMaxSize] localAddressBuffer, remoteAddressBuffer;
        uint localAddressSize = SockAddressMaxSize, remoteAddressSize;
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
                saPtr.sin6_addr.s6_addr16 = value;
                saPtr.sin6_port = address.networkOrderPort();
                validAddress = true;
            }, () @trusted {
                // any ipv4
            }, () @trusted {
                // any ipv6
            }, (scope Hostname hostname) {
                // needs to be have been already resolved
            }, () {});

            if (!validAddress)
                return ErrorResult(MalformedInputException("Not a valid network address, must be resolved ip/port"));
        }

        final switch (socketState.protocol) {
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
            socketState.fd = .socket(addressFamily, socketType, socketProtocol);

            if (socketState.fd == -1) {
                logger.notice("Could not open socket ", address, " with error ", errno, " on ", Thread.self);
                return ErrorResult(UnknownPlatformBehaviorException("Could not create socket"));
            } else {
                logger.debug_("Socket created successfully ", socketState.handle, " at ", address, " on ", Thread.self);
            }
        }

        {
            if (keepAlive && setsockopt(socketState.fd, SOL_SOCKET, SO_KEEPALIVE, cast(char*)&keepAlive, 1) != 0) {
                logger.notice("Could not set SO_KEEPALIVE ", socketState.handle, " with error ", errno, " on ", Thread.self);
                close(socketState.fd);
                return ErrorResult(UnknownPlatformBehaviorException("Could not set keep alive status to socket"));
            }
        }

        {
            if (connect(socketState.fd, cast(sockaddr*)remoteAddressBuffer.ptr, remoteAddressSize) == -1) {
                logger.notice("Could not connect to address on port ", socketState.handle, " with error ", errno, " on ", Thread.self);
                close(socketState.fd);
                return ErrorResult(UnknownPlatformBehaviorException("Could not connect socket to address"));
            } else {
                logger.debug_("Connected to port successfully ", socketState.handle, " on ", Thread.self);
            }
        }

        {
            NetworkAddress localAddress;
            sockaddr_in* localAddressPtr = cast(sockaddr_in*)localAddressBuffer.ptr;

            if (getsockname(socketState.fd, cast(sockaddr*)localAddressBuffer.ptr, &localAddressSize) != 0) {
                logger.notice("Error could not acquire local network address for socket client ", socketState.handle,
                        " with error ", errno, " on ", Thread.self);
                close(socketState.fd);
                return ErrorResult(UnknownPlatformBehaviorException("Could not associate on close event for socket"));
            }

            if (localAddressPtr.sin_family == AF_INET) {
                sockaddr_in* localAddress4 = localAddressPtr;
                localAddress = NetworkAddress.fromIPv4(localAddress4.sin_port, localAddress4.sin_addr.s_addr, true, true);
            } else if (localAddressPtr.sin_family == AF_INET6) {
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

            if (notRecognized) {
                logger.notice("Did not recognize an IP address for socket client local ", localAddress, " remote ",
                        address, " for ", socketState.handle, " on ", Thread.self);
                close(socketState.fd);
                return ErrorResult(UnknownPlatformBehaviorException("Could not acquire local address for client socket"));
            } else {
                logger.debug_("Connected socket addresses local ", localAddress, " remote ", address, " for ",
                        socketState.handle, " on ", Thread.self);
            }

            socketState.localAddress = localAddress;
            socketState.remoteAddress = address;
        }

        {
            const flags = fcntl(socketState.fd, F_GETFL, 0);
            fcntl(socketState.fd, F_SETFL, flags | O_NONBLOCK | O_CLOEXEC);
        }

        addEventWaiterHandle(socketState.handle, &handleSocketEvent, socketState);
        socketState.pin();
        return ErrorResult.init;
    } else
        assert(0);
}

void shutdown(scope SocketState* socketState, bool haveReferences = true) @trusted {
    version (Posix) {
        import sidero.base.internal.atomic;
        import core.sys.posix.sys.socket : shutdown;

        if (cas(socketState.isShutdown, false, true)) {
            logger.notice("Shutting down socket ", socketState.handle, " on ", Thread.self);
            socketState.performReadWrite();
            shutdown(socketState.fd, SHUT_WR);

            socketState.reading.cleanup();
            socketState.performReadWrite();
        }
    } else
        assert(0);
}

void forceClose(scope SocketState* socketState) @trusted {
    version (Posix) {
        import sidero.base.internal.atomic;

        if (cas(socketState.isClosed, false, true)) {
            logger.debug_("Forcing closed socket ", socketState.handle);
            close(socketState.fd);
        }
    } else
        assert(0);
}

bool tryWriteMechanism(scope SocketState* socketState, ubyte[] buffer) @trusted {
    version (Posix) {
        const err = send(socketState.fd, buffer.ptr, buffer.length, 0);

        if (err >= 0) {
            logger.debug_("Immediate completion of write ", socketState.handle, " on ", Thread.self);
            socketState.rawWriting.complete(socketState, err);
            return true;
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                logger.debug_("Writing failed as it would block, try again later for ", socketState.handle, " on ", Thread.self);
                return socketState.needToBeRetriggered(socketState);
            } else {
                logger.info("Failed to write initiate closing ", errno, " for ", socketState.handle, " on ", Thread.self);
                socketState.unpinGuarded;
                return false;
            }
        }
    } else
        assert(0);
}

bool tryReadMechanism(scope SocketState* socketState, ubyte[] buffer) @trusted {
    version (Posix) {
        const err = recv(socketState.fd, buffer.ptr, buffer.length, 0);

        if (err == 0) {
            logger.info("Failed to read initiate closing for ", socketState.handle, " on ", Thread.self);
            socketState.unpin;
            return false;
        } else if (err > 0) {
            logger.debug_("Immediate completion of read ", socketState.handle, " on ", Thread.self);
            socketState.rawReading.complete(socketState, err);
            return true;
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                logger.debug_("Reading failed as it would block, try again later for ", socketState.handle, " on ", Thread.self);
                return socketState.needToBeRetriggered(socketState);
            } else {
                logger.info("Failed to read initiate closing ", errno, " for ", socketState.handle, " on ", Thread.self);
                socketState.unpin;
                return false;
            }
        }
    } else
        assert(0);
}

void handleSocketEvent(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version (Posix) {
        import core.sys.posix.poll;

        SocketState* socketState = cast(SocketState*)user;
        const revent = *cast(int*)eventResponsePtr;

        if (revent != 0) {
            if ((revent & POLLIN) == POLLIN || (revent & POLLOUT) == POLLOUT) {
                // all ok nothing to do here
            } else if ((revent & POLLNVAL) == POLLNVAL || (revent & POLLHUP) == POLLHUP) {
                logger.debug_("Socket closed ", socketState.handle, " on ", Thread.self);
                socketState.unpin();
            } else {
                logger.debug_("Socket got network event and shouldn't have (may indicate a bug) ", revent, " with ",
                        socketState.handle, " on ", Thread.self);
            }
        }
    } else
        assert(0);
}
