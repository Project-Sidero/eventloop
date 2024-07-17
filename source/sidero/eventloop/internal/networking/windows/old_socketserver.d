module sidero.eventloop.internal.networking.windows.old_socketserver;
import sidero.eventloop.internal.networking.windows.mechanism;
import sidero.eventloop.internal.networking.windows.old_socketclient;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.sockets;
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
import sidero.base.datetime.stopwatch;
import sidero.base.synchronization.mutualexclusion;
__EOF__

@safe nothrow @nogc:

alias PlatformListenSocketKey = void*;

//enum CanAcceptLater = true;
enum CanAcceptLater = false;

struct PlatformListenSocket {
    version(Windows) {
        SOCKET handle;
        WSAEVENT eventHandle;
    }

    shared(bool) isAlive;
    shared(ptrdiff_t) numberOfAccepts;
    NetworkAddress address;

    StopWatch timeSinceLastInitiatedAcceptStandOff, timeSinceLastInitiatedAccept;
    shared(size_t) lastInitiatedAcceptCount;
    size_t lastInitiatedAcceptStandOff;

    TestSetLockInline mutextToProtectAccepts;

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

void forceClose(scope PlatformListenSocket* socketState) scope @trusted {
    version(Windows) {
        closesocket(socketState.handle);
    } else
        assert(0);
}

void cleanup(scope PlatformListenSocket* socketState) scope @trusted {
    version(Windows) {
        CloseHandle(socketState.eventHandle);
    } else
        assert(0);
}

bool listenOnAddress(scope ListenSocketState* listenSocketState, bool reuseAddr, Optional!Duration keepAliveInterval) @trusted {
    if(listenSocketState.address.type == NetworkAddress.Type.Hostname) {
        auto resolved = listenSocketState.address.resolve();

        uint gotOne;

        foreach(address; resolved) {
            if(listenOnSpecificAddress(listenSocketState, address, reuseAddr, keepAliveInterval))
                gotOne++;
        }

        if(gotOne > 0)
            return true;
    } else if(listenSocketState.address.type != NetworkAddress.Type.Invalid) {
        if(listenOnSpecificAddress(listenSocketState, listenSocketState.address, reuseAddr, keepAliveInterval))
            return true;
    }

    return false;
}

void checkForAccepts(ListenSocketPair listenSocketPair) {
    import sidero.base.internal.atomic;
    import core.stdc.math : hypotf, cbrtf;

    version(Windows) {
        assert(listenSocketPair.perSocket);

        const currentCount = atomicLoad(listenSocketPair.perSocket.lastInitiatedAcceptCount);

        if(atomicDecrementAndLoad(listenSocketPair.perSocket.numberOfAccepts, 1) <= currentCount / 2) {
            if(listenSocketPair.perSocket.mutextToProtectAccepts.tryLock) {
                // A lot of what we do here is actually "magic".
                // The numbers here were picked to try and prevent both denial of service attacks taking a foot hold.
                // By having both a stand off attempts and stand off in seconds,
                //  we can guarantee we will only attempt to have accepts that we can actually handle.

                // This number provides us the ability to know
                const nextStandOffAmount = cast(size_t)hypotf(currentCount, currentCount).cbrtf;

                if(currentCount < 5_000 && listenSocketPair.perSocket.timeSinceLastInitiatedAcceptStandOff.peek < 1.seconds) {
                    listenSocketPair.perSocket.lastInitiatedAcceptStandOff++;

                    if(listenSocketPair.perSocket.lastInitiatedAcceptStandOff > nextStandOffAmount) {
                        // Ok the number posts has occured, but also has the right number of seconds occured also?

                        if(listenSocketPair.perSocket.timeSinceLastInitiatedAccept.peek >= nextStandOffAmount.seconds) {
                            // ok bump it to next value

                            // This formula will take around 6 hours to boot up all the way to 5_000 accepts
                            // However it is fine if it doesn't, it'll accept more immediately.
                            float diff = cbrtf(5000 - (5000 / currentCount)) * ((nextStandOffAmount + currentCount.cbrtf));
                            atomicStore(listenSocketPair.perSocket.lastInitiatedAcceptCount, currentCount + cast(size_t)diff);

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
                postAccept(listenSocketPair, 10);
            }
        }
    }
}

private:

bool listenOnSpecificAddress(ListenSocketState* listenSocketState, NetworkAddress address, bool reuseAddr,
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

        {
            platformListenSocket.eventHandle = WSACreateEvent();

            if(platformListenSocket.eventHandle is WSA_INVALID_EVENT) {
                logger.notice("Error occured while creating the accept/close event ", platformListenSocket.handle,
                        " with error ", WSAGetLastError(), " on ", Thread.self);
                closesocket(platformListenSocket.handle);
                return false;
            } else {
                logger.debug_("WSA accept/close event created ", platformListenSocket.handle, " on ", Thread.self);
            }

            uint eventsFlag = FD_CLOSE;

            static if(!CanAcceptLater) {
                eventsFlag |= FD_ACCEPT;
            }

            if(WSAEventSelect(platformListenSocket.handle, platformListenSocket.eventHandle, eventsFlag) == SOCKET_ERROR) {
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

        listenSocketState.pin(1);
        platformListenSocket.address = address;
        atomicStore(platformListenSocket.isAlive, true);

        listenSocketState.platformSockets[platformListenSocket.eventHandle] = platformListenSocket;
        addEventWaiterHandle(platformListenSocket.eventHandle, &handleListenSocketEvent, listenSocketState);

        static if(CanAcceptLater) {
            ListenSocket listenSocket;
            listenSocket.state = listenSocketState;
            listenSocket.state.rc(true);

            auto perSockState = listenSocket.state.platformSockets[platformListenSocket.eventHandle];
            assert(perSockState);

            // start up the state needed for accept stand off
            perSockState.timeSinceLastInitiatedAcceptStandOff.start;
            perSockState.timeSinceLastInitiatedAccept.start;
            atomicStore(perSockState.lastInitiatedAcceptCount, 3);

            ListenSocketPair pair = ListenSocketPair(listenSocket, perSockState);
            // post away the initial accepts
            postAccept(pair, 3);
        }
        return true;
    } else
        assert(0);
}

void handleListenSocketEvent(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version(Windows) {
        ListenSocket listenSocket;
        listenSocket.state = cast(ListenSocketState*)user;
        listenSocket.state.rc(true);

        auto perSockState = listenSocket.state.platformSockets[cast(PlatformListenSocketKey)handle];
        assert(perSockState);

        WSANETWORKEVENTS wsaEvent;

        if(WSAEnumNetworkEvents(perSockState.handle, perSockState.eventHandle, &wsaEvent) != 0) {
            auto error = GetLastError();

            if(error == WSAENOTSOCK) {
                // ok just in case lets just unpin it
                listenSocket.state.unpin;
            } else {
                logger.notice("Error could not enumerate WSA network listen socket events with code ",
                        perSockState.handle, " with error ", error, " on ", Thread.self);
            }
        } else if((wsaEvent.lNetworkEvents & FD_ACCEPT) == FD_ACCEPT && wsaEvent.iErrorCode[FD_ACCEPT_BIT] == 0) {
            logger.debug_("Listen socket got an accept ", perSockState.handle, " on ", Thread.self);
            ListenSocketPair pair = ListenSocketPair(listenSocket, perSockState);
            postAccept(pair, 1);
        } else if((wsaEvent.lNetworkEvents & FD_CLOSE) == FD_CLOSE && wsaEvent.iErrorCode[FD_CLOSE_BIT] == 0) {
            logger.debug_("Listen socket closing cleanly ", perSockState.handle, " on ", Thread.self);
            closesocket(perSockState.handle);
            listenSocket.state.unpin();
        }
    } else
        assert(0);
}

void postAccept(ListenSocketPair listenSocketPair, size_t numberOfAccepts) @trusted {
    import sidero.eventloop.internal.networking.windows.socketclient;
    import sidero.eventloop.internal.workers.kernelwait.windows;
    import sidero.eventloop.internal.event_waiting;
    import sidero.base.bitmanip : bigEndianToNative, nativeToBigEndian;
    import sidero.eventloop.tasks.workers : registerAsTask;
    import sidero.base.internal.atomic;

    assert(listenSocketPair.perSocket);
    logger.debug_("Posting ", numberOfAccepts, " accepts for listen socket ", listenSocketPair.perSocket.handle,
            " is null? ", listenSocketPair.listenSocket.isNull(), " is alive? ",
            listenSocketPair.listenSocket.isAlive(), " on ", Thread.self);

    foreach(_; 0 .. numberOfAccepts) {
        if(!listenSocketPair.listenSocket.isAlive())
            return;

        version(Windows) {
            short addressFamily, socketType, socketProtocol;

            {
                bool notRecognized;

                listenSocketPair.perSocket.address.onNetworkOrder((uint value) @trusted {
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

                if(notRecognized) {
                    logger.error("Did not recognize network address type for accept ", listenSocketPair.perSocket.address,
                            " for ", listenSocketPair.perSocket.handle, " on ", Thread.self);
                    return;
                }
            }

            final switch(listenSocketPair.listenSocket.state.protocol) {
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

            if(acceptedSocket == INVALID_SOCKET) {
                logger.error("Error could not create accepted socket with error ", listenSocketPair.perSocket.handle,
                        " for ", listenSocketPair.perSocket.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                return;
            }

            // we'll setup the local/remote addresses later
            Socket acquiredSocket = Socket.fromListen(listenSocketPair, NetworkAddress.init, NetworkAddress.init);
            acquiredSocket.state.handle = acceptedSocket;

            DWORD received;

            acquiredSocket.state.acceptOverlapped = OVERLAPPED.init;
            auto result = AcceptEx(listenSocketPair.perSocket.handle, acceptedSocket,
                    acquiredSocket.state.addressBuffer.ptr, 0, sockaddr_in.sizeof + 16, sockaddr_in.sizeof + 16,
                    &received, &acquiredSocket.state.acceptOverlapped);

            if(result == 0) {
                auto error = WSAGetLastError();

                switch(error) {
                case ERROR_IO_PENDING:
                    static if(CanAcceptLater) {
                        acquiredSocket.state.isDelayedAccept = true;
                        logger.debug_("Socket is delayed for acceptance ", acquiredSocket.state.handle,
                                " for listen socket ", listenSocketPair.perSocket.handle, " on ", Thread.self);
                        break;
                    } else {
                        goto default;
                    }

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

            static if(!acquiredSocket.state.keepAReadAlwaysGoing) {
                acquiredSocket.state.onCloseEvent = WSACreateEvent();

                if(acquiredSocket.state.onCloseEvent is WSA_INVALID_EVENT) {
                    logger.notice("Error occured while creating the on close event with code ", acceptedSocket,
                            " for ", listenSocketPair.perSocket.handle, " with error ", GetLastError(), " on ", Thread.self);
                    closesocket(acceptedSocket);
                    return;
                } else {
                    logger.debug_("WSA on close event created ", acceptedSocket, " on ", Thread.self);
                }

                if(WSAEventSelect(acceptedSocket, acquiredSocket.state.onCloseEvent, FD_CLOSE) == SOCKET_ERROR) {
                    logger.notice("Could not associated on close event with accepted socket ", acceptedSocket, " for ",
                            listenSocketPair.perSocket.handle, " with error ", WSAGetLastError(), " on ", Thread.self);
                    closesocket(acceptedSocket);
                    return;
                } else {
                    logger.debug_("Associated on close event on accepted socket ", acceptedSocket, " on ", Thread.self);
                }
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
                acquiredSocket.state.rc(true);
            } else {
                static if(acquiredSocket.state.keepAReadAlwaysGoing) {
                    acquiredSocket.state.initiateAConstantlyRunningReadRequest(acquiredSocket.state);
                } else {
                    addEventWaiterHandle(acquiredSocket.state.onCloseEvent, &handleSocketEvent, acquiredSocket.state);
                }

                auto acceptSocketCO = listenSocketPair.listenSocket.state.onAccept.makeInstance(RCAllocator.init, acquiredSocket);
                registerAsTask(acceptSocketCO);
            }
        } else
            assert(0);
    }
}
