module sidero.eventloop.threads.hook;
import sidero.eventloop.threads.registration;
import sidero.eventloop.threads.osthread;

version(D_BetterC) {
} else {
    import core.thread.osthread : thread_attachThis;
    import core.thread.threadbase : thread_detachThis;

    extern (C) void rt_moduleTlsCtor();
    extern (C) void rt_moduleTlsDtor();
    private __gshared int globalThreadSystemKey;

    shared static this() {
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

    shared static ~this() {
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
