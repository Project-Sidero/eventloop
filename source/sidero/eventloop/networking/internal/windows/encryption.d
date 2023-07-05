module sidero.eventloop.networking.internal.windows.encryption;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.certificates;

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;

    struct EncryptionStateWinCrypt {
        private {
            static immutable SecurityPackageName = "Schannel"w;
            // TODO: Schannel
            // SCHANNEL_CRED
            // CredHandle
        }

    @safe nothrow @nogc:

        void cleanup() scope {

        }

        bool add(scope SocketState* socketState, Certificate certificate, Socket.EncryptionProtocol protocol) scope {
            return false;
        }

        bool replace(scope SocketState* socketState, Certificate certificate, Socket.EncryptionProtocol protocol) scope {
            return false;
        }

        void configure(scope SocketState* socketState) scope @trusted {
            // placeholder, gotta find a better place later

            {
                // handle getting of the buffer size needed
                SecPkgInfoW* spi;

                QuerySecurityPackageInfoW(cast(wchar*)SecurityPackageName.ptr, &spi);

                socketState.encryptionState.bufferSize = spi.cbMaxToken;
                FreeContextBuffer(spi);
            }
        }
    }
}
