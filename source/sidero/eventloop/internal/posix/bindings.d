module sidero.eventloop.internal.posix.bindings;

nothrow @nogc:

version (Posix) {
    import drtwait = core.sys.posix.sys.wait;

    version (CRuntime_Glibc) {
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
    } else version (Darwin) {
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
    } else version (CRuntime_Bionic) {
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
    } else version (CRuntime_Musl) {
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
    } else version (CRuntime_UClibc) {
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
        version (CRuntime_UClibc) {
            extern __gshared char** __environ;
            alias environ = __environ;
        } else {
            extern __gshared char** environ;
        }
    }
}
