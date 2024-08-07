module sidero.eventloop.internal.posix.bindings;

nothrow @nogc:

version(Posix) {
    import core.sys.posix.stat;
    import drtwait = core.sys.posix.sys.wait;

    version(CRuntime_Glibc) {
        private {
            int __WTERMSIG(int status) {
                return status & 0x7F;
            }
        }

        int WEXITSTATUS(int status) {
            return (status & 0xFF00) >> 8;
        }

        int WTERMSIG(int status) {
            return status & 0x7F;
        }

        bool WIFEXITED(int status) {
            return __WTERMSIG(status) == 0;
        }

        bool WIFSIGNALED(int status) {
            return (cast(byte)((status & 0x7F) + 1) >> 1) > 0;
        }
    } else version(Darwin) {
        private {
            int _WSTATUS(int status) {
                return (status & 0x7F);
            }
        }

        int WEXITSTATUS(int status) {
            return (status >> 8);
        }

        int WTERMSIG(int status) {
            return _WSTATUS(status);
        }

        bool WIFEXITED(int status) {
            return _WSTATUS(status) == 0;
        }

        bool WIFSIGNALED(int status) {
            return _WSTATUS(status) != drtwait._WSTOPPED && _WSTATUS(status) != 0;
        }
    } else version(CRuntime_Bionic) {
        int WEXITSTATUS(int status) {
            return (status & 0xFF00) >> 8;
        }

        int WTERMSIG(int status) {
            return status & 0x7F;
        }

        bool WIFEXITED(int status) {
            return WTERMSIG(status) == 0;
        }

        bool WIFSIGNALED(int status) {
            return WTERMSIG(status + 1) >= 2;
        }
    } else version(CRuntime_Musl) {
        int WEXITSTATUS(int status) {
            return (status & 0xFF00) >> 8;
        }

        int WTERMSIG(int status) {
            return status & 0x7F;
        }

        bool WIFEXITED(int status) {
            return WTERMSIG(status) == 0;
        }

        bool WIFSIGNALED(int status) {
            return (status & 0xffff) - 1U < 0xffU;
        }
    } else version(CRuntime_UClibc) {
        private {
            int __WTERMSIG(int status) {
                return status & 0x7F;
            }
        }

        int WEXITSTATUS(int status) {
            return (status & 0xFF00) >> 8;
        }

        int WTERMSIG(int status) {
            return status & 0x7F;
        }

        bool WIFEXITED(int status) {
            return __WTERMSIG(status) == 0;
        }

        bool WIFSIGNALED(int status) {
            return (cast(ulong)((status & 0xffff) - 1U) >> 1) < 0xffU;
        }
    } else
        static assert(0, "Unimplemented posix bindings");

    // we have to define our own environ variable, because somebody put const on it in druntime???
    extern (C) {
        version(CRuntime_UClibc) {
            extern __gshared char** __environ;
            alias environ = __environ;
        } else {
            extern __gshared char** environ;
        }
    }

    struct FTW {
        int base;
        int level;
    }

    extern (C) {
        alias NFTWFunc = extern (C) int function(const char*, const stat*, int, FTW*);
        int nftw(const char*, NFTWFunc, int, int);
    }

    version(linux) {
        enum {
            FTW_PHYS = 1,
            FTW_MOUNT = 2,
            FTW_CHDIR = 4,
            FTW_DEPTH = 8,
        }
    } else version(Android) {
        enum {
            FTW_PHYS = 1,
            FTW_MOUNT = 2,
            FTW_CHDIR = 4,
            FTW_DEPTH = 8,
        }
    } else version(FreeBSD) {
        enum {
            FTW_PHYS = 1,
            FTW_MOUNT = 2,
            FTW_DEPTH = 4,
            FTW_CHDIR = 8,
        }
    } else version(OpenBSD) {
        enum {
            FTW_PHYS = 1,
            FTW_MOUNT = 2,
            FTW_DEPTH = 4,
            FTW_CHDIR = 8,
        }
    } else version(NetBSD) {
        enum {
            FTW_PHYS = 1,
            FTW_MOUNT = 2,
            FTW_DEPTH = 4,
            FTW_CHDIR = 8,
        }
    }

    version(OSX) {
        enum {
            REMOVEFILE_RECURSIVE = 1 << 0,
            REMOVEFILE_KEEP_PARENT = 1 << 1,
            REMOVEFILE_SECURE_7_PASS = 1 << 2,
            REMOVEFILE_SECURE_35_PASS  = 1 << 3,
            REMOVEFILE_SECURE_1_PASS = 1 << 4,
            REMOVEFILE_SECURE_3_PASS = 1 << 5,
            REMOVEFILE_SECURE_1_PASS_ZERO = 1 << 6,
            REMOVEFILE_CROSS_MOUNT = 1 << 7,
        }

        struct removefile_state;
        alias removefile_state_t = removefile_state*;
        alias removefile_flags_t = uint;

        extern(C) {
            removefile_state_t removefile_state_alloc();
            int removefile_state_free(removefile_state_t);
            int removefile(const(char)* path, removefile_state_t state, removefile_flags_t flags);
        }
    }
}
