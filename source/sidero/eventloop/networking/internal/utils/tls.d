module sidero.eventloop.networking.internal.utils.tls;
import sidero.base.containers.dynamicarray;
import sidero.base.text;

@safe nothrow @nogc:

enum {
    TLS_HandShake_ClientHello = 1,
}

struct TLS_Packet_Info {
    ubyte contentType;
    ubyte major, minor;
    ushort length;

    ubyte handshakeType;
    uint handshakeLength;

    String_UTF8 sni;

    size_t fullMessageSize;

@safe nothrow @nogc:

    this(return scope ref TLS_Packet_Info other) scope @trusted {
        this.tupleof = other.tupleof;
    }

    this(return scope const(ubyte)[] data) scope @trusted {
        if(data.length >= 5) {
            contentType = data[0];
            major = data[1];
            minor = data[2];
            length = (data[3] << 8) | data[4];

            data = data[5 .. $];
            fullMessageSize = 5;
        }

        // we only need to recognize handshakes
        if(contentType != 0x16)
            return;

        if(data.length >= 3) {
            handshakeType = data[0];
            handshakeLength = (data[1] << 16) | (data[2] << 8) | data[3];

            data = data[4 .. $];

            fullMessageSize += 4;
            fullMessageSize += handshakeLength;
        }

        if(handshakeType == TLS_HandShake_ClientHello)
            parseClientHello(data);
    }

private:

    void parseClientHello(scope ref const(ubyte)[] data) scope @trusted {
        if(data.length < 2 + 32 + 1)
            return;

        // skip client version
        data = data[2 .. $];

        // skip random
        data = data[32 .. $];

        {
            // skip session id

            ushort sessionIdLength = data[0];
            if(data.length < sessionIdLength + 1)
                return;
            data = data[1 + sessionIdLength .. $];
        }

        {
            // skip cipher suite

            if(data.length < 2)
                return;

            ushort cipherSuiteLength = (data[0] << 8) | data[1];
            if(data.length < cipherSuiteLength + 2)
                return;
            data = data[2 + cipherSuiteLength .. $];
        }

        {
            // skip compression method

            if(data.length < 1)
                return;

            ubyte compressionMethodsLength = data[0];
            if(data.length < compressionMethodsLength + 1)
                return;
            data = data[1 + compressionMethodsLength .. $];
        }

        if(data.length < 2)
            return;

        ushort extensionsLength = (data[0] << 8) | data[1];
        if(data.length < extensionsLength + 2)
            return;
        data = data[2 .. $];

        while(data.length >= 4) {
            const extensionType = (data[0] << 8) | data[1];
            ushort length = (data[2] << 8) | data[3];

            if(data.length < length + 4)
                return;
            data = data[4 .. $];

            if(extensionType == 0x0000 && length >= 2) {
                // server names
                ushort serverNameListLength = (data[0] << 8) | data[1];
                data = data[2 .. $];
                length -= 2;

                while(serverNameListLength > 0 && data.length >= 3) {
                    const serverNameType = data[0];
                    const serverNameLength = (data[1] << 8) | data[2];
                    data = data[3 .. $];
                    length -= 3;

                    if(data.length < serverNameLength)
                        return;

                    sni = String_UTF8(cast(const(char)[])data[0 .. serverNameLength]);
                    length -= serverNameLength;
                    data = data[serverNameLength .. $];

                    // we only support one (the first)
                    break;
                }
            }

            if(length > 0)
                data = data[length .. $];
        }
    }
}

unittest {
    // from https://stackoverflow.com/a/21926971
    static const ubyte[] sampleSession = [
        0x16, // Content Type: Handshake

        0x03, 0x01, // Version: TLS 1.0
        0x00, 0x6c, // Length (use for bounds checking)
        // Handshake
        0x01, // Handshake Type: Client Hello
        0x00, 0x00, 0x68, // Length (use for bounds checking)

        0x03, 0x03, // Version: TLS 1.2
        // Random (32 bytes fixed length)
        0xb6, 0xb2, 0x6a, 0xfb, 0x55, 0x5e, 0x03, 0xd5, 0x65, 0xa3, 0x6a, 0xf0, 0x5e, 0xa5, 0x43, 0x02, 0x93, 0xb9,
        0x59, 0xa7, 0x54, 0xc3, 0xdd, 0x78, 0x57, 0x58, 0x34, 0xc5, 0x82, 0xfd, 0x53, 0xd1, 0x00, // Session ID Length (skip past this much)
        0x00, 0x04, // Cipher Suites Length (skip past this much)
        0x00, 0x01, // NULL-MD5
        0x00, 0xff, // RENEGOTIATION INFO SCSV
        0x01, // Compression Methods Length (skip past this much)
        0x00, // NULL

        0x00, 0x3b, // Extensions Length (use for bounds checking)

        // Extension
        0x00, 0x00, // Extension Type: Server Name (check extension type)
        0x00, 0x0e, // Length (use for bounds checking)
        0x00, 0x0c, // Server Name Indication Length
        0x00, // Server Name Type: host_name (check server name type)
        0x00, 0x09, // Length (length of your data)
        // "localhost" (data your after)
        0x6c, 0x6f, 0x63, 0x61, 0x6c, 0x68, 0x6f, 0x73, 0x74,

        // Extension
        0x00, 0x0d, // Extension Type: Signature Algorithms (check extension type)
        0x00, 0x20, // Length (skip past since this is the wrong extension)
        // Data
        0x00, 0x1e, 0x06, 0x01, 0x06, 0x02, 0x06, 0x03, 0x05, 0x01, 0x05, 0x02, 0x05, 0x03, 0x04, 0x01, 0x04, 0x02,
        0x04, 0x03, 0x03, 0x01, 0x03, 0x02, 0x03, 0x03, 0x02, 0x01, 0x02, 0x02, 0x02, 0x03,

        // Extension
        0x00, 0x0f, // Extension Type: Heart Beat (check extension type)
        0x00, 0x01, // Length (skip past since this is the wrong extension)
        0x01 // Mode: Peer allows to send requests
    ];

    TLS_Packet_Info tlsPacketInfo = TLS_Packet_Info(sampleSession);

    assert(tlsPacketInfo.contentType == 22);
    assert(tlsPacketInfo.major == 3);
    assert(tlsPacketInfo.minor == 1);
    assert(tlsPacketInfo.length == 108);
    assert(tlsPacketInfo.handshakeType == 1);
    assert(tlsPacketInfo.handshakeLength == 104);
    assert(tlsPacketInfo.fullMessageSize == 113);
    assert(tlsPacketInfo.sni == String_ASCII("localhost"));
}
