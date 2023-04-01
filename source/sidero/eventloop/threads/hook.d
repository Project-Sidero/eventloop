module sidero.eventloop.threads.hook;
import sidero.eventloop.threads.registration;
import sidero.eventloop.threads.osthread;

version (D_BetterC) {
} else {
    import core.thread.osthread : thread_attachThis;
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
            import core.thread.osthread : Thread;

            return Thread.getThis() !is null;
        }

        registerThreadRegistration(&globalThreadSystemKey, cast(OnAttachThisFunction)&onAttach,
                cast(OnDetachThisFunction)&onDetach, cast(IsThreadRegisteredFunction)&isRegistered);
    }

    pragma(crt_destructor) extern (C) void register_sidero_threads_deregister() {
        deregisterThreadRegistration(&globalThreadSystemKey);
    }

    static this() {
        Thread self = Thread.self;
        self.externalAttach;
    }

    static ~this() {
        Thread self = Thread.self;
        self.externalDetach;
    }
}
