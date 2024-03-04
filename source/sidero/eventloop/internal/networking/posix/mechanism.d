module sidero.eventloop.internal.networking.posix.mechanism;
import sidero.base.logger;
import sidero.base.text;

__gshared {
    package(sidero.eventloop.internal.networking.posix) {
        LoggerReference logger;
    }
}

@safe nothrow @nogc:

bool startUpNetworkingMechanism() @trusted {
    version (Posix) {
        logger = Logger.forName(String_UTF8(__MODULE__));
        if (!logger)
            return false;
        return true;
    } else
        assert(0);
}

void shutdownNetworkingMechanism() {
}
