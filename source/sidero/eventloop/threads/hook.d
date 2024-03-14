module sidero.eventloop.threads.hook;
import sidero.eventloop.threads.registration;
import sidero.eventloop.threads.osthread;

version(D_BetterC) {
} else {
    import core.thread.osthread : thread_attachThis;
    import core.thread.threadbase : thread_detachThis;

    extern (C) void rt_moduleTlsCtor();
    extern (C) void rt_moduleTlsDtor();

    shared static this() {
        static extern (C) void onAttach() {
            thread_attachThis;
            rt_moduleTlsCtor;
        }

        static extern (C) void onDetach() {
            rt_moduleTlsDtor;
            thread_detachThis;
        }

        static extern (C) bool isRegistered() {
            import core.thread.osthread : Thread;

            return Thread.getThis() !is null;
        }

        static extern (C) void detachOfThread(Thread self) @trusted {
            import core.thread.threadbase : thread_detachByAddr;
            import core.thread.types : ThreadID;

            if(self.isNull)
                return;

            auto handle = self.unsafeGetHandle();

            thread_detachByAddr(cast(ThreadID)handle.handle);
        }

        registerThreadRegistration(&thread_attachThis, cast(OnAttachThisFunction)&onAttach, cast(OnDetachThisFunction)&onDetach,
                cast(IsThreadRegisteredFunction)&isRegistered, cast(DetachOfThreadFunction)&detachOfThread);
    }

    shared static ~this() {
        import core.memory : GC;

        // For Posix you super dooper dooperily do not want the GC enabled and aware of our threads
        // If we don't disable and /then/ deregister it will be possible that the GC will collect something that
        //  one of our threads knows about.
        // If we don't deregister all threads we own on Posix you will get segfaults
        GC.collect;
        GC.disable;
        deregisterOwnedThreads();

        deregisterThreadRegistration(&thread_attachThis);
    }

    static this() {
        Thread.externalAttach;
    }

    static ~this() {
        Thread.externalDetach;
    }
}
