module sidero.eventloop.certificates.selfsign;
import sidero.eventloop.certificates.defs;
import sidero.base.text;
import sidero.base.errors;
import sidero.base.datetime.duration;
import sidero.base.path.hostname;

Result!Certificate createSelfSigned(uint keySizeInBits, Duration validDuration, Hostname hostName = Hostname.init,
        String_UTF8 countryName = String_UTF8.init, String_UTF8 commonName = String_UTF8.init,
        String_UTF8 organizationName = String_UTF8.init, int serialNumber = 1) {
    return createSelfSigned(Certificate.Type.Default, keySizeInBits, validDuration, hostName, countryName, commonName,
            organizationName, serialNumber);
}

Result!Certificate createSelfSigned(Certificate.Type type, uint keySizeInBits, Duration validDuration,
        Hostname hostName = Hostname.init, String_UTF8 countryName = String_UTF8.init,
        String_UTF8 commonName = String_UTF8.init, String_UTF8 organizationName = String_UTF8.init, int serialNumber = 1) {
    final switch (type) {
    case Certificate.Type.None:
        return typeof(return)(MalformedInputException("You must specific a certificate type that is not None"));

    case Certificate.Type.Default:
        version (Windows) {
            goto case Certificate.Type.WinCrypt;
        } else {
            goto case Certificate.Type.OpenSSL;
        }

    case Certificate.Type.WinCrypt:
        version (Windows) {
            assert(0);
        } else
            return typeof(return)(MalformedInputException("WinCrypt is only supported on Windows"));

    case Certificate.Type.OpenSSL:
        return buildOpenSSL3(keySizeInBits, validDuration, hostName, countryName, commonName,
                organizationName, serialNumber);
    }
}

private:

Result!Certificate buildOpenSSL3(uint keySizeInBits, Duration validDuration, Hostname hostName = Hostname.init,
        String_UTF8 countryName = String_UTF8.init, String_UTF8 commonName = String_UTF8.init,
        String_UTF8 organizationName = String_UTF8.init, int serialNumber = 1) {
    import sidero.base.bindings.openssl.libcrypto;
    import core.stdc.config : c_long;

    {
        auto error = loadLibCrypto();
        if (!error)
            return typeof(return)(error.getError());
    }

    X509* certificate;
    EVP_PKEY* keyPair;

    // openssl < 3
    BIGNUM* bigNumber;

    scope (exit) {
        if (certificate !is null)
            X509_free(certificate);
        if (bigNumber !is null)
            BN_free(bigNumber);
    }

    {
        certificate = X509_new_ex(null, null);
        if (certificate is null)
            return typeof(return)(NullPointerException("Could not allocate an OpenSSL X509 object"));

        if (X509_set_version(certificate, X509_VERSION_3) != 1)
            return typeof(return)(UnknownPlatformBehaviorException("Could not set OpenSSL X509 object version"));

        {
            ASN1_INTEGER* serialNumberPtr = X509_get_serialNumber(certificate);
            if (serialNumberPtr is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not acquire OpenSSL X509 object serial"));

            if (ASN1_INTEGER_set(serialNumberPtr, serialNumber) != 1)
                return typeof(return)(UnknownPlatformBehaviorException("Could not set serial number for OpenSSL X509 object"));
        }

        {
            if (validDuration < 1.hour)
                validDuration = 1.day;

            long seconds = validDuration.totalSeconds;
            if (seconds > int.max)
                seconds = int.max;

            ASN1_TIME* notBefore = X509_getm_notBefore(certificate), notAfter = X509_getm_notAfter(certificate);

            if (notBefore is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not get available on for OpenSSL X509 object"));
            else if (notAfter is null)
                return typeof(return)(UnknownPlatformBehaviorException(
                        "Could not get when certificate is not available for OpenSSL X509 object"));

            if (X509_gmtime_adj(notBefore, 0) is null)
                return typeof(return)(UnknownPlatformBehaviorException(
                        "Could not set when certificate is available on for OpenSSL X509 object"));
            else if (X509_gmtime_adj(notAfter, cast(c_long)seconds) is null)
                return typeof(return)(UnknownPlatformBehaviorException(
                        "Could not set when certificate is not available for OpenSSL X509 object"));
        }

        {
            X509_NAME* name = X509_get_subject_name(certificate);
            if (name is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not get certificate name for OpenSSL X509 object"));

            if (!countryName.isNull) {
                if (!countryName.isPtrNullTerminated)
                    countryName = countryName.dup;

                if (X509_NAME_add_entry_by_txt(name, "C".ptr, MBSTRING_UTF8, cast(const(ubyte)*)countryName.ptr,
                        cast(int)countryName.length, -1, 0) != 1)
                    return typeof(return)(
                            UnknownPlatformBehaviorException("Could not set certificate country name for OpenSSL X509 object"));
            }

            if (!commonName.isNull) {
                if (!commonName.isPtrNullTerminated)
                    commonName = commonName.dup;

                if (X509_NAME_add_entry_by_txt(name, "CN".ptr, MBSTRING_UTF8, cast(const(ubyte)*)commonName.ptr,
                        cast(int)commonName.length, -1, 0) != 1)
                    return typeof(return)(UnknownPlatformBehaviorException("Could not set certificate common name for OpenSSL X509 object"));
            }

            if (!organizationName.isNull) {
                if (!organizationName.isPtrNullTerminated)
                    organizationName = organizationName.dup;

                if (X509_NAME_add_entry_by_txt(name, "CN".ptr, MBSTRING_UTF8, cast(const(ubyte)*)organizationName.ptr,
                        cast(int)organizationName.length, -1, 0) != 1)
                    return typeof(return)(UnknownPlatformBehaviorException(
                            "Could not set certificate organization name for OpenSSL X509 object"));
            }

            if (X509_set_issuer_name(certificate, name) != 1)
                return typeof(return)(UnknownPlatformBehaviorException("Could not set certificate issuer name for OpenSSL X509 object"));
        }

        if (!hostName.isNull) {
            auto hostNameBuilder = hostName.toString().asMutable();
            hostNameBuilder.prepend("DNS:");
            auto hostNameFinal = hostNameBuilder.asReadOnly;

            ASN1_OCTET_STRING* extData = ASN1_STRING_type_new(V_ASN1_OCTET_STRING);
            if (extData is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not create DNS name for OpenSSL ASN1 string"));
            if (ASN1_STRING_set(extData, hostNameFinal.ptr, cast(int)hostNameFinal.length) != 1)
                return typeof(return)(UnknownPlatformBehaviorException("Could not assign hostname to OpenSSL ASN1 string"));

            X509_EXTENSION* extension = X509_EXTENSION_create_by_NID(null, NID_subject_alt_name, 0, extData);
            ASN1_STRING_free(extData);

            if (extension is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not create alternative name for OpenSSL X509 object"));

            if (X509_add_ext(certificate, extension, -1) != 1) {
                X509_EXTENSION_free(extension);
                return typeof(return)(UnknownPlatformBehaviorException("Could not add subject alternative name for OpenSSL X509 object"));
            }

            X509_EXTENSION_free(extension);
        }
    }

    {
        if (EVP_PKEY_Q_keygen !is null) {
            keyPair = EVP_PKEY_Q_keygen(null, null, "RSA", cast(size_t)keySizeInBits);
            if (keyPair is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not create OpenSSL RSA Q key pair"));
        } else if (EVP_RSA_gen !is null) {
            // OpenSSL >= 3
            keyPair = EVP_RSA_gen(keySizeInBits);
            if (keyPair is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not create OpenSSL RSA key pair"));
        } else if (RSA_generate_key_ex !is null && EVP_PKEY_assign_RSA !is null) {
            // OpenSSL < 3

            bigNumber = BN_new();
            if (bigNumber is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not create OpenSSL big number"));

            if (BN_set_word(bigNumber, RSA_F4) != 1)
                return typeof(return)(UnknownPlatformBehaviorException("Could not set OpenSSL big number"));

            RSA* rsa = RSA_new();
            if (rsa is null)
                return typeof(return)(UnknownPlatformBehaviorException("Could not create OpenSSL RSA"));

            if (RSA_generate_key_ex(rsa, keySizeInBits, bigNumber, null) != 1)
                return typeof(return)(UnknownPlatformBehaviorException("Could not generate OpenSSL RSA key pair"));

            keyPair = EVP_PKEY_new();
            if (keyPair is null) {
                RSA_free(rsa);
                return typeof(return)(UnknownPlatformBehaviorException("Could not create OpenSSL EVP_PKEY"));
            }

            EVP_PKEY_assign_RSA(keyPair, rsa);
            RSA_free(rsa);
        } else
            return typeof(return)(UnknownPlatformBehaviorException("Unknown method to generate EVP_PKEY"));

        if (X509_set_pubkey(certificate, keyPair) != 1)
            return typeof(return)(UnknownPlatformBehaviorException("Could not copy OpenSSL private key to public key"));

        // NOTE: we use sha1 for the hash because it'll be faster than the alternatives and the problems it can bring don't matter for self signed
        if (X509_sign(certificate, keyPair, EVP_sha1()) < 1)
            return typeof(return)(UnknownPlatformBehaviorException("Could not sign OpenSSL X509 certificate"));
    }

    {
        auto x509Cert = certificate;
        certificate = null;

        EVP_PKEY_up_ref(keyPair);
        return typeof(return)(Certificate.loadFromOpenSSLObjects(x509Cert, keyPair));
    }
}
