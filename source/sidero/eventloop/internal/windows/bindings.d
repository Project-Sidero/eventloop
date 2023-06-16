module sidero.eventloop.internal.windows.bindings;

version (Windows) {
    public import core.sys.windows.windows : SOCKET, DWORD, GUID, CHAR, WCHAR, HANDLE, INFINITE, WAIT_OBJECT_0,
        WAIT_TIMEOUT, OVERLAPPED, ULONG, ERROR_IO_INCOMPLETE;
    import core.stdc.config : c_long;

    alias WSAEVENT = HANDLE;
    alias LPWSAOVERLAPPED_COMPLETION_ROUTINE = extern (Windows) void function(DWORD, DWORD, OVERLAPPED*, DWORD) nothrow;

    extern (Windows) nothrow @nogc {
        SOCKET WSASocketA(int, int, int, WSAPROTOCOL_INFOA*, GROUP, DWORD);
        SOCKET WSASocketW(int, int, int, WSAPROTOCOL_INFOW*, GROUP, DWORD);
        WSAEVENT WSACreateEvent();
        bool WSACloseEvent(WSAEVENT);
        int WSAEventSelect(SOCKET, WSAEVENT, c_long);
        DWORD WSAWaitForMultipleEvents(DWORD, WSAEVENT*, bool, DWORD, bool);
        bool WSASetEvent(WSAEVENT);
        bool WSAResetEvent(WSAEVENT);
        int WSAEnumNetworkEvents(SOCKET, WSAEVENT, WSANETWORKEVENTS*);
        bool AcceptEx(SOCKET, SOCKET, void*, DWORD, DWORD, DWORD, DWORD*, OVERLAPPED*);
        int WSARecv(SOCKET, WSABUF*, DWORD, DWORD*, DWORD*, OVERLAPPED*, LPWSAOVERLAPPED_COMPLETION_ROUTINE);
        bool WSAGetOverlappedResult(SOCKET, OVERLAPPED*, DWORD*, bool, DWORD*);
        int WSASend(SOCKET, WSABUF*, DWORD, DWORD*, DWORD, OVERLAPPED*, LPWSAOVERLAPPED_COMPLETION_ROUTINE);
    }

    enum {
        WSAPROTOCOL_LEN = 255,
        MAX_PROTOCOL_CHAIN = 7,
        WSA_FLAG_OVERLAPPED = 1,
        SOMAXCONN = 0x7fffffff,
        WSA_INVALID_EVENT = cast(WSAEVENT)null,
        FD_ACCEPT_BIT = 3,
        FD_ACCEPT = 1 << FD_ACCEPT_BIT,
        FD_CLOSE_BIT = 5,
        FD_CLOSE = 1 << FD_CLOSE_BIT,
        WSA_INFINITE = INFINITE,
        WSA_WAIT_EVENT_0 = WAIT_OBJECT_0,
        WSA_WAIT_TIMEOUT = WAIT_TIMEOUT,
        FD_MAX_EVENTS = 10,
        WSA_IO_INCOMPLETE = ERROR_IO_INCOMPLETE,
    }

    struct WSAPROTOCOLCHAIN {
        int ChainLen;
        DWORD[MAX_PROTOCOL_CHAIN] ChainEntries;
    }

    alias GROUP = uint;

    struct WSAPROTOCOL_INFOA {
        DWORD dwServiceFlags1;
        DWORD dwServiceFlags2;
        DWORD dwServiceFlags3;
        DWORD dwServiceFlags4;
        DWORD dwProviderFlags;
        GUID ProviderId;
        DWORD dwCatalogEntryId;
        WSAPROTOCOLCHAIN ProtocolChain;
        int iVersion;
        int iAddressFamily;
        int iMaxSockAddr;
        int iMinSockAddr;
        int iSocketType;
        int iProtocol;
        int iProtocolMaxOffset;
        int iNetworkByteOrder;
        int iSecurityScheme;
        DWORD dwMessageSize;
        DWORD dwProviderReserved;
        CHAR[WSAPROTOCOL_LEN + 1] szProtocol;
    }

    struct WSAPROTOCOL_INFOW {
        DWORD dwServiceFlags1;
        DWORD dwServiceFlags2;
        DWORD dwServiceFlags3;
        DWORD dwServiceFlags4;
        DWORD dwProviderFlags;
        GUID ProviderId;
        DWORD dwCatalogEntryId;
        WSAPROTOCOLCHAIN ProtocolChain;
        int iVersion;
        int iAddressFamily;
        int iMaxSockAddr;
        int iMinSockAddr;
        int iSocketType;
        int iProtocol;
        int iProtocolMaxOffset;
        int iNetworkByteOrder;
        int iSecurityScheme;
        DWORD dwMessageSize;
        DWORD dwProviderReserved;
        WCHAR[WSAPROTOCOL_LEN + 1] szProtocol;
    }

    struct WSANETWORKEVENTS {
        long lNetworkEvents;
        int[FD_MAX_EVENTS] iErrorCode;
    }

    struct WSABUF {
        ULONG len;
        ubyte* buf;
    }
}
