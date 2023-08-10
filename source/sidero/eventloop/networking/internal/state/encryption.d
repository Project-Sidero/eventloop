module sidero.eventloop.networking.internal.state.encryption;
import sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.certificates;
import sidero.base.path.hostname;
import sidero.base.containers.readonlyslice;

struct EncryptionState {
    bool enabled;
    bool negotiating;

    @safe nothrow @nogc:

    size_t amountOfBytesToRead() {
        return 0;
    }

    bool addEncryption(scope SocketState* socketState, Hostname sniHostname, Certificate certificate, Socket.EncryptionProtocol protocol,
        bool validateCertificates, Slice!Certificate sniCertificates = Slice!Certificate.init) scope @trusted {
        assert(0);
    }

    bool negotiate(scope SocketState* socketState) scope {
        assert(0);
    }

    bool encryptDecrypt(scope SocketState* socketState) scope {
        assert(0);
    }

    void cleanup() scope {
        assert(0);
    }
}
