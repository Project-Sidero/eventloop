module sidero.eventloop.internal.windows.bindings;

version(Windows) {
    public import core.sys.windows.windows : SOCKET, DWORD, GUID, CHAR, WCHAR, HANDLE, INFINITE, WAIT_OBJECT_0,
        WAIT_TIMEOUT, OVERLAPPED, ULONG, ERROR_IO_INCOMPLETE, FileTimeToSystemTime, SYSTEMTIME, LPSTR, BOOL, LPCWSTR,
        PLUID, WSAENOTSOCK, getsockname, GetLastError;
    public import core.sys.windows.ntdef : PUNICODE_STRING, UNICODE_STRING;
    public import core.sys.windows.wincrypt : PCCERT_CONTEXT, X509_ASN_ENCODING, PKCS_7_ASN_ENCODING, CERT_SIMPLE_NAME_STR, HCERTSTORE,
        PCCERT_CONTEXT, CERT_RDN_VALUE_BLOB, CERT_FIND_SUBJECT_STR_W, CERT_FIND_ISSUER_STR_W, CERT_NAME_BLOB, HCRYPTPROV, ALG_ID;
    public import core.sys.windows.sspi : SecPkgInfoW, CredHandle, SECPKG_CRED_INBOUND, SECPKG_CRED_OUTBOUND, TimeStamp, SEC_GET_KEY_FN,
        SecPkgContext_StreamSizes, CtxtHandle, PSecHandle, SECPKG_ATTR_STREAM_SIZES, SecBuffer, SecBufferDesc, SECBUFFER_STREAM_HEADER,
        SECBUFFER_DATA, PCtxtHandle, SECBUFFER_STREAM_TRAILER, SECBUFFER_VERSION, SECBUFFER_EMPTY, SECBUFFER_EXTRA, SECBUFFER_TOKEN;
    public import core.sys.windows.security : SECURITY_STATUS, SEC_E_OK, SEC_I_RENEGOTIATE, SEC_I_CONTINUE_NEEDED,
        SEC_E_WRONG_PRINCIPAL, SEC_E_INCOMPLETE_MESSAGE;
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
        SECURITY_STATUS QuerySecurityPackageInfoW(wchar*, SecPkgInfoW**);
        SECURITY_STATUS FreeContextBuffer(void*);
        SECURITY_STATUS AcquireCredentialsHandleW(wchar*, wchar*, ULONG, PLUID, void*, SEC_GET_KEY_FN, void*,
                CredHandle*, TimeStamp*);
        SECURITY_STATUS FreeCredentialsHandle(CredHandle*);
        SECURITY_STATUS QueryContextAttributesW(PSecHandle, ULONG, void*);
        SECURITY_STATUS DecryptMessage(PSecHandle, SecBufferDesc*, ULONG, ULONG*);
        SECURITY_STATUS EncryptMessage(PSecHandle, ULONG, SecBufferDesc*, ULONG);
        SECURITY_STATUS AcceptSecurityContext(CredHandle*, PCtxtHandle, SecBufferDesc*, ULONG, ULONG, PCtxtHandle,
                SecBufferDesc*, ULONG*, TimeStamp*);
        SECURITY_STATUS DeleteSecurityContext(PCtxtHandle);
        SECURITY_STATUS InitializeSecurityContextW(CredHandle*, PCtxtHandle, wchar*, ULONG, ULONG, ULONG,
                SecBufferDesc*, ULONG, PCtxtHandle, SecBufferDesc*, ULONG*, TimeStamp*);
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

        SCHANNEL_CRED_VERSION = 4,
        SCH_CREDENTIALS_VERSION = 5,

        SECURITY_NATIVE_DREP = 0x00000010,
        ISC_REQ_ALLOCATE_MEMORY = 0x00000100,
        ISC_REQ_STREAM = 0x00008000,

        SP_PROT_SSL2_SERVER = 0x00000004,
        SP_PROT_SSL3_SERVER = 0x00000010,
        SP_PROT_TLS1_SERVER = 0x00000040,
        SP_PROT_TLS1_0_SERVER = SP_PROT_TLS1_SERVER,
        SP_PROT_TLS1_1_SERVER = 0x00000100,
        SP_PROT_TLS1_2_SERVER = 0x00000400,
        SP_PROT_TLS1_3_SERVER = 0x00001000,
        SP_PROT_DTLS1_SERVER = 0x00010000,
        SP_PROT_DTLS1_0_SERVER = SP_PROT_DTLS1_SERVER,
        SP_PROT_DTLS1_2_SERVER = 0x00040000,

        SP_PROT_SSL2_CLIENT = 0x00000008,
        SP_PROT_SSL3_CLIENT = 0x00000020,
        SP_PROT_TLS1_CLIENT = 0x00000080,
        SP_PROT_TLS1_0_CLIENT = SP_PROT_TLS1_CLIENT,
        SP_PROT_TLS1_1_CLIENT = 0x00000200,
        SP_PROT_TLS1_2_CLIENT = 0x00000800,
        SP_PROT_TLS1_3_CLIENT = 0x00002000,
        SP_PROT_DTLS1_CLIENT = 0x00020000,
        SP_PROT_DTLS1_0_CLIENT = SP_PROT_DTLS1_CLIENT,
        SP_PROT_DTLS1_2_CLIENT = 0x00080000,

        SCH_CRED_AUTO_CRED_VALIDATION = 0x00000020,
        SCH_CRED_MANUAL_CRED_VALIDATION = 0x00000008,
        SCH_CRED_NO_SERVERNAME_CHECK = 0x00000004,
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

    struct SCH_CREDENTIALS {
        DWORD dwVersion;
        DWORD dwCredFormat;
        DWORD cCreds;
        PCCERT_CONTEXT* paCred;
        HCERTSTORE hRootStore;
        DWORD cMappers;
        void** aphMappers;
        DWORD dwSessionLifespan;
        DWORD dwFlags;
        DWORD cTlsParameters;
        TLS_PARAMETERS* pTlsParameters;
    }

    struct TLS_PARAMETERS {
        DWORD cAlpnIds;
        PUNICODE_STRING rgstrAlpnIds;
        DWORD grbitDisabledProtocols;
        DWORD cDisabledCrypto;
        CRYPTO_SETTINGS* pDisabledCrypto;
        DWORD dwFlags;
    }

    struct CRYPTO_SETTINGS {
        eTlsAlgorithmUsage eAlgorithmUsage;
        UNICODE_STRING strCngAlgId;
        DWORD cChainingModes;
        PUNICODE_STRING rgstrChainingModes;
        DWORD dwMinBitLength;
        DWORD dwMaxBitLength;
    }

    enum eTlsAlgorithmUsage {
        TlsParametersCngAlgUsageKeyExchange,
        TlsParametersCngAlgUsageSignature,
        TlsParametersCngAlgUsageCipher,
        TlsParametersCngAlgUsageDigest,
        TlsParametersCngAlgUsageCertSig
    }

    struct SCHANNEL_CRED {
        DWORD dwVersion;
        DWORD cCreds;
        PCCERT_CONTEXT* paCred;
        HCERTSTORE hRootStore;
        DWORD cMappers;
        void** aphMappers;
        DWORD cSupportedAlgs;
        ALG_ID* palgSupportedAlgs;
        DWORD grbitEnabledProtocols;
        DWORD dwMinimumCipherStrength;
        DWORD dwMaximumCipherStrength;
        DWORD dwSessionLifespan;
        DWORD dwFlags;
        DWORD dwCredFormat;
    }
}
