module sidero.eventloop.networking.internal.windows.encryption.state;
import sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.certificates;
import sidero.eventloop.networking.sockets;
import sidero.base.path.hostname;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;

struct EncryptionStateWinCrypt {
    version(Windows) {

    }

@safe nothrow @nogc:

    bool add(scope SocketState* socketState, Hostname sniHostname, Certificate certificate,
            Socket.EncryptionProtocol protocol, bool validateCertificates, Slice!Certificate sniCertificates) scope @trusted {
        version(Windows) {
            assert(0);
        } else
            assert(0);
    }

    Slice!ubyte encrypt(scope SocketState* socketState, return scope Slice!ubyte decrypted) scope {
        version(Windows) {
            assert(0);
        } else
            assert(0);
    }

    Slice!ubyte decrypt(scope SocketState* socketState, return scope DynamicArray!ubyte encrypted, out size_t consumed) scope {
        version(Windows) {
            assert(0);
        } else
            assert(0);
    }

    bool negotiate(scope SocketState* socketState) scope {
        version(Windows) {
            assert(0);
        } else
            assert(0);
    }

    void cleanup(scope SocketState* socketState) scope {
        version(Windows) {
            assert(0);
        } else
            assert(0);
    }
}
