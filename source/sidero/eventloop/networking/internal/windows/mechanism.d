module sidero.eventloop.networking.internal.windows.mechanism;
import sidero.eventloop.networking.sockets;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.containers.queue.concurrentqueue;

__gshared {
    package(sidero.eventloop.networking.internal.windows) {
        LoggerReference logger;
    }
}

@safe nothrow @nogc:

bool startUpNetworkingMechanism() @trusted {
    import sidero.eventloop.internal.cleanup_timer;

    logger = Logger.forName(String_UTF8(__MODULE__));
    if(!logger)
        return false;

    if(!startUpCleanupTimer()) {
        logger.warning("Failed to setup cleanup timer");
        return false;
    }

    version(Windows) {
        import sidero.eventloop.internal.windows.bindings : MAKEWORD, WSADATA, WSAStartup, NO_ERROR, WSAGetLastError;

        {
            enum WSAVersion = MAKEWORD(2, 2);

            WSADATA wsaData;
            int nResult = WSAStartup(WSAVersion, &wsaData);

            if(nResult != NO_ERROR) {
                logger.warning("Error occured while executing WSAStartup with code", WSAGetLastError(), " ", nResult);
                return false;
            } else {
                logger.info("WSA initialized successfully");
            }
        }
    } else
        assert(0);

    return true;
}

void shutdownNetworkingMechanism() @trusted {
    import sidero.eventloop.internal.cleanup_timer;

    version(Windows) {
        import sidero.eventloop.internal.windows.bindings : WSACleanup;

        WSACleanup;
        logger.info("WSA uninitialized");
    } else
        assert(0);

    shutdownCleanupTimer();
}
