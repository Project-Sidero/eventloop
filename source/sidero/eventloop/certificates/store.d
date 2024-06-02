module sidero.eventloop.certificates.store;
import sidero.eventloop.certificates.defs;
import sidero.base.allocators;
import sidero.base.text;
import sidero.base.containers.dynamicarray;
import sidero.base.internal.atomic;

export @safe nothrow @nogc:

///
struct CertificateStore {
    private {
        import sidero.base.internal.meta : OpApplyCombos;

        State* state;

        int opApplyImpl(Del)(scope Del del) @trusted scope {
            if(isNull)
                return 0;

            int ret;

            final switch(state.type) {
            case Certificate.Type.None:
            case Certificate.Type.Default:
                assert(0);

            case Certificate.Type.WinCrypt:
                version(Windows) {
                    PCCERT_CONTEXT certificateContext;
                    while((certificateContext = CertEnumCertificatesInStore(state.winCryptCertificateStore, certificateContext)) !is null) {
                        auto context2 = CertDuplicateCertificateContext(certificateContext);
                        auto certificate = Certificate.loadFromWinCrypt(context2);

                        if(certificate.isNull) {
                            if(context2 !is null)
                                CertFreeCertificateContext(context2);
                        } else
                            ret = del(certificate);

                        if(ret)
                            break;
                    }
                }
                break;

            case Certificate.Type.OpenSSL:
                break; // OpenSSL does not provide a keychain
            }

            return ret;
        }
    }

export:

    ///
    mixin OpApplyCombos!(Certificate, void, "opApply", true, true, true, false, false);

@safe nothrow @nogc:

    this(scope return ref CertificateStore other) scope {
        this.tupleof = other.tupleof;

        if(state !is null)
            atomicIncrementAndLoad(state.refCount, 1);
    }

    ~this() scope @trusted {
        if(state !is null && atomicDecrementAndLoad(state.refCount, 1) == 0) {
            state.cleanup;
            RCAllocator allocator = state.allocator;
            allocator.dispose(state);
        }
    }

    ///
    bool isNull() scope {
        return state is null;
    }

    ///
    Certificate.Type type() scope {
        if(isNull)
            return Certificate.Type.None;
        else
            return state.type;
    }

    ///
    DynamicArray!Certificate byFriendlyName(String_UTF8 friendlyName, return RCAllocator allocator = RCAllocator.init) scope @trusted {
        if(isNull)
            return typeof(return).init;

        DynamicArray!Certificate ret = DynamicArray!Certificate(allocator);

        final switch(state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version(Windows) {
                PCCERT_CONTEXT certificateContext;
                while((certificateContext = CertEnumCertificatesInStore(state.winCryptCertificateStore, certificateContext)) !is null) {
                    void[128] buffer = void;
                    DWORD bufferUsed = buffer.length;

                    if(CertGetCertificateContextProperty(certificateContext, CERT_FRIENDLY_NAME_PROP_ID, buffer.ptr, &bufferUsed)) {
                        if(bufferUsed > 1)
                            bufferUsed -= 2;
                        if(bufferUsed < 2 || !String_UTF16(cast(wstring)buffer[0 .. bufferUsed]).contains(friendlyName))
                            continue;

                        auto context2 = CertDuplicateCertificateContext(certificateContext);
                        auto certificate = Certificate.loadFromWinCrypt(context2);

                        if(certificate.isNull) {
                            if(context2 !is null)
                                CertFreeCertificateContext(context2);
                        } else
                            ret ~= certificate;
                    }
                }
            }
            break;

        case Certificate.Type.OpenSSL:
            break; // OpenSSL does not provide a keychain
        }

        return ret;
    }

    ///
    DynamicArray!Certificate byFriendlyName(String_UTF16 friendlyName, return RCAllocator allocator = RCAllocator.init) scope {
        return byIssuedTo(friendlyName.byUTF8, allocator);
    }

    ///
    DynamicArray!Certificate byFriendlyName(String_UTF32 friendlyName, return RCAllocator allocator = RCAllocator.init) scope {
        return byIssuedTo(friendlyName.byUTF8, allocator);
    }

    ///
    DynamicArray!Certificate byIssuer(String_UTF8 issuer, return RCAllocator allocator = RCAllocator.init) scope @trusted {
        if(isNull)
            return typeof(return).init;

        DynamicArray!Certificate ret = DynamicArray!Certificate(allocator);

        final switch(state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version(Windows) {
                String_UTF16 toSearchFor = issuer.byUTF16;
                if(!toSearchFor.isPtrNullTerminated)
                    toSearchFor = toSearchFor.dup;

                PCCERT_CONTEXT certificateContext;
                while((certificateContext = CertFindCertificateInStore(state.winCryptCertificateStore,
                        X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, 0, CERT_FIND_ISSUER_STR_W, toSearchFor.ptr, certificateContext)) !is null) {
                    auto context2 = CertDuplicateCertificateContext(certificateContext);
                    auto certificate = Certificate.loadFromWinCrypt(context2);

                    if(certificate.isNull) {
                        if(context2 !is null)
                            CertFreeCertificateContext(context2);
                    } else
                        ret ~= certificate;
                }
            }
            break;

        case Certificate.Type.OpenSSL:
            break; // OpenSSL does not provide a keychain
        }

        return ret;
    }

    ///
    DynamicArray!Certificate byIssuer(String_UTF16 issuer, return RCAllocator allocator = RCAllocator.init) scope {
        return byIssuedTo(issuer.byUTF8, allocator);
    }

    ///
    DynamicArray!Certificate byIssuer(String_UTF32 issuer, return RCAllocator allocator = RCAllocator.init) scope {
        return byIssuedTo(issuer.byUTF8, allocator);
    }

    ///
    DynamicArray!Certificate byIssuedTo(String_UTF8 issuedTo, return RCAllocator allocator = RCAllocator.init) scope @trusted {
        if(isNull)
            return typeof(return).init;

        DynamicArray!Certificate ret = DynamicArray!Certificate(allocator);

        final switch(state.type) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);

        case Certificate.Type.WinCrypt:
            version(Windows) {
                String_UTF16 toSearchFor = issuedTo.byUTF16;
                if(!toSearchFor.isPtrNullTerminated)
                    toSearchFor = toSearchFor.dup;

                PCCERT_CONTEXT certificateContext;
                while((certificateContext = CertFindCertificateInStore(state.winCryptCertificateStore,
                        X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, 0, CERT_FIND_SUBJECT_STR_W, toSearchFor.ptr, certificateContext)) !is null) {
                    auto context2 = CertDuplicateCertificateContext(certificateContext);
                    auto certificate = Certificate.loadFromWinCrypt(context2);

                    if(certificate.isNull) {
                        if(context2 !is null)
                            CertFreeCertificateContext(context2);
                    } else
                        ret ~= certificate;
                }
            }
            break;

        case Certificate.Type.OpenSSL:
            break; // OpenSSL does not provide a keychain
        }

        return ret;
    }

    ///
    DynamicArray!Certificate byIssuedTo(String_UTF16 issuedTo, return RCAllocator allocator = RCAllocator.init) scope {
        return byIssuedTo(issuedTo.byUTF8, allocator);
    }

    ///
    DynamicArray!Certificate byIssuedTo(String_UTF32 issuedTo, return RCAllocator allocator = RCAllocator.init) scope {
        return byIssuedTo(issuedTo.byUTF8, allocator);
    }

    ///
    static CertificateStore from(Certificate.Type type = Certificate.Type.Default, return RCAllocator allocator = RCAllocator.init) {
        if(allocator.isNull)
            allocator = globalAllocator();

        if(type == Certificate.Type.Default) {
            version(Windows) {
                type = Certificate.Type.WinCrypt;
            } else
                type = Certificate.Type.None;
        }

        version(Windows) {
        } else {
            if(type == Certificate.Type.WinCrypt)
                type = Certificate.Type.None;
        }

        if(type == Certificate.Type.None)
            return CertificateStore.init;

        CertificateStore ret;
        ret.state = allocator.make!State;
        ret.state.allocator = allocator;
        ret.state.type = type;

        final switch(type) {
        case Certificate.Type.WinCrypt:
            if(!ret.state.loadWinCrypt(WinCryptStore.Personal))
                return CertificateStore.init;
            break;

        case Certificate.Type.OpenSSL:
            break; // OpenSSL does not provide a keychain

        case Certificate.Type.Default:
        case Certificate.Type.None:
            assert(0);
        }

        return ret;
    }

    ///
    static CertificateStore from(WinCryptStore store, return RCAllocator allocator = RCAllocator.init) {
        if(allocator.isNull)
            allocator = globalAllocator();

        version(Windows) {
            CertificateStore ret;
            ret.state = allocator.make!State;
            ret.state.allocator = allocator;
            ret.state.type = Certificate.Type.WinCrypt;

            if(ret.state.loadWinCrypt(store))
                return ret;
        }

        return CertificateStore.init;
    }

    /// Default: is Personal
    enum WinCryptStore {
        ///
        CertificateAuthority,
        ///
        Personal,
        ///
        Root,
        ///
        SoftwarePublisherCertificate,
    }
}

private:
import sidero.eventloop.internal.windows.bindings;

struct State {
    shared(ptrdiff_t) refCount = 1;
    RCAllocator allocator;

    Certificate.Type type;

    version(Windows) {
        HCERTSTORE winCryptCertificateStore;
    }

@safe nothrow @nogc:

    bool loadWinCrypt(CertificateStore.WinCryptStore store) @trusted {
        version(Windows) {
            winCryptCertificateStore = CertOpenSystemStoreW(0, cast(wchar*)&WinCrypt_Stores_Strings[store][0]);
            return winCryptCertificateStore !is null;
        } else
            return false;
    }

    void cleanup() @trusted {
        final switch(type) {
        case Certificate.Type.WinCrypt:
            version(Windows) {
                if(winCryptCertificateStore !is null)
                    CertCloseStore(winCryptCertificateStore, 0);
            }
            break;

        case Certificate.Type.OpenSSL:
            break; // OpenSSL does not provide a keychain

        case Certificate.Type.Default:
        case Certificate.Type.None:
            assert(0);
        }
    }
}
