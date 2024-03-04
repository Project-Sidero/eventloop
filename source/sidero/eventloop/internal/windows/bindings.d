module sidero.eventloop.internal.windows.bindings;

version(Windows) {
    public import core.sys.windows.windows : SOCKET, WORD, DWORD, GUID, CHAR, WCHAR, HANDLE, INFINITE, WAIT_OBJECT_0,
        WAIT_TIMEOUT, ULONG, LONG, LONGLONG, ERROR_IO_INCOMPLETE, FileTimeToSystemTime, SYSTEMTIME, LPSTR, LPCSTR,
        LPWSTR, BOOL, LPCWSTR, ULONG_PTR, PLUID, WSAENOTSOCK, GetLastError, MAKEWORD, LPCWSTR, LocalAlloc, LocalFree;
    public import core.sys.windows.ntdef : PUNICODE_STRING, UNICODE_STRING;
    public import core.sys.windows.wincrypt : PCCERT_CONTEXT, X509_ASN_ENCODING, PKCS_7_ASN_ENCODING, CERT_SIMPLE_NAME_STR, HCERTSTORE,
        PCCERT_CONTEXT, CERT_RDN_VALUE_BLOB, CERT_FIND_SUBJECT_STR_W, CERT_FIND_ISSUER_STR_W, CERT_NAME_BLOB, HCRYPTPROV, ALG_ID;
    public import core.sys.windows.sspi : SecPkgInfoW, CredHandle, SECPKG_CRED_INBOUND, SECPKG_CRED_OUTBOUND, TimeStamp, SEC_GET_KEY_FN,
        SecPkgContext_StreamSizes, CtxtHandle, PSecHandle, SECPKG_ATTR_STREAM_SIZES, SecBuffer, SecBufferDesc, SECBUFFER_STREAM_HEADER,
        SECBUFFER_DATA, PCtxtHandle, SECBUFFER_STREAM_TRAILER, SECBUFFER_VERSION, SECBUFFER_EMPTY, SECBUFFER_EXTRA, SECBUFFER_TOKEN;
    public import core.sys.windows.security : SECURITY_STATUS, SEC_E_OK, SEC_I_RENEGOTIATE, SEC_I_CONTINUE_NEEDED,
        SEC_E_WRONG_PRINCIPAL, SEC_E_INCOMPLETE_MESSAGE, SEC_I_COMPLETE_AND_CONTINUE, SEC_I_COMPLETE_NEEDED;
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
        bool CancelIoEx(SOCKET, OVERLAPPED*);

        bool CryptEncodeObjectEx(DWORD, LPCSTR, const(void)*, DWORD, CRYPT_ENCODE_PARAM*, void*, DWORD*);
        bool CertStrToNameW(DWORD, LPCWSTR, DWORD, void*, ubyte*, DWORD*, LPCWSTR*);
        PCCERT_CONTEXT CertCreateSelfSignCertificate(HANDLE hCryptProvOrNCryptKey, CERT_NAME_BLOB* pSubjectIssuerBlob,
                DWORD dwFlags, CRYPT_KEY_PROV_INFO* pKeyProvInfo,
                CRYPT_ALGORITHM_IDENTIFIER* pSignatureAlgorithm, SYSTEMTIME* pStartTime, SYSTEMTIME* pEndTime,
                CERT_EXTENSIONS* pExtensions);
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
        SECURITY_STATUS CompleteAuthToken(PCtxtHandle, SecBufferDesc*);

        HANDLE CreateIoCompletionPort(HANDLE, HANDLE, ULONG_PTR, DWORD);
        BOOL PostQueuedCompletionStatus(HANDLE, DWORD, ULONG_PTR, OVERLAPPED*);
        BOOL CloseHandle(HANDLE);
        int WSAGetLastError();
        BOOL GetQueuedCompletionStatus(HANDLE, DWORD*, ULONG_PTR*, OVERLAPPED**, DWORD);
        int WSAStartup(WORD, WSADATA*);
        int WSACleanup();

        HANDLE CreateWaitableTimerW(SECURITY_ATTRIBUTES*, BOOL, wchar*);
        BOOL SetWaitableTimer(HANDLE, LARGE_INTEGER*, LONG, void*, void*, BOOL);

        int setsockopt(SOCKET s, int level, int optname, const(void)* optval, int optlen);
        int closesocket(SOCKET s);
        int connect(SOCKET s, const(sockaddr)* name, int namelen);
        int bind(SOCKET s, const(sockaddr)* name, int namelen);
        SOCKET accept(SOCKET s, sockaddr* addr, int* addrlen);
        int listen(SOCKET s, int backlog);
        int getsockname(SOCKET s, sockaddr* name, int* namelen);

        bool GetExitCodeProcess(HANDLE, DWORD*);
        bool CreateProcessW(wchar*, wchar*, SECURITY_ATTRIBUTES*, SECURITY_ATTRIBUTES*, bool, DWORD, void*, wchar*, STARTUPINFOW*, PROCESS_INFORMATION*);
        bool CreatePipe(HANDLE*, HANDLE*, SECURITY_ATTRIBUTES*, DWORD);
        bool SetHandleInformation(HANDLE, DWORD, DWORD);
        bool PeekNamedPipe(HANDLE, void*, DWORD, DWORD*, DWORD*, DWORD*);
        bool ReadFile(HANDLE, void*, DWORD, DWORD*, OVERLAPPED*);
        bool WriteFile(HANDLE, void*, DWORD, DWORD*, OVERLAPPED*);

        bool SetNamedPipeHandleState(HANDLE, DWORD*, DWORD*, DWORD*);
    }

    enum {
        WSAPROTOCOL_LEN = 255,
        MAX_PROTOCOL_CHAIN = 7,
        WSA_FLAG_OVERLAPPED = 1,
        SOMAXCONN = 0x7fffffff,
        FD_ACCEPT_BIT = 3,
        FD_ACCEPT = 1 << FD_ACCEPT_BIT,
        FD_CLOSE_BIT = 5,
        FD_CLOSE = 1 << FD_CLOSE_BIT,
        FD_MAX_EVENTS = 10,

        SD_RECEIVE = 0,
        SD_SEND = 1,
        SD_BOTH = 2,

        WSA_INVALID_EVENT = cast(WSAEVENT)null,
        WSA_INFINITE = INFINITE,
        WSA_WAIT_EVENT_0 = WAIT_OBJECT_0,
        WSA_WAIT_TIMEOUT = WAIT_TIMEOUT,
        WSA_IO_INCOMPLETE = ERROR_IO_INCOMPLETE,
        WSA_OPERATION_ABORTED = 995,
        WSA_IO_PENDING = 997,
        WSAEINTR = 10004,
        WSAEFAULT = 10014,
        WSAEINVAL = 10022,
        WSAEWOULDBLOCK = 10035,
        WSAEINPROGRESS = 10036,
        WSAEMSGSIZE = 10040,
        WSAEOPNOTSUPP = 10045,
        WSAENETDOWN = 10050,
        WSAENETRESET = 10052,
        WSAECONNABORTED = 10053,
        WSAECONNRESET = 10054,
        WSAENOBUFS = 10055,
        WSAENOTCONN = 10057,
        WSAESHUTDOWN = 10058,
        WSAETIMEDOUT = 10060,
        WSANOTINITIALISED = 10093,
        WSAEDISCON = 10101,

        szOID_COMMON_NAME = "2.5.4.3",
        szOID_PKCS_12_FRIENDLY_NAME_ATTR = "1.2.840.113549.1.9.20",
        szOID_SUBJECT_ALT_NAME = "2.5.29.7",
        szOID_SUBJECT_ALT_NAME2 = "2.5.29.17",
        CERT_RDN_PRINTABLE_STRING = 4,
        CERT_RDN_UNICODE_STRING = 12,
        CERT_RDN_UTF8_STRING = 13,
        CERT_FRIENDLY_NAME_PROP_ID = 11,
        CERT_NAME_RDN_TYPE = 2,
        CERT_NAME_ISSUER_FLAG = 1,
        CRYPT_ENCODE_ALLOC_FLAG = 0x8000,
        CERT_ALT_NAME_DNS_NAME = 3,

        SCHANNEL_CRED_VERSION = 4,
        SCH_CREDENTIALS_VERSION = 5,

        SECURITY_NATIVE_DREP = 0x00000010,

        ISC_REQ_REPLAY_DETECT = 0x00000004,
        ISC_REQ_SEQUENCE_DETECT = 0x00000008,
        ISC_REQ_CONFIDENTIALITY = 0x00000010,
        ISC_REQ_USE_SUPPLIED_CREDS = 0x00000080,
        ISC_REQ_ALLOCATE_MEMORY = 0x00000100,
        ISC_REQ_EXTENDED_ERROR = 0x00004000,
        ISC_REQ_STREAM = 0x00008000,
        ISC_REQ_MANUAL_CRED_VALIDATION = 0x00080000,

        ASC_REQ_DELEGATE = 1,
        ASC_REQ_MUTUAL_AUTH = 2,
        ASC_REQ_REPLAY_DETECT = 4,
        ASC_REQ_SEQUENCE_DETECT = 8,
        ASC_REQ_CONFIDENTIALITY = 16,
        ASC_REQ_USE_SESSION_KEY = 32,
        ASC_REQ_ALLOCATE_MEMORY = 256,
        ASC_REQ_USE_DCE_STYLE = 512,
        ASC_REQ_DATAGRAM = 1024,
        ASC_REQ_CONNECTION = 2048,
        ASC_REQ_EXTENDED_ERROR = 32768,
        ASC_REQ_STREAM = 65536,
        ASC_REQ_INTEGRITY = 131072,

        SP_PROT_SSL2_SERVER = 0x00000004,
        SP_PROT_SSL3_SERVER = 0x00000010,
        SP_PROT_TLS1_SERVER = 0x00000040,
        SP_PROT_TLS1_1_SERVER = 0x00000100,
        SP_PROT_TLS1_2_SERVER = 0x00000400,
        SP_PROT_TLS1_3_SERVER = 0x00001000,
        SP_PROT_DTLS1_SERVER = 0x00010000,
        SP_PROT_DTLS1_2_SERVER = 0x00040000,

        SP_PROT_SSL2_CLIENT = 0x00000008,
        SP_PROT_SSL3_CLIENT = 0x00000020,
        SP_PROT_TLS1_CLIENT = 0x00000080,
        SP_PROT_TLS1_1_CLIENT = 0x00000200,
        SP_PROT_TLS1_2_CLIENT = 0x00000800,
        SP_PROT_TLS1_3_CLIENT = 0x00002000,
        SP_PROT_DTLS1_CLIENT = 0x00020000,
        SP_PROT_DTLS1_2_CLIENT = 0x00080000,

        SCH_CRED_AUTO_CRED_VALIDATION = 0x00000020,
        SCH_CRED_MANUAL_CRED_VALIDATION = 0x00000008,
        SCH_CRED_NO_SERVERNAME_CHECK = 0x00000004,

        INVALID_HANDLE_VALUE = cast(HANDLE)-1,
        NO_ERROR = 0,
        ERROR_IO_PENDING = 997,

        AF_INET = 2,
        AF_INET6 = 23,
        IPPROTO_TCP = 6,
        IPPROTO_UDP = 41,
        SOCKET_ERROR = -1,
        INVALID_SOCKET = ~0,
        SOCK_STREAM = 1,
        SOCK_DGRAM = 2,
        SOL_SOCKET = 0xFFFF,
        SO_REUSEADDR = 0x0004,
        SO_KEEPALIVE = 0x0008,

        INADDR_ANY = 0,
        IN6ADDR_ANY = in6_addr.init,

        CERT_X500_NAME_STR = 3,
        CERT_NAME_STR_COMMA_FLAG = 0x04000000,

        NORMAL_PRIORITY_CLASS = 0x00000020,
        CREATE_UNICODE_ENVIRONMENT = 0x00000400,

        STARTF_USESTDHANDLES = 0x00000100,
        HANDLE_FLAG_INHERIT = 0x00000001,

        PIPE_READMODE_BYTE = 0x00000000,
        PIPE_NOWAIT = 0x00000001,
    }

    struct OVERLAPPED {
        ULONG_PTR Internal;
        ULONG_PTR InternalHigh;
        DWORD Offset;
        DWORD OffsetHigh;
        HANDLE hEvent;
    }

    alias LPOVERLAPPED = OVERLAPPED*;

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

    struct CERT_OTHER_NAME {
        LPSTR pszObjId;
        CRYPT_OBJID_BLOB Value;
    }

    struct CRYPT_DATA_BLOB {
        DWORD cbData;
        ubyte* pbData;
    }

    struct CERT_ALT_NAME_ENTRY {
        DWORD dwAltNameChoice;

        union {
            CERT_OTHER_NAME* pOtherName;
            LPWSTR pwszRfc822Name;
            LPWSTR pwszDNSName;
            CERT_NAME_BLOB DirectoryName;
            LPWSTR pwszURL;
            CRYPT_DATA_BLOB IPAddress;
            LPSTR pszRegisteredID;
        }
    }

    struct CERT_ALT_NAME_INFO {
        DWORD cAltEntry;
        CERT_ALT_NAME_ENTRY* rgAltEntry;
    }

    alias PFN_CRYPT_ALLOC = extern (Windows) void* function(size_t);
    alias PFN_CRYPT_FREE = extern (Windows) void function(void*);

    struct CRYPT_ENCODE_PARAM {
        DWORD cbSize;
        PFN_CRYPT_ALLOC pfnAlloc;
        PFN_CRYPT_FREE pfnFree;
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

    struct CRYPT_KEY_PROV_PARAM {
        DWORD dwParam;
        ubyte* pbData;
        DWORD cbData;
        DWORD dwFlags;
    }

    struct CRYPT_KEY_PROV_INFO {
        LPWSTR pwszContainerName;
        LPWSTR pwszProvName;
        DWORD dwProvType;
        DWORD cProvParam;
        CRYPT_KEY_PROV_PARAM* rgProvParam;
        DWORD dwKeySpec;
    }

    struct CRYPT_ALGORITHM_IDENTIFIER {
        LPSTR pszObjId;
        CRYPT_OBJID_BLOB Parameters;
    }

    struct CRYPT_OBJID_BLOB {
        DWORD cbData;
        ubyte* pbData;
    }

    struct CERT_EXTENSION {
        LPSTR pszObjId;
        bool fCritical;
        CRYPT_OBJID_BLOB Value;
    }

    struct CERT_EXTENSIONS {
        DWORD cExtension;
        CERT_EXTENSION* rgExtension;
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

    enum {
        WSADESCRIPTION_LEN = 256,
        WSASYS_STATUS_LEN = 128,
    }

    struct WSADATA {
        WORD wVersion;
        WORD wHighVersion;

        version(Win64) {
            ushort iMaxSockets;
            ushort iMaxUdpDg;
            char* lpVendorInfo;
            char[WSADESCRIPTION_LEN + 1] szDescription;
            char[WSASYS_STATUS_LEN + 1] szSystemStatus;
        } else {
            char[WSADESCRIPTION_LEN + 1] szDescription;
            char[WSASYS_STATUS_LEN + 1] szSystemStatus;
            ushort iMaxSockets;
            ushort iMaxUdpDg;
            char* lpVendorInfo;
        }
    }

    struct SECURITY_ATTRIBUTES {
        DWORD nLength;
        void* lpSecurityDescriptor;
        BOOL bInheritHandle;
    }

    union LARGE_INTEGER {
        struct {
            DWORD LowPart;
            LONG HighPart;
        }

        LONGLONG QuadPart;
    }

    struct sockaddr {
        short sa_family;
        ubyte[14] sa_data;
    }

    union in_addr {
        struct {
            ubyte s_b1;
            ubyte s_b2;
            ubyte s_b3;
            ubyte s_b4;
        }

        struct {
            ushort s_w1;
            ushort s_w2;
        }

        uint s_addr;
    }

    union in6_addr {
        ubyte[16] Byte;
        ushort[8] Word;
    }

    struct sockaddr_in {
        short sin_family;
        ushort sin_port;
        in_addr sin_addr;
        ubyte[8] sin_zero;
    }

    struct sockaddr_in6 {
        short sin6_family;
        ushort sin6_port;
        uint sin6_flowinfo;
        in6_addr sin6_addr;
        uint sin6_scope_id;
    }

    struct STARTUPINFOW {
        DWORD cb;
        LPWSTR lpReserved;
        LPWSTR lpDesktop;
        LPWSTR lpTitle;
        DWORD dwX;
        DWORD dwY;
        DWORD dwXSize;
        DWORD dwYSize;
        DWORD dwXCountChars;
        DWORD dwYCountChars;
        DWORD dwFillAttribute;
        DWORD dwFlags;
        WORD wShowWindow;
        WORD cbReserved2;
        ubyte* lpReserved2;
        HANDLE hStdInput;
        HANDLE hStdOutput;
        HANDLE hStdError;
    }

    struct PROCESS_INFORMATION {
        HANDLE hProcess;
        HANDLE hThread;
        DWORD dwProcessId;
        DWORD dwThreadId;
    }
}
