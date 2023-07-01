module sidero.eventloop.internal.windows.bindings;

version (Windows) {
    public import core.sys.windows.windows : SOCKET, DWORD, GUID, CHAR, WCHAR, HANDLE, INFINITE, WAIT_OBJECT_0,
        WAIT_TIMEOUT, OVERLAPPED, ULONG, ERROR_IO_INCOMPLETE, FileTimeToSystemTime, SYSTEMTIME, LPSTR, BOOL, LPCWSTR;
    public import core.sys.windows.wincrypt : PCCERT_CONTEXT, X509_ASN_ENCODING, PKCS_7_ASN_ENCODING, CERT_SIMPLE_NAME_STR, HCERTSTORE,
        PCCERT_CONTEXT, CERT_RDN_VALUE_BLOB, CERT_FIND_SUBJECT_STR_W, CERT_FIND_ISSUER_STR_W, CERT_NAME_BLOB, HCRYPTPROV;
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

        PCCERT_CONTEXT CertDuplicateCertificateContext(PCCERT_CONTEXT);
        PCCERT_CONTEXT CertEnumCertificatesInStore(HCERTSTORE, PCCERT_CONTEXT);
        DWORD CertEnumCertificateContextProperties(PCCERT_CONTEXT, DWORD);
        bool CertGetCertificateContextProperty(PCCERT_CONTEXT, DWORD, void*, DWORD*);
        PCCERT_CONTEXT CertCreateCertificateContext(DWORD, const(ubyte)*, DWORD);
        BOOL CertFreeCertificateContext(PCCERT_CONTEXT);
        bool CertGetCertificateContextProperty(PCCERT_CONTEXT, DWORD, void*, DWORD*);
        DWORD CertGetNameStringW(PCCERT_CONTEXT, DWORD, DWORD, void*, wchar*, DWORD);
        HCERTSTORE CertOpenSystemStoreW(HCRYPTPROV, LPCWSTR);
        BOOL CertCloseStore(HCERTSTORE, DWORD);
        PCCERT_CONTEXT CertFindCertificateInStore(HCERTSTORE, DWORD, DWORD, DWORD, const(void)*, PCCERT_CONTEXT);

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

        szOID_COMMON_NAME = "2.5.4.3",
        szOID_PKCS_12_FRIENDLY_NAME_ATTR = "1.2.840.113549.1.9.20",
        CERT_RDN_PRINTABLE_STRING = 4,
        CERT_RDN_UNICODE_STRING = 12,
        CERT_RDN_UTF8_STRING = 13,
        CERT_FRIENDLY_NAME_PROP_ID = 11,
        CERT_NAME_RDN_TYPE = 2,
        CERT_NAME_ISSUER_FLAG = 1,
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

    struct CERT_RDN_ATTR {
        LPSTR pszObjId;
        DWORD dwValueType;
        CERT_RDN_VALUE_BLOB Value;
    }

    struct CERT_RDN {
        DWORD cRDNAttr;
        CERT_RDN_ATTR* rgRDNAttr;
    }

    static immutable WinCrypt_Stores_Strings = ["CA"w, "MY"w, "ROOT"w, "SPC"w];

}
