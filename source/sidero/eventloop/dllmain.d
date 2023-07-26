module sidero.base.dllmain;
export:

version(DynamicSideroEventLoop) {
    version(Windows) {
        import core.sys.windows.windef : HINSTANCE, BOOL, DWORD, LPVOID;

        extern (Windows) BOOL DllMain(HINSTANCE hInstance, DWORD ulReason, LPVOID reserved) {
            import sidero.eventloop.threads.osthread;
            import core.sys.windows.winnt : DLL_THREAD_ATTACH, DLL_THREAD_DETACH;

            if(ulReason == DLL_THREAD_ATTACH) {
                Thread self = Thread.self;
                self.externalAttach;
            } else if(ulReason == DLL_THREAD_DETACH) {
                Thread self = Thread.self;
                self.externalDetach;
            }
            return true;
        }
    }
}
