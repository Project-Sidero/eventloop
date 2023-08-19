module sidero.eventloop.networking.internal.windows.mechanism;
import sidero.base.logger;
import sidero.base.text;

__gshared {
    package(sidero.eventloop.networking.internal.windows) {
        LoggerReference logger;
    }
}

@safe nothrow @nogc:

bool startUpNetworkingMechanism() @trusted {
    version(Windows) {
        import sidero.eventloop.internal.windows.bindings;

        logger = Logger.forName(String_UTF8(__MODULE__));
        if(!logger)
            return false;

        logger.setLevel = LogLevel.Trace;
        enum WSAVersion = MAKEWORD(2, 2);

        WSADATA wsaData;
        int nResult = WSAStartup(WSAVersion, &wsaData);

        if(nResult != NO_ERROR) {
            logger.warning("Error occured while executing WSAStartup with code", WSAGetLastError(), " ", nResult);
            return false;
        } else {
            logger.info("WSA initialized successfully");
        }

        return true;
    } else
        assert(0);
}

void shutdownNetworkingMechanism() @trusted {
    version(Windows) {
        import sidero.eventloop.internal.windows.bindings;

        WSACleanup;
        logger.info("WSA uninitialized");
    } else
        assert(0);
}
