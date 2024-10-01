module sidero.eventloop.internal.networking.windows.socketserver;
import sidero.eventloop.internal.networking.windows.mechanism;
import sidero.eventloop.internal.networking.windows.socket;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.internal.workers.kernelwait.windows;
import sidero.eventloop.internal.windows.bindings;
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
import sidero.base.datetime.stopwatch;
import sidero.base.synchronization.system.lock;
import sidero.base.containers.map.hashmap;

@safe nothrow @nogc:

alias PlatformListenSocketKey = SOCKET;

struct PlatformListenSocket {
    version(Windows) {
        SOCKET handle;
        IOCPwork iocpWork;
    }

    shared(bool) isAlive;
    shared(ptrdiff_t) numberOfAccepts;
    NetworkAddress address;

    StopWatch timeSinceLastInitiatedAcceptStandOff, timeSinceLastInitiatedAccept;
    shared(size_t) lastInitiatedAcceptCount;
    size_t lastInitiatedAcceptStandOff;

    SystemLock mutextToProtectAccepts;

    HashMap!(OVERLAPPED*, Socket) overlappedToBeAcceptSockets;

@safe nothrow @nogc:

    this(return scope ref PlatformListenSocket other) scope {
        this.tupleof = other.tupleof;
    }

    ~this() scope {
    }

    void opAssign(return scope PlatformListenSocket other) scope {
        this.destroy;
        this.__ctor(other);
    }
}

void uponSocketAccept(Socket socket) @trusted {
    version(Windows) {
        import sidero.eventloop.control : registerAsTask;
        import sidero.base.internal.atomic;
        import core.stdc.math : hypotf, cbrtf;

        logger.debug_("Received accept for socket ", socket.state.handle, " on ", Thread.self);
        assert(socket.state.listenSocketPair.perSocket);

        {
            ListenSocketPair listenSocketPair = socket.state.listenSocketPair;
            assert(listenSocketPair.perSocket);

            const currentMax = atomicLoad(listenSocketPair.perSocket.lastInitiatedAcceptCount);
            const currentCount = atomicDecrementAndLoad(listenSocketPair.perSocket.numberOfAccepts, 1);

            if(currentCount <= currentMax / 2) {
                if(listenSocketPair.perSocket.mutextToProtectAccepts.tryLock) {
                    // A lot of what we do here is actually "magic".
                    // The numbers here were picked to try and prevent both denial of service attacks taking a foot hold.
                    // By having both a stand off attempts and stand off in seconds,
                    //  we can guarantee we will only attempt to have accepts that we can actually handle.

                    // This number provides us the ability to know
                    const nextStandOffAmount = cast(size_t)hypotf(currentMax, currentMax).cbrtf;

                    if(currentMax < 5_000 && listenSocketPair.perSocket.timeSinceLastInitiatedAcceptStandOff.peek < 1.seconds) {
                        listenSocketPair.perSocket.lastInitiatedAcceptStandOff++;

                        if(listenSocketPair.perSocket.lastInitiatedAcceptStandOff > nextStandOffAmount) {
                            // Ok the number posts has occured, but also has the right number of seconds occured also?

                            if(listenSocketPair.perSocket.timeSinceLastInitiatedAccept.peek >= nextStandOffAmount.seconds) {
                                // ok bump it to next value

                                // This formula will take around 6 hours to boot up all the way to 5_000 accepts
                                // However it is fine if it doesn't, it'll accept more immediately.
                                float diff = cbrtf(5000 - (5000 / currentMax)) * ((nextStandOffAmount + currentMax.cbrtf));
                                // Multiplying the formula by 3, because quite frankly it's far too slow if it takes 6 hours to start up.
                                atomicStore(listenSocketPair.perSocket.lastInitiatedAcceptCount, (currentMax + cast(size_t)diff) * 3);

                                listenSocketPair.perSocket.lastInitiatedAcceptStandOff = 0;
                                listenSocketPair.perSocket.timeSinceLastInitiatedAccept.start;
                            }
                        }
                    } else {
                        listenSocketPair.perSocket.lastInitiatedAcceptStandOff = 0;
                    }

                    listenSocketPair.perSocket.timeSinceLastInitiatedAcceptStandOff.start;

                    postAccept(listenSocketPair, atomicLoad(listenSocketPair.perSocket.lastInitiatedAcceptCount));
                    listenSocketPair.perSocket.mutextToProtectAccepts.unlock;
                }
            } else if(currentCount < 2 || currentCount <= currentMax / 8) {
                listenSocketPair.perSocket.mutextToProtectAccepts.lock.assumeOkay;
                postAccept(listenSocketPair, currentMax);
                listenSocketPair.perSocket.mutextToProtectAccepts.unlock;
            }
        }

        auto result = setsockopt(socket.state.handle, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT,
                &socket.state.listenSocketPair.perSocket.handle, SOCKET.sizeof);

        if(result == SOCKET_ERROR) {
            logger.debug_("Failed to configure accepted socket for listen socket with error ", WSAGetLastError(), " for ",
                    socket.state.handle, " for listen ", socket.state.listenSocketPair.perSocket.handle, " on ", Thread.self);
            socket.state.unpinGuarded;
            return;
        }

        {
            ubyte[SockAddressMaxSize] addressBuffer;
            sockaddr_in* addressPtr = cast(sockaddr_in*)addressBuffer.ptr;

            int addressSize = SockAddressMaxSize;
            bool haveError;

            NetworkAddress handle(int result) {
                if(result != 0) {
                    logger.debug_("Error could not acquire network address for socket client ", socket.state.handle,
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
                            address, " for ", socket.state.handle, " on ", Thread.self);
                    haveError = true;
                    return NetworkAddress.init;
                } else
                    return address;
            }

            addressSize = SockAddressMaxSize;
            socket.state.localAddress = handle(getsockname(socket.state.handle, cast(sockaddr*)addressBuffer.ptr, &addressSize));
            addressSize = SockAddressMaxSize;
            socket.state.remoteAddress = handle(getpeername(socket.state.handle, cast(sockaddr*)addressBuffer.ptr, &addressSize));

            if(haveError) {
                socket.state.unpinGuarded;
                return;
            }
        }

        auto acceptSocketCO = socket.state.listenSocketPair.listenSocket.state.onAccept.makeInstance(RCAllocator.init, socket);
        registerAsTask(acceptSocketCO);

        socket.state.initiateAConstantlyRunningReadRequest(socket.state);
    }
}

bool listenOnAddress(scope ListenSocketState* listenSocketState, bool reuseAddr, Optional!Duration keepAlive) {
    if(listenSocketState.address.type == NetworkAddress.Type.Hostname) {
        auto resolved = listenSocketState.address.resolve();

        uint gotOne;

        foreach(address; resolved) {
            if(listenOnSpecificAddress(listenSocketState, address, reuseAddr, keepAlive))
                gotOne++;
        }

        if(gotOne > 0)
            return true;
    } else if(listenSocketState.address.type != NetworkAddress.Type.Invalid) {
        if(listenOnSpecificAddress(listenSocketState, listenSocketState.address, reuseAddr, keepAlive))
            return true;
    }

    return false;
}

void forceClose(scope PlatformListenSocket* perSocketState) scope @trusted {
    version(Windows) {
        import sidero.base.internal.atomic;
        import core.sys.windows.winsock2 : closesocket;

        if(cas(perSocketState.isAlive, true, false)) {
            logger.debug_("Forcing closed listen socket ", perSocketState.handle);

            closesocket(perSocketState.handle);

            perSocketState.mutextToProtectAccepts.lock.assumeOkay;
            perSocketState.overlappedToBeAcceptSockets = typeof(perSocketState.overlappedToBeAcceptSockets).init;
            perSocketState.mutextToProtectAccepts.unlock;
        }
    } else
        assert(0);
}

void cleanup(scope PlatformListenSocket* listenSocketState) scope {
}

private:

bool listenOnSpecificAddress(scope ListenSocketState* listenSocketState, NetworkAddress address, bool reuseAddr,
        Optional!Duration keepAliveInterval) @trusted {
    version(Windows) {
        import sidero.eventloop.internal.event_waiting;
        import sidero.base.internal.atomic;
        import sidero.base.system : operatingSystem, OperatingSystem;

        enum SockAddress4Size = sockaddr_in.sizeof;
        enum SockAddress6Size = sockaddr_in6.sizeof;
        enum SockAddressMaxSize = SockAddress6Size > SockAddress4Size ? SockAddress6Size : SockAddress4Size;

        ubyte[SockAddressMaxSize] serverAddressBuffer;
        int serverAddressSize;
        short addressFamily, socketType, socketProtocol;

        PlatformListenSocket platformListenSocket;
        platformListenSocket.address = address;

        if(!extractSocketAddressInformation(address, listenSocketState.protocol, true, addressFamily, socketType,
                socketProtocol, serverAddressBuffer, serverAddressSize))
            return false;

        {
            platformListenSocket.handle = WSASocketW(addressFamily, socketType, socketProtocol, null, 0, WSA_FLAG_OVERLAPPED);

            if(platformListenSocket.handle == INVALID_SOCKET) {
                logger.notice("Error could not open socket ", address, " as ", addressFamily, " ", socketType, " ",
                        socketProtocol, " with error ", WSAGetLastError(), " on ", Thread.self);
                return false;
            } else {
                logger.debug_("Listen socket created successfully ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        // This allows port to be sharable between processes & load balanced https://stackoverflow.com/a/14388707
        if(reuseAddr && setsockopt(platformListenSocket.handle, SOL_SOCKET, SO_REUSEADDR, cast(char*)&reuseAddr, 1) != 0) {
            logger.notice("Error could not set SO_REUSEADDR ", platformListenSocket.handle, " with error ",
                    WSAGetLastError(), " on ", Thread.self);
            closesocket(platformListenSocket.handle);
            return false;
        }

        if(keepAliveInterval) {
            // keepAlive is in milliseconds
            uint keepAliveEnabledValue = 1, keepAliveIntervalValue = cast(uint)keepAliveInterval.get.totalSeconds;

            if(setsockopt(platformListenSocket.handle, SOL_SOCKET, SO_KEEPALIVE, cast(uint*)&keepAliveEnabledValue, 4) != 0) {
                logger.notice("Could not set SO_KEEPALIVE ", platformListenSocket.handle, " with error ",
                        WSAGetLastError(), " on ", Thread.self);
                closesocket(platformListenSocket.handle);
                return false;
            }

            // added in Windows 10 1709
            OperatingSystem os = operatingSystem();

            if(os.major >= 10) {
                // due to forced updates its safe to go anything less its disabled upon.

                if(setsockopt(platformListenSocket.handle, SOL_SOCKET, TCP_KEEPIDLE, cast(uint*)&keepAliveIntervalValue, 4) != 0) {
                    logger.notice("Could not set SO_KEEPALIVE ", platformListenSocket.handle, " with error ",
                            WSAGetLastError(), " on ", Thread.self);
                    closesocket(platformListenSocket.handle);
                    return false;
                }
            }
        }

        {
            if(bind(platformListenSocket.handle, cast(sockaddr*)serverAddressBuffer.ptr, serverAddressSize) == SOCKET_ERROR) {
                logger.notice("Error could not bind on port ", address.port, " for ", platformListenSocket.handle,
                        " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.debug_("Bound on port successfully ", address.port, " for ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        {
            if(listen(platformListenSocket.handle, SOMAXCONN) == SOCKET_ERROR) {
                logger.notice("Error could not listen on port ", address.port, " for ", platformListenSocket.handle,
                        " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.debug_("Listening on port ", address.port, " for ", platformListenSocket.handle, " on ", Thread.self);
            }
        }

        listenSocketState.pin(1);
        atomicStore(platformListenSocket.isAlive, true);

        listenSocketState.platformSockets[platformListenSocket.handle] = platformListenSocket;

        ListenSocket listenSocket;
        listenSocket.state = listenSocketState;
        listenSocket.state.rc(true);

        auto perSockState = listenSocket.state.platformSockets[platformListenSocket.handle];
        assert(perSockState);

        // start up the state needed for accept stand off
        perSockState.timeSinceLastInitiatedAcceptStandOff.start;
        perSockState.timeSinceLastInitiatedAccept.start;
        atomicStore(perSockState.lastInitiatedAcceptCount, 3);

        ListenSocketPair pair = ListenSocketPair(listenSocket, perSockState);
        associateWithIOCP(pair);

        perSockState.mutextToProtectAccepts.lock.assumeOkay;
        scope(exit)
            perSockState.mutextToProtectAccepts.unlock;

        // post away the initial accepts
        postAccept(pair, 3);

        return true;
    } else
        assert(0);
}

// needs guarding
void postAccept(ListenSocketPair listenSocketPair, size_t numberOfAccepts) @trusted {
    import sidero.eventloop.internal.networking.windows.socketclient;
    import sidero.eventloop.internal.workers.kernelwait.windows;
    import sidero.eventloop.internal.event_waiting;
    import sidero.base.bitmanip : bigEndianToNative, nativeToBigEndian;
    import sidero.eventloop.control : registerAsTask;
    import sidero.base.internal.atomic;

    assert(listenSocketPair.perSocket);
    logger.debug_("Posting ", numberOfAccepts, " accepts for listen socket ", listenSocketPair.perSocket.handle,
            " is null? ", listenSocketPair.listenSocket.isNull(), " is alive? ",
            listenSocketPair.listenSocket.isAlive(), " on ", Thread.self);

    foreach(_; 0 .. numberOfAccepts) {
        if(!listenSocketPair.listenSocket.isAlive())
            return;

        version(Windows) {
            ubyte[SockAddressMaxSize] serverAddressBuffer;
            int serverAddressSize;
            short addressFamily, socketType, socketProtocol;

            if(!extractSocketAddressInformation(listenSocketPair.perSocket.address, listenSocketPair.listenSocket.state.protocol,
                    true, addressFamily, socketType, socketProtocol, serverAddressBuffer, serverAddressSize))
                return;

            SOCKET acceptedSocket = WSASocketA(addressFamily, socketType, socketProtocol, null, 0, WSA_FLAG_OVERLAPPED);

            if(acceptedSocket == INVALID_SOCKET) {
                logger.error("Error could not create accepted socket with error ", listenSocketPair.perSocket.handle,
                        " for ", listenSocketPair.perSocket.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                return;
            }

            // we'll setup the local/remote addresses later
            Socket acquiredSocket = Socket.fromListen(listenSocketPair, NetworkAddress.init, NetworkAddress.init);
            acquiredSocket.state.handle = acceptedSocket;

            DWORD received;
            auto result = AcceptEx(listenSocketPair.perSocket.handle, acceptedSocket,
                    acquiredSocket.state.addressBuffer.ptr, 0, sockaddr_in.sizeof + 16, sockaddr_in.sizeof + 16,
                    &received, &acquiredSocket.state.acceptOverlapped);

            if(result == 0) {
                auto error = WSAGetLastError();

                switch(error) {
                case ERROR_IO_PENDING:
                    logger.debug_("Socket is delayed for acceptance ", acquiredSocket.state.handle,
                            " for listen socket ", listenSocketPair.perSocket.handle, " on ", Thread.self);

                    acquiredSocket.state.isDelayedAccept = true;
                    acquiredSocket.state.pinExtra;
                    break;

                default:
                    logger.notice("Error could not accept socket ", acquiredSocket.state.handle, " for ",
                            listenSocketPair.perSocket.handle, " with error ", error, " on ", Thread.self);
                    closesocket(acceptedSocket);
                    return;
                }
            }

            logger.debug_("Accepted a socket ", acceptedSocket, " for ", listenSocketPair.perSocket.handle, " on ", Thread.self);

            if(!associateWithIOCP(acquiredSocket)) {
                closesocket(acceptedSocket);
                return;
            } else {
                logger.debug_("Associated connection with IOCP ", acceptedSocket, " on ", Thread.self);
            }

            if(!listenSocketPair.listenSocket.state.fallbackCertificate.isNull) {
                if(!acquiredSocket.state.encryption.addEncryption(acquiredSocket.state, Hostname.init,
                        listenSocketPair.listenSocket.state.fallbackCertificate, Closure!(Certificate, String_UTF8).init,
                        listenSocketPair.listenSocket.state.encryption, listenSocketPair.listenSocket.state.validateCertificates)) {
                    logger.notice("Could not initialize encryption on socket ", acceptedSocket, " for ",
                            listenSocketPair.perSocket.handle, " on ", Thread.self);
                    closesocket(acceptedSocket);
                    return;
                }
            }

            acquiredSocket.state.pin();

            if(acquiredSocket.state.isDelayedAccept) {
                atomicIncrementAndLoad(listenSocketPair.perSocket.numberOfAccepts, 1);
                listenSocketPair.perSocket.overlappedToBeAcceptSockets[&acquiredSocket.state.acceptOverlapped] = acquiredSocket;
            } else {
                acquiredSocket.state.initiateAConstantlyRunningReadRequest(acquiredSocket.state);

                auto acceptSocketCO = listenSocketPair.listenSocket.state.onAccept.makeInstance(RCAllocator.init, acquiredSocket);
                registerAsTask(acceptSocketCO);
            }
        } else
            assert(0);
    }
}
