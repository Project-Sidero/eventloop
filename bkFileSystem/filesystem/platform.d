module sidero.eventloop.internal.filesystem.platform;
import sidero.eventloop.internal.filesystem.state;

version(Windows) {
    public import sidero.eventloop.internal.filesystem.windows;
} else version(Posix) {
    public import sidero.eventloop.internal.filesystem.posix;
} else {
    static assert(0, "Unimplemented");

    bool startUpFileSystemMechanism() {
        assert(0);
    }

    void shutdownFileSystemMechanism() {
        assert(0);
    }

    struct PlatformFile {
        void* handle;

        enum keepAReadAlwaysGoing = false;

    @safe nothrow @nogc:

        void initiateAConstantlyRunningReadRequest(scope FileState* fileState) {
            // keepAReadAlwaysGoing == true
            assert(0);
        }

        // NOTE: must be guarded
        void notifiedOfReadComplete(scope FileState* fileState) {
            assert(0);
        }
    }

    ErrorResult connectToSpecificFile(File file) {
        assert(0);
    }

    void forceClose(scope FileState* fileState) {
        assert(0);
    }

    bool tryWriteMechanism(scope FileState* fileState, ubyte[] buffer) {
        assert(0);
    }

    bool tryReadMechanism(scope FileState* fileState, ubyte[] buffer) {
        assert(0);
    }
}
