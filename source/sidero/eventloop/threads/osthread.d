module sidero.eventloop.threads.osthread;
import sidero.eventloop.handles;

struct Thread {
    private {
        State* state;
    }

    enum Stage {
        Inactive,
        Suspended,
        Running,
    }

private:
    static struct State {
        shared(ptrdiff_t) refCount;
        SystemHandle handle;

        ExternalThreadRegistration threadRegistration;
    }
}

private:
import sidero.eventloop.threads.registration;
import sidero.base.allocators.predefined;
import sidero.base.parallelism.rwmutex;

__gshared {
    ReaderWriterLockInline rwlock;
    Thread* threadLL;
    HouseKeepingAllocator!() threadAllocator;
}
