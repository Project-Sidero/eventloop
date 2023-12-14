module sidero.eventloop.certificates.defs;
import sidero.eventloop.handles;
import sidero.base.allocators;
import sidero.base.datetime;
import sidero.base.text;
import sidero.base.containers.readonlyslice;
import sidero.base.typecons : Optional;
import sidero.base.path.file;
import sidero.base.internal.atomic;
import sidero.base.bindings.openssl.libcrypto : X509, X509_INFO, X509_PKEY, EVP_PKEY, STACK_OF;

export @safe nothrow @nogc:

///
static immutable WinCryptCertificateHandleType = SystemHandleType.from("wictcert");

///
alias OpenSSLPasswordDelegate = uint delegate(FilePath fileToLoad, scope ubyte[] toFillIn) @safe nothrow @nogc;

///
struct Certificate {
    private {
        State* state;
    }

export @safe nothrow @nogc:

    this(scope return ref Certificate other) scope {
        this.tupleof = other.tupleof;

        if (state !is null)
            atomicIncrementAndLoad(state.refCount, 1);
    }

    ~this() scope @trusted {
        if (state !is null && atomicDecrementAndLoad(state.refCount, 1) == 0) {
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
    Type type() scope const {
        if (isNull)
            return Type.None;

        return state.type;
    }

    /// Warning: unsafe, you must handle reference counting and keeping this instance alive
    SystemHandle unsafeGetHandle() scope const @trusted {
        if (isNull)
            return SystemHandle.init;

        final switch (state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version (Windows) {
                return SystemHandle(cast(void*)state.winCryptCertificateContext, WinCryptCertificateHandleType);
            } else
                assert(0);
        case Certificate.Type.OpenSSL:
            return SystemHandle.init; // does not have a single handle to return
        }
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

        case Certificate.Type.OpenSSL:
            import sidero.base.bindings.openssl.libcrypto;

            if (state.opensslState.toUseX509 !is null) {
                EVP_PKEY* key = X509_get0_pubkey(state.opensslState.toUseX509);

                if (key !is null) {
                    BIO* outputBIO = BIO_new(BIO_s_mem());
                    scope (exit)
                        BIO_free(outputBIO);

                    PEM_write_bio_PUBKEY(outputBIO, key);

                    ubyte* outputPtr;
                    const length = BIO_get_mem_data(outputBIO, outputPtr);

                    if (length > 0) {
                        state.copiedPublicKey = Slice!ubyte(outputPtr[0 .. length]).dup;
                        return state.copiedPublicKey;
                    }
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

        case Certificate.Type.OpenSSL:
            import sidero.base.bindings.openssl.libcrypto;

            if (state.opensslState.toUseEVP_PKEY !is null) {
                BIO* outputBIO = BIO_new(BIO_s_mem());
                scope (exit)
                    BIO_free(outputBIO);

                PEM_write_bio_PKCS8PrivateKey(outputBIO, state.opensslState.toUseEVP_PKEY, null, null, 0, null, null);

                ubyte* outputPtr;
                const length = BIO_get_mem_data(outputBIO, outputPtr);

                if (length > 0) {
                    state.copiedPrivateKey = Slice!ubyte(outputPtr[0 .. length]).dup;
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

        case Certificate.Type.OpenSSL:
            import sidero.base.bindings.openssl.libcrypto;

            if (state.opensslState.toUseX509 !is null) {
                const(ASN1_TIME)* notBefore = X509_get0_notBefore(state.opensslState.toUseX509);

                char* notBeforeZ;
                int notBeforeError = ASN1_STRING_to_UTF8(notBeforeZ, notBefore);
                assert(notBeforeError >= 0);

                auto got = parseRFC5280(String_UTF8(notBeforeZ[0 .. notBeforeError]));
                OPENSSL_free(notBeforeZ);

                if (got)
                    return got.get;
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

        case Certificate.Type.OpenSSL:
            import sidero.base.bindings.openssl.libcrypto;

            if (state.opensslState.toUseX509 !is null) {
                const(ASN1_TIME)* notAfter = X509_get0_notAfter(state.opensslState.toUseX509);

                char* notAfterZ;
                int notAfterError = ASN1_STRING_to_UTF8(notAfterZ, notAfter);
                assert(notAfterError >= 0);

                auto got = parseRFC5280(String_UTF8(notAfterZ[0 .. notAfterError]));
                OPENSSL_free(notAfterZ);

                if (got)
                    return got.get;
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

        case Certificate.Type.OpenSSL:
            return typeof(return).init; // PEM file format does not stores PKCS #8 tags
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

        case Certificate.Type.OpenSSL:
            import sidero.base.bindings.openssl.libcrypto;

            if (state.opensslState.toUseX509 !is null) {
                X509_NAME* names = X509_get_issuer_name(state.opensslState.toUseX509);

                foreach (i; 0 .. X509_NAME_entry_count(names)) {
                    X509_NAME_ENTRY* nameEntry = X509_NAME_get_entry(names, i);

                    ASN1_OBJECT* nameEntryObject = X509_NAME_ENTRY_get_object(nameEntry);
                    if (OBJ_obj2nid(nameEntryObject) != NID_commonName)
                        continue;

                    ASN1_STRING* nameEntryASN1 = X509_NAME_ENTRY_get_data(nameEntry);

                    char* nameZ;
                    int nameError = ASN1_STRING_to_UTF8(nameZ, nameEntryASN1);
                    assert(nameError >= 0);

                    scope (exit)
                        OPENSSL_free(nameZ);

                    state.copiedIssuedTo = String_UTF8(nameZ[0 .. nameError]).dup;
                    return state.copiedIssuedTo;
                }
            }

            return typeof(return).init;
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

        case Certificate.Type.OpenSSL:
            import sidero.base.bindings.openssl.libcrypto;

            if (state.opensslState.toUseX509 !is null) {
                X509_NAME* names = X509_get_subject_name(state.opensslState.toUseX509);

                foreach (i; 0 .. X509_NAME_entry_count(names)) {
                    X509_NAME_ENTRY* nameEntry = X509_NAME_get_entry(names, i);

                    ASN1_OBJECT* nameEntryObject = X509_NAME_ENTRY_get_object(nameEntry);
                    if (OBJ_obj2nid(nameEntryObject) != NID_commonName)
                        continue;

                    ASN1_STRING* nameEntryASN1 = X509_NAME_ENTRY_get_data(nameEntry);

                    char* nameZ;
                    int nameError = ASN1_STRING_to_UTF8(nameZ, nameEntryASN1);
                    assert(nameError >= 0);

                    scope (exit)
                        OPENSSL_free(nameZ);

                    state.copiedIssuedTo = String_UTF8(nameZ[0 .. nameError]).dup;
                    return state.copiedIssuedTo;
                }
            }

            return typeof(return).init;
        }
    }

    ///
    void unsafeGetOpenSSLHandles(scope void delegate(X509* publicKey, EVP_PKEY* privateKey,
            STACK_OF!X509_INFO* chain) @system nothrow @nogc del) @system {
        if (!isNull && this.state.type == Certificate.Type.OpenSSL) {
            if (state.opensslState.toUseX509 !is null || state.opensslState.toUseEVP_PKEY !is null ||
                    state.opensslState.pemChain.certificates !is null)
                del(state.opensslState.toUseX509, state.opensslState.toUseEVP_PKEY, state.opensslState.pemChain.certificates);
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
    static Certificate loadFromWinCrypt(FilePath path, bool useX509_ASN_Encoding = true, bool usePKCS7_ASN_Encoding = true,
            return RCAllocator allocator = RCAllocator.init) @trusted {
        import sidero.base.internal.filesystem : readFile;

        version (Windows) {
            auto encodedBytes = readFile!ubyte(path);
            DWORD encodingOr = (useX509_ASN_Encoding ? X509_ASN_ENCODING : 0) | (usePKCS7_ASN_Encoding ? PKCS_7_ASN_ENCODING : 0);
            return Certificate.loadFromWinCrypt(CertCreateCertificateContext(encodingOr, encodedBytes.ptr,
                    cast(DWORD)encodedBytes.length), allocator);
        } else
            return Certificate.init;
    }

    /// File type PEM, private key may be in same file as public key, with optional chain/public key file
    static Certificate loadFromOpenSSL(FilePath keyPath, FilePath chainFilePath = FilePath.init,
            scope OpenSSLPasswordDelegate passwordDelegate = null, return RCAllocator allocator = RCAllocator.init) @trusted {
        import sidero.base.bindings.openssl.libcrypto;

        if (!keyPath.couldPointToEntry() || !loadLibCrypto())
            return Certificate.init;
        if (allocator.isNull)
            allocator = globalAllocator();

        Certificate ret;
        ret.state = allocator.make!State();
        ret.state.allocator = allocator;
        ret.state.type = Type.OpenSSL;

        BIO* bioInput, keyBIO, chainBIO;

        {
            auto keyFileName = keyPath.toString();
            bioInput = BIO_new_file(keyFileName.ptr, "r");

            if (bioInput is null)
                return Certificate.init;
        }

        if (!chainFilePath.isNull) {
            keyBIO = bioInput;
            bioInput = BIO_new(BIO_s_mem());

            int len;
            ubyte[1024] buffer;

            while ((len = BIO_read(keyBIO, buffer.ptr, cast(int)buffer.length)) > 0) {
                BIO_write(bioInput, buffer.ptr, len);
            }

            auto chainFileName = chainFilePath.toString();
            chainBIO = BIO_new_file(chainFileName.ptr, "r");

            while ((len = BIO_read(chainBIO, buffer.ptr, cast(int)buffer.length)) > 0) {
                BIO_write(bioInput, buffer.ptr, len);
            }
        }

        {
            ret.state.opensslState.loadFromPEMChain(bioInput, keyPath, passwordDelegate);

            if (keyBIO !is null) {
                BIO_free(keyBIO);
                BIO_free(chainBIO);
            }

            BIO_free(bioInput);
        }

        if (ret.state.opensslState.pemChain.numberOfCertificates > 0)
            return ret;
        else
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

        static Certificate loadFromOpenSSLObjects(X509* publicKey, EVP_PKEY* privateKey = null,
                return RCAllocator allocator = RCAllocator.init) @trusted {
            if (publicKey is null)
                return Certificate.init;

            if (allocator.isNull)
                allocator = globalAllocator();

            Certificate ret;
            ret.state = allocator.make!State();
            ret.state.allocator = allocator;

            ret.state.opensslState.toUseX509 = publicKey;
            ret.state.opensslState.toUseEVP_PKEY = privateKey;
            ret.state.opensslState.toCleanupX509 = publicKey;
            ret.state.opensslState.toCleanupEVP_PKEY = privateKey;
            return ret;
        }
    }

    ///
    enum Type {
        ///
        None,
        ///
        WinCrypt,
        ///
        OpenSSL,

        /// WinCrypt on Windows, otherwise OpenSSL
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

    OpenSSLState opensslState;

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
            version (Windows) {
                if (winCryptCertificateContext !is null)
                    CertFreeCertificateContext(winCryptCertificateContext);
            }
            break;

        case Certificate.Type.OpenSSL:
            opensslState.destroy;
            break;
        }
    }
}

struct OpenSSLState {
    import sidero.base.bindings.openssl.libcrypto;

    X509* toUseX509;
    EVP_PKEY* toUseEVP_PKEY;

    X509* toCleanupX509;
    EVP_PKEY* toCleanupEVP_PKEY;

    OpenSSLPEMChain pemChain;

export nothrow @nogc:

    @disable this(this);

    ~this() @trusted {
        if (toCleanupX509 !is null)
            X509_free(toCleanupX509);
        if (toCleanupEVP_PKEY !is null)
            EVP_PKEY_free(toCleanupEVP_PKEY);
    }

    void loadFromPEMChain(BIO* inputBIO, FilePath filePath, scope OpenSSLPasswordDelegate passwordDelegate) @trusted {
        pemChain.loadFrom(inputBIO, filePath, passwordDelegate);

        if (pemChain.numberOfCertificates > 0) {
            X509_INFO* xi = sk_X509_INFO_value(pemChain.certificates, 0);
            this.toUseX509 = xi.x509;

            if (xi.x_pkey !is null)
                this.toUseEVP_PKEY = xi.x_pkey.dec_pkey;
        }
    }
}

struct OpenSSLPEMChain {
    import sidero.base.bindings.openssl.libcrypto;

    size_t numberOfCertificates;
    STACK_OF!X509_INFO* certificates;

export nothrow @nogc:

    @disable this(this);

    ~this() @trusted {
        if (certificates is null)
            return;

        sk_X509_INFO_pop_free(certificates, cast(f_OPENSSL_sk_pop_free_freefunc)X509_INFO_free);

        certificates = null;
        numberOfCertificates = 0;
    }

    void loadFrom(BIO* inputBIO, FilePath filePath, scope OpenSSLPasswordDelegate passwordDelegate) @trusted {
        //https://stackoverflow.com/a/60123583
        //https://cpp.hotexamples.com/examples/-/-/sk_X509_INFO_value/cpp-sk_x509_info_value-function-examples.html

        static struct PasswordContext {
            FilePath filePath;
            OpenSSLPasswordDelegate passwordDelegate;

        nothrow @nogc:

            static extern (C) int handle(ubyte* buf, int size, int rwflag, void* userdata) {
                PasswordContext* self = cast(PasswordContext*)userdata;

                if (self.passwordDelegate !is null) {
                    return self.passwordDelegate(self.filePath, buf[0 .. size]);
                }

                return 0;
            }
        }

        PasswordContext passwordContext = PasswordContext(filePath, passwordDelegate);

        certificates = PEM_X509_INFO_read_bio(inputBIO, null, &PasswordContext.handle, cast(void*)&passwordContext);
        if (certificates is null)
            return;

        numberOfCertificates = sk_X509_INFO_num(certificates);

        if (numberOfCertificates == 0)
            this.destroy;
    }
}
