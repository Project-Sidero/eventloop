module sidero.eventloop.synchronization.systemlock;
import sidero.eventloop.handles;
import sidero.base.datetime.duration;
import sidero.base.errors;

///
enum MutexHandleIdentifier = SystemHandleType.from("mutex");

/// Recursive mutex
struct SystemLock {
    private {
        import sidero.base.synchronization.mutualexclusion : TestTestSetLockInline;

        TestTestSetLockInline protectMutex;
        bool initialized;

        version (Windows) {
            import core.sys.windows.windows : CreateMutex, HANDLE, CloseHandle, WaitForSingleObject, INFINITE,
                WAIT_OBJECT_0, WAIT_ABANDONED, WAIT_FAILED, WAIT_TIMEOUT, ReleaseMutex;

            HANDLE mutex;

            void setup() scope @trusted nothrow @nogc {
                protectMutex.pureLock;

                if (!initialized) {
                    mutex = CreateMutex(null, false, null);
                    assert(mutex !is null);
                    initialized = true;
                }

                protectMutex.unlock;
            }
        } else version (Posix) {
            import core.sys.posix.pthread : pthread_mutex_t, pthread_mutex_init, pthread_mutex_destroy,
                pthread_mutex_lock, pthread_mutex_unlock, pthread_mutex_trylock, pthread_mutexattr_t,
                pthread_mutexattr_settype, PTHREAD_MUTEX_RECURSIVE,
                pthread_mutexattr_setrobust, PTHREAD_MUTEX_ROBUST, pthread_mutex_consistent, EOWNERDEAD, EAGAIN, ENOTRECOVERABLE, EBUSY;

            pthread_mutex_t mutex;

            void setup() scope @trusted nothrow @nogc {
                protectMutex.pureLock;

                if (!initialized) {
                    pthread_mutexattr_t attr;
                    auto result = pthread_attr_init(&attr);
                    assert(result == 0);

                    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
                    pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST);

                    pthread_mutex_init(&mutex, &attr);
                    pthread_attr_destroy(&attr);
                    initialized = true;
                }

                protectMutex.unlock;
            }
        } else
            static assert(0, "Unimplemented platform");
    }

export @safe nothrow @nogc:
    @disable this(this);

    /// Warning: unsafe, you must handle reference counting and keeping this instance alive
    SystemHandle unsafeGetHandle() @system {
        setup;
        return SystemHandle(mutex, MutexHandleIdentifier);
    }

    ///
    ~this() scope @trusted {
        if (initialized) {
            version (Windows) {
                CloseHandle(mutex);
            } else version (Posix) {
                pthread_mutex_destroy(&mutex);
            } else
                static assert(0, "Unimplemented platform");
        }
    }

    ///
    ErrorResult lock(Duration timeout = Duration.max) scope @trusted {
        if (timeout <= Duration.init)
            return ErrorResult(MalformedInputException("Timeout duration must be above zero"));

        setup;

        version (Windows) {
            auto result = WaitForSingleObject(mutex, timeout < Duration.max ? cast(uint)timeout.totalMilliSeconds() : INFINITE);

            switch (result) {
            case WAIT_OBJECT_0:
            case WAIT_ABANDONED:
                return ErrorResult.init;

            case WAIT_FAILED:
            default:
                return ErrorResult(UnknownPlatformBehaviorException("Could not lock mutex"));
            }
        } else version (Posix) {
            import core.sys.posix.pthread : pthread_timedjoin_np;
            import core.sys.posix.time : clock_gettime, CLOCK_REALTIME;
            import core.stdc.time : timespec;

            int result;

            if (timeout < Duration.max) {
                long secs = timeout.totalSeconds();
                long nsecs = (timeout - secs.seconds()).totalNanoSeconds();

                timespec ts;
                if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
                    return ErrorResult(UnknownPlatformBehaviorException("Could not get time to compute timeout for thread join"));

                ts.tv_sec += secs;
                ts.tv_nsec += nsecs;

                result = pthread_mutex_timedlock(&mutex, ts);
            } else {
                result = pthread_mutex_lock(&mutex);
            }

            switch (result) {
            case 0:
                return ErrorResult.init;

            case EOWNERDEAD:
                pthread_mutex_consistent(&mutex);
                return ErrorResult.init;

            case EINVAL:
                return ErrorResult(MalformedInputException("Timeout duration out of range"));

            case EAGAIN:
            case ENOTRECOVERABLE:
            default:
                return ErrorResult(UnknownPlatformBehaviorException("Could not lock mutex"));
            }
        } else
            static assert(0, "Unimplemented platform");
    }

    ///
    Result!bool tryLock() scope @trusted {
        setup;

        version (Windows) {
            auto result = WaitForSingleObject(mutex, 0);

            switch (result) {
            case WAIT_OBJECT_0:
            case WAIT_ABANDONED:
                return typeof(return)(true);

            case WAIT_TIMEOUT:
                return typeof(return)(false);

            case WAIT_FAILED:
            default:
                return typeof(return)(UnknownPlatformBehaviorException("Could not lock mutex"));
            }
        } else version (Posix) {
            auto result = pthread_mutex_trylock(&mutex);

            switch (result) {
            case 0:
                return typeof(return)(true);

            case EOWNERDEAD:
                pthread_mutex_consistent(&mutex);
                return typeof(return)(true);

            case EBUSY:
                return typeof(return)(false);

            case EAGAIN:
            case ENOTRECOVERABLE:
            default:
                return typeof(return)(UnknownPlatformBehaviorException("Could not lock mutex"));
            }
        } else
            static assert(0, "Unimplemented platform");
    }

    ///
    void unlock() scope @trusted {
        setup;

        version (Windows) {
            ReleaseMutex(mutex);
        } else version (Posix) {
            pthread_mutex_unlock(&mutex);
        } else
            static assert(0, "Unimplemented platform");
    }
}
