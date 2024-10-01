module sidero.eventloop.internal.filesystem.defs;
import sidero.base.synchronization.mutualexclusion;
import sidero.base.logger;
import sidero.base.text;

@safe nothrow @nogc:

package(sidero.eventloop.internal.filesystem) {
    __gshared {
        TestTestSetLockInline initLock;
        LoggerReference logger;
    }

    void checkInit() @trusted {
        initLock.pureLock;

        if(!logger || logger.isNull) {
            logger = Logger.forName(String_UTF8(__MODULE__));
            assert(logger);
        }

        initLock.unlock;
    }
}
