module sidero.eventloop.threads.hook;
import sidero.eventloop.threads.registration;

version (D_BetterC) {
} else {
    import core.thread.osthread : thread_attachThis, Thread;
    import core.thread.threadbase : thread_detachThis;

    extern (C) void rt_moduleTlsCtor();
    extern (C) void rt_moduleTlsDtor();
    private __gshared int globalThreadSystemKey;

    pragma(crt_constructor) extern (C) void register_sidero_threads_register() {
        static extern (C) void onAttach() {
            thread_attachThis;
            rt_moduleTlsCtor;
        }

        static extern (C) void onDetach() {
            thread_detachThis;
            rt_moduleTlsDtor;
        }

        static extern (C) bool isRegistered() {
            return Thread.getThis() !is null;
        }

        registerThreadRegistration(&globalThreadSystemKey, &onAttach, &onDetach, &isRegistered);
    }

    pragma(crt_destructor) extern (C) void register_sidero_threads_deregister() {
        deregisterThreadRegistration(&globalThreadSystemKey);
    }

    static this() {
        attachThisThread;
    }

    static ~this() {
        detachThisThread;
    }
}
