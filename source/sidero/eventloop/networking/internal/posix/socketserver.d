module sidero.eventloop.networking.internal.posix.socketserver;
import sidero.eventloop.networking.internal.posix.mechanism;
import sidero.eventloop.networking.internal.posix.socketclient;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.threads;
import sidero.eventloop.certificates;
import sidero.eventloop.closure.callable;
import sidero.base.path.networking;
import sidero.base.path.hostname;
import sidero.base.errors;
import sidero.base.allocators;
import sidero.base.text;

version(Posix) {
    import core.sys.posix.netinet.in_;
    import core.sys.posix.sys.socket;
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;
    import core.stdc.errno;
}

@safe nothrow @nogc:

alias PlatformListenSocketKey = void*;

struct PlatformListenSocket {
    version(Posix) {
        union {
            void* handle;
            int fd;
        }
    }

    shared(ptrdiff_t) isAlive;
    NetworkAddress address;

@safe nothrow @nogc:

    this(return scope ref PlatformListenSocket other) scope {
        this.tupleof = other.tupleof;
    }
}

bool listenOnAddress(scope ListenSocketState* listenSocketState, bool reuseAddr, bool keepAlive) @trusted {
    if(listenSocketState.address.type == NetworkAddress.Type.Hostname) {
        auto resolved = listenSocketState.address.resolve();

        uint gotOne;

        foreach(address; resolved) {
            if(listenOnSpecificAddress(listenSocketState, address, reuseAddr, keepAlive))
                gotOne++;
        }

        if(gotOne > 0) {
            listenSocketState.pin(gotOne);
            return true;
        }
    } else if(listenSocketState.address.type != NetworkAddress.Type.Invalid) {
        if(listenOnSpecificAddress(listenSocketState, listenSocketState.address, reuseAddr, keepAlive)) {
            listenSocketState.pin(1);
            return true;
        }
    }

    return false;
}

void forceClose(scope PlatformListenSocket* listenSocketState) scope {
    version(Posix) {
        close(listenSocketState.fd);
    } else
        assert(0);
}

void cleanup(scope PlatformListenSocket* listenSocketState) scope {
    version(Posix) {
    } else
        assert(0);
}

private:

bool listenOnSpecificAddress(ListenSocketState* listenSocketState, NetworkAddress address, bool reuseAddr, bool keepAlive) @trusted {
    version(Posix) {
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

        final switch(listenSocketState.protocol) {
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

            if(platformListenSocket.fd == -1) {
                logger.notice("Error could not open socket ", address, " as ", addressFamily, " ", socketType, " ",
                        socketProtocol, " with error ", errno, " on ", Thread.self);
                return false;
            } else {
                logger.debug_("Listen socket created successfully ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        {
            if(reuseAddr && setsockopt(platformListenSocket.fd, SOL_SOCKET, SO_REUSEADDR, cast(char*)&reuseAddr, 1) != 0) {
                logger.notice("Error could not set SO_REUSEADDR ", platformListenSocket.handle, " with error ",
                        errno, " on ", Thread.self);
                close(platformListenSocket.fd);
                return false;
            }

            if(keepAlive && setsockopt(platformListenSocket.fd, SOL_SOCKET, SO_KEEPALIVE, cast(char*)&keepAlive, 1) != 0) {
                logger.debug_("Error could not set SO_KEEPALIVE ", platformListenSocket.handle, " with error ",
                        errno, " on ", Thread.self);
                close(platformListenSocket.fd);
                return false;
            }
        }

        {
            if(bind(platformListenSocket.fd, cast(sockaddr*)serverAddressBuffer.ptr, serverAddressSize) == -1) {
                logger.notice("Error could not bind on port ", platformListenSocket.handle, " with error ", errno, " on ", Thread.self);
                close(platformListenSocket.fd);
                return false;
            } else {
                logger.debug_("Bound on port successfully ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        {
            if(listen(platformListenSocket.fd, SOMAXCONN) == -1) {
                logger.notice("Error could not listen on port ", platformListenSocket.handle, " with error ", errno, " on ", Thread.self);
                closesocket(platformListenSocket.handle);
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
