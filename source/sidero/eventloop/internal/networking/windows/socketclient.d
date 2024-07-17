module sidero.eventloop.internal.networking.windows.socketclient;
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

ErrorResult connectToSpecificAddress(Socket socket, NetworkAddress address) @trusted {
    version(Windows) {
        SocketState* socketState = socket.state;

        ubyte[SockAddressMaxSize] localAddressBuffer, remoteAddressBuffer;
        int localAddressSize = SockAddressMaxSize, remoteAddressSize;
        short addressFamily, socketType, socketProtocol;

        if(!extractSocketAddressInformation(address, socketState.protocol, false, addressFamily, socketType,
                socketProtocol, remoteAddressBuffer, remoteAddressSize))
            return ErrorResult(MalformedInputException("Not a valid network address, must be resolved ip/port"));

        {
            socketState.handle = WSASocketW(addressFamily, socketType, socketProtocol, null, 0, WSA_FLAG_OVERLAPPED);

            if(socketState.handle == INVALID_SOCKET) {
                logger.notice("Could not open socket ", address, " with error ", WSAGetLastError(), " on ", Thread.self);
                return ErrorResult(UnknownPlatformBehaviorException("Could not create socket"));
            } else {
                logger.debug_("Socket created successfully ", socketState.handle, " at ", address, " on ", Thread.self);
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
            } else {
                logger.notice("Did not recognize an IP address for socket client local ", localAddress, " remote ",
                        address, " for ", socketState.handle, " on ", Thread.self);
                closesocket(socketState.handle);
                CloseHandle(socketState.onCloseEvent);
                return ErrorResult(UnknownPlatformBehaviorException("Could not acquire local address for client socket"));
            }

            logger.debug_("Connected socket addresses local ", localAddress, " remote ", address, " for ",
                    socketState.handle, " on ", Thread.self);

            socketState.localAddress = localAddress;
            socketState.remoteAddress = address;
        }

        socketState.pin();
        socketState.initiateAConstantlyRunningReadRequest(socketState);
        return ErrorResult.init;
    } else
        assert(0);
}
