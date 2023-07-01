module sidero.eventloop.certificates.defs;
import sidero.base.allocators;
import sidero.base.datetime;
import sidero.base.text;
import sidero.base.containers.readonlyslice;
import sidero.base.typecons : Optional;
import sidero.base.path.file;

export @safe nothrow @nogc:

///
struct Certificate {
    private {
        State* state;
    }

export @safe nothrow @nogc:

    this(scope return ref Certificate other) scope {
        import core.atomic : atomicOp;

        this.tupleof = other.tupleof;

        if (state !is null)
            atomicOp!"+="(state.refCount, 1);
    }

    ~this() scope @trusted {
        import core.atomic : atomicOp;

        if (state !is null && atomicOp!"-="(state.refCount, 1) == 0) {
            state.cleanup;
            RCAllocator allocator = state.allocator;
            allocator.dispose(state);
        }
    }

    ///
    bool isNull() scope const {
        return state is null;
    }

    ///
    Slice!ubyte publicKey(scope return RCAllocator allocator = RCAllocator.init) scope return @trusted {
        if (isNull)
            return typeof(return).init;

        state.mutex.pureLock;
        scope (exit)
            state.mutex.unlock;

        if (!state.copiedPublicKey.isNull)
            return state.copiedPublicKey;

        final switch (state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (state.winCryptCertificateContext !is null && state.winCryptCertificateContext.pCertInfo !is null) {
                    auto spki = &state.winCryptCertificateContext.pCertInfo.SubjectPublicKeyInfo.PublicKey;
                    state.copiedPublicKey = Slice!ubyte(spki.pbData[0 .. spki.cbData]).dup(allocator);
                    return state.copiedPublicKey;
                }
            }

            return typeof(return).init;
        }
    }

    ///
    Slice!ubyte privateKey(scope return RCAllocator allocator = RCAllocator.init) scope return @trusted {
        if (isNull)
            return typeof(return).init;

        state.mutex.pureLock;
        scope (exit)
            state.mutex.unlock;

        if (!state.copiedPrivateKey.isNull)
            return state.copiedPrivateKey;

        final switch (state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (state.winCryptCertificateContext !is null) {
                    state.copiedPrivateKey = Slice!ubyte(
                            state.winCryptCertificateContext.pbCertEncoded[0 .. state.winCryptCertificateContext.cbCertEncoded]).dup(
                            allocator);
                    return state.copiedPrivateKey;
                }
            }

            return typeof(return).init;
        }
    }

    ///
    Optional!GDateTime availableOn() scope @trusted {
        if (isNull)
            return typeof(return).init;

        final switch (state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (state.winCryptCertificateContext !is null && state.winCryptCertificateContext.pCertInfo !is null) {
                    SYSTEMTIME systemTime;
                    if (FileTimeToSystemTime(&state.winCryptCertificateContext.pCertInfo.NotBefore, &systemTime) != 0) {
                        return typeof(return)(GDateTime(GDate(systemTime.wYear, cast(ubyte)systemTime.wMonth,
                                cast(ubyte)systemTime.wDay), TimeOfDay(cast(ubyte)systemTime.wHour,
                                cast(ubyte)systemTime.wMinute, cast(ubyte)systemTime.wSecond)));
                    }
                }
            }

            return typeof(return).init;
        }
    }

    ///
    Optional!GDateTime expiresOn() scope @trusted {
        if (isNull)
            return typeof(return).init;

        final switch (state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (state.winCryptCertificateContext !is null && state.winCryptCertificateContext.pCertInfo !is null) {
                    SYSTEMTIME systemTime;
                    if (FileTimeToSystemTime(&state.winCryptCertificateContext.pCertInfo.NotAfter, &systemTime) != 0) {
                        return typeof(return)(GDateTime(GDate(systemTime.wYear, cast(ubyte)systemTime.wMonth,
                                cast(ubyte)systemTime.wDay), TimeOfDay(cast(ubyte)systemTime.wHour,
                                cast(ubyte)systemTime.wMinute, cast(ubyte)systemTime.wSecond)));
                    }
                }
            }

            return typeof(return).init;
        }
    }

    ///
    String_UTF8 friendlyName(scope return RCAllocator allocator = RCAllocator.init) scope @trusted {
        if (isNull)
            return String_UTF8.init;

        state.mutex.pureLock;
        scope (exit)
            state.mutex.unlock;

        if (!state.copiedFriendlyName.isNull)
            return state.copiedFriendlyName;

        final switch (state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (state.winCryptCertificateContext !is null) {
                    void[128] buffer = void;
                    DWORD bufferUsed = buffer.length;

                    if (CertGetCertificateContextProperty(state.winCryptCertificateContext, CERT_FRIENDLY_NAME_PROP_ID,
                            buffer.ptr, &bufferUsed)) {
                        if (bufferUsed > 1)
                            bufferUsed -= 2;
                        state.copiedFriendlyName = String_UTF8(cast(wstring)buffer[0 .. bufferUsed]).dup(allocator);
                    }

                    return state.copiedFriendlyName;
                }
            }

            return String_UTF8.init;
        }
    }

    ///
    String_UTF8 issuedBy(scope return RCAllocator allocator = RCAllocator.init) scope @trusted {
        if (isNull)
            return String_UTF8.init;

        state.mutex.pureLock;
        scope (exit)
            state.mutex.unlock;

        if (!state.copiedIssuedBy.isNull)
            return state.copiedIssuedBy;

        final switch (state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (state.winCryptCertificateContext !is null) {
                    DWORD dwStrType = CERT_SIMPLE_NAME_STR;
                    wchar[128] buffer;
                    auto converted = CertGetNameStringW(state.winCryptCertificateContext, CERT_NAME_RDN_TYPE,
                            CERT_NAME_ISSUER_FLAG, &dwStrType, buffer.ptr, cast(DWORD)buffer.length);

                    if (converted > 0)
                        converted--;

                    state.copiedIssuedBy = String_UTF8(cast(wstring)buffer[0 .. converted]).dup(allocator);
                    return state.copiedIssuedBy;
                }
            }

            return String_UTF8.init;
        }
    }

    ///
    String_UTF8 issuedTo(scope return RCAllocator allocator = RCAllocator.init) scope @trusted {
        if (isNull)
            return String_UTF8.init;

        state.mutex.pureLock;
        scope (exit)
            state.mutex.unlock;

        if (!state.copiedIssuedTo.isNull)
            return state.copiedIssuedTo;

        final switch (state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (state.winCryptCertificateContext !is null) {
                    DWORD dwStrType = CERT_SIMPLE_NAME_STR;
                    wchar[128] buffer;
                    auto converted = CertGetNameStringW(state.winCryptCertificateContext, CERT_NAME_RDN_TYPE, 0,
                            &dwStrType, buffer.ptr, cast(DWORD)buffer.length);

                    if (converted > 0)
                        converted--;

                    state.copiedIssuedTo = String_UTF8(cast(wstring)buffer[0 .. converted]).dup(allocator);
                    return state.copiedIssuedTo;
                }
            }

            return String_UTF8.init;
        }
    }

    ///
    StringBuilder_UTF8 toString() scope const @trusted {
        if (isNull)
            return StringBuilder_UTF8("null");

        Certificate* self = cast(Certificate*)&this;

        return formattedWrite("friendlyName = `{:s}`, issuedTo = `{:s}`, issuedBy = `{:s}`, " ~
                "expiresOn = `{:s}`, availableOn = `{:s}`, public key = `{:s}`, private key = `{:s}`",
                self.friendlyName, self.issuedTo, self.issuedBy, self.expiresOn, self.availableOn,
                self.publicKey.length, self.privateKey.length);
    }

    ///
    static Certificate loadFromWinCrypt(return FilePath path, bool useX509_ASN_Encoding = true,
            bool usePKCS7_ASN_Encoding = true, return RCAllocator allocator = RCAllocator.init) @trusted {
        import sidero.base.internal.filesystem : readFile;

        version (Windows) {
            auto encodedBytes = readFile!ubyte(path);
            DWORD encodingOr = (useX509_ASN_Encoding ? X509_ASN_ENCODING : 0) | (usePKCS7_ASN_Encoding ? PKCS_7_ASN_ENCODING : 0);
            return Certificate.loadFromWinCrypt(CertCreateCertificateContext(encodingOr, encodedBytes.ptr,
                    cast(DWORD)encodedBytes.length), allocator);
        } else
            return Certificate.init;
    }

    package(sidero.eventloop.certificates) {
        version (Windows) {
            static Certificate loadFromWinCrypt(scope return PCCERT_CONTEXT certificateContext,
                    return RCAllocator allocator = RCAllocator.init) @trusted {
                if (certificateContext is null)
                    return Certificate.init;

                if (allocator.isNull)
                    allocator = globalAllocator();

                Certificate ret;
                ret.state = allocator.make!State();
                ret.state.allocator = allocator;
                ret.state.type = Type.WinCrypt;
                ret.state.winCryptCertificateContext = certificateContext;

                return ret;
            }
        }
    }

    ///
    enum Type {
        ///
        None,
        ///
        WinCrypt,

        /// WinCrypt on Windows
        Default,
    }
}

private:
import sidero.eventloop.internal.windows.bindings;
import sidero.base.synchronization.mutualexclusion;

struct State {
    shared(ptrdiff_t) refCount = 1;
    RCAllocator allocator;

    TestTestSetLockInline mutex;

    Certificate.Type type;

    version (Windows) {
        PCCERT_CONTEXT winCryptCertificateContext;
    }

    Slice!ubyte copiedPublicKey;
    Slice!ubyte copiedPrivateKey;
    String_UTF8 copiedFriendlyName;
    String_UTF8 copiedIssuedBy;
    String_UTF8 copiedIssuedTo;

@safe nothrow @nogc:

    void cleanup() @trusted {
        final switch (type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            return;

        case Certificate.Type.WinCrypt:
            if (winCryptCertificateContext !is null)
                CertFreeCertificateContext(winCryptCertificateContext);
            break;
        }
    }
}
