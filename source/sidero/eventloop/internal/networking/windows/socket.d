module sidero.eventloop.internal.networking.windows.socket;
import sidero.eventloop.internal.networking.windows.mechanism;
import sidero.eventloop.internal.networking.windows.socket;
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

    ubyte[(SockAddressMaxSize * 2) + 32] addressBuffer;

    enum keepAReadAlwaysGoing = true;

@safe nothrow @nogc:

     ~this() scope {
    }

    // NOTE: must not be guarded
    void haveBeenRetriggered(scope SocketState* socketState) scope {
        isWaitingForRetrigger = false;

        socketState.guard(&socketState.performReadWrite);
    }

    // NOTE: must be guarded
    void notifiedOfReadComplete(scope SocketState* socketState) scope @trusted {
        this.havePendingAlwaysWaitingRead = false;
        this.havePendingRead = false;
    }

    // NOTE: must be guarded
    void initiateAConstantlyRunningReadRequest(scope SocketState* socketState) scope @trusted {
        version(Windows) {
            import sidero.base.internal.atomic : atomicLoad;

            if(atomicLoad(socketState.isShutdown) || socketState.havePendingAlwaysWaitingRead || socketState.havePendingRead)
                return;

            socketState.readOverlapped = OVERLAPPED.init;
            socketState.havePendingAlwaysWaitingRead = true;

            logger.debug_("Starting a constantly running read request for ", socketState.handle, " on ", Thread.self);

            DWORD flags;

            ubyte[1] buf;
            WSABUF wsaBuffer;
            wsaBuffer.buf = buf.ptr;

            auto result = WSARecv(socketState.handle, &wsaBuffer, 1, null, &flags, &socketState.readOverlapped, null);

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
}

bool extractSocketAddressInformation(NetworkAddress address, Socket.Protocol protocol, bool allowAny,
        out short addressFamily, out short socketType, out short socketProtocol, ref ubyte[SockAddressMaxSize] addressBuffer,
        out int addressBufferSize) {
    bool notRecognized;

    address.onNetworkOrder((uint value) @trusted {
        //ipv4
        addressFamily = AF_INET;
        addressBufferSize = SockAddress4Size;

        sockaddr_in* saPtr = cast(sockaddr_in*)addressBuffer.ptr;
        saPtr.sin_family = AF_INET;
        saPtr.sin_addr.s_addr = value;
        saPtr.sin_port = address.networkOrderPort();
    }, (ushort[8] value) @trusted {
        // ipv6
        addressFamily = AF_INET6;
        addressBufferSize = SockAddress6Size;

        sockaddr_in6* saPtr = cast(sockaddr_in6*)addressBuffer.ptr;
        saPtr.sin6_family = AF_INET6;
        saPtr.sin6_addr.Word = value;
        saPtr.sin6_port = address.networkOrderPort();
    }, () @trusted {
        if(allowAny) {
            // any ipv4
            addressFamily = AF_INET;
            addressBufferSize = SockAddress4Size;

            sockaddr_in* saPtr = cast(sockaddr_in*)addressBuffer.ptr;
            saPtr.sin_family = AF_INET;
            saPtr.sin_addr.s_addr = INADDR_ANY;
            saPtr.sin_port = address.networkOrderPort();
        } else
            notRecognized = true;
    }, () @trusted {
        if(allowAny) {
            // any ipv6
            addressFamily = AF_INET6;
            addressBufferSize = SockAddress6Size;

            sockaddr_in6* saPtr = cast(sockaddr_in6*)addressBuffer.ptr;
            saPtr.sin6_family = AF_INET6;
            saPtr.sin6_addr = IN6ADDR_ANY;
            saPtr.sin6_port = address.networkOrderPort();
        } else
            notRecognized = true;
    }, (scope Hostname hostname) { notRecognized = true; }, () { notRecognized = true; });

    if(notRecognized)
        return false;

    final switch(protocol) {
    case Socket.Protocol.TCP:
        socketType = SOCK_STREAM;
        socketProtocol = IPPROTO_TCP;
        break;
    case Socket.Protocol.UDP:
        socketType = SOCK_DGRAM;
        socketProtocol = IPPROTO_UDP;
        break;
    }

    return true;
}

void shutdown(scope SocketState* socketState, bool haveReferences = true) @trusted {
    version(Windows) {
        import sidero.base.internal.atomic;
        import core.sys.windows.winsock2 : shutdown;

        if(cas(socketState.isShutdown, false, true)) {
            logger.info("Shutting down socket ", socketState.handle, " on ", Thread.self);
            socketState.performReadWrite();
            shutdown(socketState.handle, SD_SEND);

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
                needToBeRetriggered(socketState);
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
                needToBeRetriggered(socketState);
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

private:

// NOTE: needs to be guarded
void needToBeRetriggered(scope SocketState* socketState) scope @trusted {
    import sidero.eventloop.internal.cleanup_timer;
    import sidero.base.internal.atomic : atomicLoad;

    if(socketState.isWaitingForRetrigger || atomicLoad(socketState.isClosed))
        return;

    Socket socket;
    socket.state = socketState;
    socket.state.rc(true);

    socketState.isWaitingForRetrigger = true;
    addSocketToRetrigger(socket);
}
