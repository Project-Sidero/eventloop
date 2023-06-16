module sidero.eventloop.networking.internal.windows.mechanism;
import sidero.base.text;
import sidero.base.logger;

@safe nothrow @nogc:

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import sidero.eventloop.internal.windows.iocp;

    private __gshared {
        LoggerReference logger;
    }

    bool startUpNetworkingMechanism() @trusted {
        import core.sys.windows.windows : MAKEWORD, GetLastError, NO_ERROR;
        import core.sys.windows.winsock2;

        auto gotLogger = Logger.forName(String_UTF8(__MODULE__));
        if (gotLogger)
            logger = gotLogger.get;

        enum WSAVersion = MAKEWORD(2, 2);

        WSADATA wsaData;
        int nResult = WSAStartup(WSAVersion, &wsaData);

        if (nResult != NO_ERROR) {
            logger.error("Error occured while executing WSAStartup with code", GetLastError(), nResult);
            return false;
        } else {
            logger.trace("WSA initialized successfully");
        }

        return true;
    }

    void shutdownNetworkingMechanism() {
        import core.sys.windows.winsock2 : WSACleanup;

        WSACleanup;
    }

    struct PlatformListenSocket {
    package(sidero.eventloop):
        SOCKET handle;
        WSAEVENT eventHandle;

    @safe nothrow @nogc:
        void forceClose() scope {
            import core.sys.windows.windows : closesocket;

            closesocket(handle);
        }

        void shutdown() scope {
            import core.sys.windows.windows : shutdown, SD_BOTH;

            shutdown(handle, SD_BOTH);
        }

        void cleanup() scope @trusted {
            import core.sys.windows.windows : CloseHandle;

            CloseHandle(eventHandle);
        }
    }

    struct PlatformSocket {
    @safe nothrow @nogc:

        void forceClose() {

        }

        void cleanup() {

        }

        void shutdown() {

        }

        void unregister() {

        }
    }
}
