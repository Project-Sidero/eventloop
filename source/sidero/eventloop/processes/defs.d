module sidero.eventloop.processes.defs;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.tasks.future_completion;
import sidero.base.text;
import sidero.base.allocators;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.map.hashmap;
import sidero.base.errors;

export @safe nothrow @nogc:

version(Windows) {
    import sidero.eventloop.internal.windows.bindings : HANDLE;

    alias ProcessID = HANDLE;
} else version(Posix) {
    alias ProcessID = pid_t;
}

struct Process {
    private {
        State* state;
    }

export @safe nothrow @nogc:

    ///
    this(return scope ref Process other) scope {
        import sidero.base.internal.atomic;

        this.state = other.state;

        if(this.state !is null) {
            atomicIncrementAndLoad(this.state.refCount, 1);
        }
    }

    ///
    ~this() scope @trusted {
        import sidero.eventloop.internal.event_waiting;
        import sidero.base.internal.atomic;

        if(this.state !is null && atomicDecrementAndLoad(this.state.refCount, 1) == 0) {
            if(atomicLoad(state.isAlive))
                removeEventWaiterHandle(state.id);

            version(Windows) {
                import sidero.eventloop.internal.windows.bindings : CloseHandle;

                CloseHandle(state.id);
            }

            RCAllocator allocator = state.allocator;
            allocator.dispose(this.state);
        }
    }

    ///
    bool isNull() scope const {
        return state is null;
    }

    ///
    ProcessID id() scope return const @trusted {
        if(isNull)
            return ProcessID.init;
        return cast(ProcessID)state.id;
    }

    ///
    Future!int result() scope const @trusted {
        if(isNull)
            return typeof(return).init;
        else
            return (cast(State*)state).result;
    }

    ///
    static Result!Process execute(scope String_UTF8 executable, scope Slice!String_UTF8 arguments,
            scope String_UTF8 currentWorkingDirectory = String_UTF8.init, scope HashMap!(String_UTF8,
                String_UTF8) environment = HashMap!(String_UTF8,
                String_UTF8).init, bool inheritStandardIO = true, bool overrideParentEnvironment = false) {
        version(Windows) {
            return executeWindows(executable, currentWorkingDirectory, environment, arguments, false,
                    inheritStandardIO, overrideParentEnvironment);
        } else
            static assert(0, "Platform unimplemented");
    }

    ///
    static Result!Process executeShell(scope String_UTF8 executable, scope Slice!String_UTF8 arguments,
            scope String_UTF8 currentWorkingDirectory = String_UTF8.init, scope HashMap!(String_UTF8,
                String_UTF8) environment = HashMap!(String_UTF8,
                String_UTF8).init, bool inheritStandardIO = true, bool overrideParentEnvironment = false) {
        version(Windows) {
            return executeWindows(executable, currentWorkingDirectory, environment, arguments, true, inheritStandardIO,
                    overrideParentEnvironment);
        } else
            static assert(0, "Platform unimplemented");
    }
}

/*
don't use posix_spawn, cannot setworking directory
https://man7.org/linux/man-pages/man2/execve.2.html
https://man7.org/linux/man-pages/man2/fork.2.html


user:
Posix shell comes from $SHELL

system:
Android /system/bin/sh
Posix /bin/sh

to tell the shell that the following is command
Posix -c

Posix wrap with ' and escape with \'


version(Posix) {
            ProcessID pid = fork();

            if(pid == 0) {
                // child

                // https://man7.org/linux/man-pages/man2/chdir.2.html
                // chdir

                // program
                // arguments

                // https://man7.org/linux/man-pages/man3/exec.3.html
                // execvpe
            } else if(pid > 0) {
                // parent
            } else if(pid < 0) {
                // parent, has error
            }
        } else

version(Posix) {
            ProcessID pid = fork();

            if(pid == 0) {
                // child

                // https://man7.org/linux/man-pages/man2/chdir.2.html
                // chdir

                // $shell
                // shellInvokeSwitch
                // program
                // arguments

                // https://man7.org/linux/man-pages/man3/exec.3.html
                // execvpe
            } else if(pid > 0) {
                // parent
            } else if(pid < 0) {
                // parent, has error
            }
        } else
 */

private:

struct State {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    ProcessID id;
    shared(bool) isAlive;
    Future!int result;
    FutureTriggerStorage!int* resultStorage;
}

Result!Process executeWindows(T)(scope String_UTF8 executable, scope String_UTF8 currentWorkingDirectory, scope HashMap!(String_UTF8,
        String_UTF8) environment, scope T arguments, bool withShell, bool inheritStandardIO, bool overrideParentEnvironment) @trusted {
    import sidero.eventloop.internal.event_waiting;
    import sidero.base.system : EnvironmentVariables;
    import sidero.base.internal.atomic;

    RCAllocator allocator = globalAllocator();
    Process ret;
    ret.state = allocator.make!State(1, allocator);

    static void unpin(void* handle, void* user, scope void* eventResponsePtr) @trusted nothrow @nogc {
        Process process;
        process.state = cast(State*)user;

        if(cas(process.state.isAlive, true, false)) {
            version(Windows) {
                import sidero.eventloop.internal.windows.bindings : DWORD, GetExitCodeProcess;

                DWORD exitCode;
                GetExitCodeProcess(process.state.id, &exitCode);

                auto triggerError = trigger(process.state.resultStorage, cast(int)exitCode);
                process.state.resultStorage = null;
            }

            removeEventWaiterHandle(process.state.id);
            // unpins by __dtor automatically
        } else // not alive, or we didn't do the unpin, either way don't handle the potential deallocate here
            process.state = null;
    }

    version(Windows) {
        import sidero.eventloop.internal.windows.bindings : STARTUPINFOW, PROCESS_INFORMATION, CreateProcessW,
            NORMAL_PRIORITY_CLASS, CREATE_UNICODE_ENVIRONMENT, CloseHandle;

        static immutable UserShellVar = "COMSPEC\0"w;
        static immutable SystemShell = "cmd.exe"w;
        static immutable ShellInvokeSwitch = "/C "w;

        String_UTF16 cwd = currentWorkingDirectory.byUTF16.dup;
        String_UTF16 cmd;
        String_UTF16 envString;

        {
            StringBuilder_UTF16 builder;

            void escapeAdd(U)(scope U toAdd) {
                const offset = builder.length;
                builder ~= toAdd;

                auto slice = builder[offset .. $];
                slice.replace(`"`w, `\"`w);
                slice.prepend(`"`w);
                slice.append(`" `w);
            }

            if (withShell) {
                String_UTF16 shell = EnvironmentVariables[String_UTF16(UserShellVar)];
                if (shell.isNull)
                    shell = String_UTF16(SystemShell);

                escapeAdd(shell);
                builder ~= ShellInvokeSwitch;
            }

            escapeAdd(executable);

            foreach (arg; arguments) {
                assert(arg);
                escapeAdd(arg);
            }

            cmd = builder.asReadOnly;
        }

        if(overrideParentEnvironment || environment.length == 0) {
            // only set envString if we are not inheriting from parent

            HashMap!(String_UTF8, String_UTF8) tempEnv;

            if(!overrideParentEnvironment) {
                // TODO: grab parent env
                // TODO: store environment into it
            } else {
                tempEnv = environment;
            }

            StringBuilder_UTF16 temp;
            // don't forget that string builder will remove last \0, so gotta add 2
            // TODO: compose envString before putting in envString
        }

        STARTUPINFOW startupInfo;
        startupInfo.cb = STARTUPINFOW.sizeof;

        if(inheritStandardIO) {
            // standard IO handles by default will be setup to inherit by sidero.base.console
            // we need to do nothing here (crt_constructor).
        } else {
            // TODO: set up pipes
            //startupInfo.dwFlags = STARTF_USESTDHANDLES;
            // startupInfo.hStdInput =
            // startupInfo.hStdOutput =
            // startupInfo.hStdError =
        }

        PROCESS_INFORMATION processInformation;

        // do not use application name
        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-process_information
        // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
        if(CreateProcessW(null, cast(wchar*)cmd.ptr, null, null, false,
                NORMAL_PRIORITY_CLASS | CREATE_UNICODE_ENVIRONMENT, cast(wchar*)envString.ptr, cast(wchar*)cwd.ptr,
                &startupInfo, &processInformation) != 0) {
            atomicStore(ret.state.refCount, 2); // pin
            atomicStore(ret.state.isAlive, true);

            CloseHandle(processInformation.hThread);

            auto instantiableFuture = acquireInstantiableFuture!int;
            ret.state.result = instantiableFuture.makeInstance(allocator, &ret.state.resultStorage).asFuture;

            auto waitError = waitOnTrigger(ret.state.result, ret.state.resultStorage);
            assert(waitError);

            ret.state.id = processInformation.hProcess;
            addEventWaiterHandle(processInformation.hProcess, &unpin, cast(void*)ret.state);
        } else {
            // GetLastError
            return typeof(return)(UnknownPlatformBehaviorException("Could not create process for an unknown reason"));
        }
    }

    return ret;
}
