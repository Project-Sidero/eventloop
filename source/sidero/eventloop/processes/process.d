module sidero.eventloop.processes.process;
import sidero.eventloop.processes.pipe;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.tasks.future_completion;
import sidero.base.text;
import sidero.base.allocators;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.map.hashmap;
import sidero.base.errors;
import sidero.base.attributes;

export @safe nothrow @nogc:

version(Windows) {
    import sidero.eventloop.internal.windows.bindings : HANDLE;

    alias ProcessID = HANDLE;
} else version(Posix) {
    import core.sys.posix.sys.types : pid_t;

    alias ProcessID = pid_t;
}

///
struct Process {
    package(sidero.eventloop) @PrettyPrintIgnore {
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
                removeEventWaiterHandle(cast(void*)state.id);

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
    WritePipe inputPipe() scope const @trusted {
        if(isNull)
            return WritePipe.init;
        else
            return (cast(State*)state).inputPipe;
    }

    ///
    ReadPipe outputPipe() scope const @trusted {
        if(isNull)
            return ReadPipe.init;
        else
            return (cast(State*)state).outputPipe;
    }

    ///
    ReadPipe errorPipe() scope const @trusted {
        if(isNull)
            return ReadPipe.init;
        else
            return (cast(State*)state).errorPipe;
    }

    ///
    ulong toHash() scope const {
        return cast(size_t)this.id;
    }

    ///
    bool opEquals(scope const Process other) scope const {
        return this.id == other.id;
    }

    ///
    int opCmp(scope const Process other) scope const {
        ProcessID a = this.id, b = other.id;

        return a < b ? -1 : (a > b ? 1 : 0);
    }

    ///
    String_UTF8 toString(RCAllocator allocator = RCAllocator.init) @trusted {
        StringBuilder_UTF8 ret = StringBuilder_UTF8(allocator);
        toString(ret);
        return ret.asReadOnly;
    }

    ///
    void toString(Sink)(scope ref Sink sink) @trusted {
        if(isNull)
            sink.formattedWrite("Process(null)");
        else
            sink.formattedWrite("Process({:p})", this.id);
    }

    ///
    String_UTF8 toStringPretty(RCAllocator allocator = RCAllocator.init) @trusted {
        StringBuilder_UTF8 ret = StringBuilder_UTF8(allocator);
        toStringPretty(ret);
        return ret.asReadOnly;
    }

    ///
    void toStringPretty(Sink)(scope ref Sink sink) @trusted {
        if(isNull)
            sink.formattedWrite("Process(null)");
        else if(!this.state.result.isComplete())
            sink.formattedWrite("Process({:p})", this.id);
        else
            sink.formattedWrite("Process({:p}, exitCode={:s})", this.id, this.state.result.result().assumeOkay);
    }

    ///
    static Result!Process execute(scope String_UTF8 executable, scope Slice!String_UTF8 arguments,
            scope String_UTF8 currentWorkingDirectory = String_UTF8.init, scope HashMap!(String_UTF8,
                String_UTF8) environment = HashMap!(String_UTF8,
                String_UTF8).init, bool inheritStandardIO = true, bool overrideParentEnvironment = false) {
        version(Windows) {
            return executeWindows(executable, currentWorkingDirectory, environment, arguments, false,
                    inheritStandardIO, overrideParentEnvironment);
        } else version(Posix) {
            return executePosix(executable, currentWorkingDirectory, environment, arguments, false, inheritStandardIO,
                    overrideParentEnvironment);
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
        } else version(Posix) {
            return executePosix(executable, currentWorkingDirectory, environment, arguments, true, inheritStandardIO,
                    overrideParentEnvironment);
        } else
            static assert(0, "Platform unimplemented");
    }
}

private:

struct State {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    ProcessID id;
    shared(bool) isAlive;
    Future!int result;
    FutureTriggerStorage!int* resultStorage;

    WritePipe inputPipe;
    ReadPipe outputPipe, errorPipe;
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
            NORMAL_PRIORITY_CLASS, CREATE_UNICODE_ENVIRONMENT,
            CloseHandle, CreatePipe, STARTF_USESTDHANDLES, SECURITY_ATTRIBUTES, SetHandleInformation, HANDLE_FLAG_INHERIT;

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

            if(withShell) {
                String_UTF16 shell = EnvironmentVariables[String_UTF16(UserShellVar)];
                if(shell.isNull)
                    shell = String_UTF16(SystemShell);

                escapeAdd(shell);
                builder ~= ShellInvokeSwitch;
            }

            escapeAdd(executable);

            foreach(arg; arguments) {
                assert(arg);
                escapeAdd(arg);
            }

            cmd = builder.asReadOnly;
        }

        if(overrideParentEnvironment || environment.length == 0) {
            // only set envString if we are not inheriting from parent

            HashMap!(String_UTF8, String_UTF8) tempEnv;

            if(!overrideParentEnvironment) {
                tempEnv = EnvironmentVariables.toHashMap();

                foreach(k, v; environment) {
                    tempEnv[k] = v;
                }
            } else {
                tempEnv = environment;
            }

            StringBuilder_UTF16 temp;

            foreach(k, v; tempEnv) {
                assert(k);
                assert(v);

                temp ~= k;
                temp ~= "="w;
                temp ~= v;
                temp ~= "\0"w;
            }
            temp ~= "\0\0"w;

            envString = temp.asReadOnly;
        }

        STARTUPINFOW startupInfo;
        startupInfo.cb = STARTUPINFOW.sizeof;

        if(inheritStandardIO) {
            // standard IO handles by default will be setup to inherit by sidero.base.console
            // we need to do nothing here (crt_constructor).
        } else {
            startupInfo.dwFlags = STARTF_USESTDHANDLES;
            HANDLE writeInputH, readOutputH, readErrorH;

            SECURITY_ATTRIBUTES secAttrib;
            secAttrib.nLength = SECURITY_ATTRIBUTES.sizeof;
            secAttrib.bInheritHandle = true;

            if(!CreatePipe(&startupInfo.hStdInput, &writeInputH, &secAttrib, 0))
                return typeof(return)(UnknownPlatformBehaviorException("Could not create input pipes"));

            if(!SetHandleInformation(writeInputH, HANDLE_FLAG_INHERIT, 0)) {
                CloseHandle(writeInputH);
                CloseHandle(startupInfo.hStdInput);
                return typeof(return)(UnknownPlatformBehaviorException("Could not set input pipe non inheritance"));
            }

            if(!CreatePipe(&readOutputH, &startupInfo.hStdOutput, &secAttrib, 0)) {
                CloseHandle(writeInputH);
                CloseHandle(startupInfo.hStdInput);
                return typeof(return)(UnknownPlatformBehaviorException("Could not create output pipes"));
            }

            if(!SetHandleInformation(readOutputH, HANDLE_FLAG_INHERIT, 0)) {
                CloseHandle(writeInputH);
                CloseHandle(readOutputH);
                CloseHandle(startupInfo.hStdInput);
                CloseHandle(startupInfo.hStdOutput);
                return typeof(return)(UnknownPlatformBehaviorException("Could not set input pipe non inheritance"));
            }

            if(!CreatePipe(&readErrorH, &startupInfo.hStdError, &secAttrib, 0)) {
                CloseHandle(writeInputH);
                CloseHandle(readOutputH);
                CloseHandle(startupInfo.hStdInput);
                CloseHandle(startupInfo.hStdOutput);
                return typeof(return)(UnknownPlatformBehaviorException("Could not create error pipes"));
            }

            if(!SetHandleInformation(readErrorH, HANDLE_FLAG_INHERIT, 0)) {
                CloseHandle(writeInputH);
                CloseHandle(readOutputH);
                CloseHandle(readErrorH);
                CloseHandle(startupInfo.hStdInput);
                CloseHandle(startupInfo.hStdOutput);
                CloseHandle(startupInfo.hStdError);
                return typeof(return)(UnknownPlatformBehaviorException("Could not set input pipe non inheritance"));
            }

            ret.state.inputPipe = WritePipe.fromSystemHandle(writeInputH);
            ret.state.outputPipe = ReadPipe.fromSystemHandle(readOutputH);
            ret.state.errorPipe = ReadPipe.fromSystemHandle(readErrorH);
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

Result!Process executePosix(T)(scope String_UTF8 executable, scope String_UTF8 currentWorkingDirectory, scope HashMap!(String_UTF8,
        String_UTF8) environment, scope T arguments, bool withShell, bool inheritStandardIO, bool overrideParentEnvironment) @trusted {
    import sidero.eventloop.internal.event_waiting;
    import sidero.eventloop.internal.posix.cleanup_timer;
    import sidero.base.system : EnvironmentVariables;
    import sidero.base.internal.atomic;

    RCAllocator allocator = globalAllocator();
    Process ret;
    ret.state = allocator.make!State(1, allocator);

    version(Posix) {
        import core.sys.posix.unistd : fork, chdir, pipe, _exit, execv, execvp, close, read, write, dup2, STDIN_FILENO,
            STDOUT_FILENO, STDERR_FILENO;
        import core.stdc.errno : errno, ECONNRESET, ENOTCONN;
        import core.sys.posix.fcntl;

        enum UserShellVar = "SHELL";
        enum ShellInvokeSwitch = "-c ";
        version(Android) {
            enum SystemShell = "/system/bin/sh";
        } else {
            enum SystemShell = "/bin/sh";
        }

        int[2] childCommunicationPipes;
        if(pipe(childCommunicationPipes) != 0)
            return typeof(return)(UnknownPlatformBehaviorException("Could not create error message pipes"));

        int[2] inputPipes, outputPipes, errorPipes;

        if(inheritStandardIO) {
            // standard IO handles by default will be setup to inherit by sidero.base.console
            // we need to do nothing here (crt_constructor).
        } else {
            if(pipe(inputPipes) != 0) {
                close(childCommunicationPipes[0]);
                close(childCommunicationPipes[1]);
                return typeof(return)(UnknownPlatformBehaviorException("Could not create process input pipes"));
            }

            if(pipe(outputPipes) != 0) {
                close(childCommunicationPipes[0]);
                close(childCommunicationPipes[1]);
                close(inputPipes[0]);
                close(inputPipes[1]);
                return typeof(return)(UnknownPlatformBehaviorException("Could not create process output pipes"));
            }

            if(pipe(errorPipes) != 0) {
                close(childCommunicationPipes[0]);
                close(childCommunicationPipes[1]);
                close(inputPipes[0]);
                close(inputPipes[1]);
                close(outputPipes[0]);
                close(outputPipes[1]);
                return typeof(return)(UnknownPlatformBehaviorException("Could not create process error pipes"));
            }

            ret.state.inputPipe = WritePipe.fromSystemHandle(inputPipes[1]);
            ret.state.outputPipe = ReadPipe.fromSystemHandle(outputPipes[0]);
            ret.state.errorPipe = ReadPipe.fromSystemHandle(errorPipes[0]);
        }

        ProcessID pid = fork();

        if(pid == 0) {
            // child

            void writeError(int message) {
                write(childCommunicationPipes[1], &message, 4);
                close(childCommunicationPipes[1]);
                _exit(-1);
            }

            if(!inheritStandardIO) {
                if(dup2(STDIN_FILENO, inputPipes[0]) < 0)
                    writeError(10);

                if(dup2(STDOUT_FILENO, outputPipes[1]) < 0)
                    writeError(11);

                if(dup2(STDERR_FILENO, errorPipes[1]) < 0)
                    writeError(12);

                close(inputPipes[1]);
                close(outputPipes[0]);
                close(errorPipes[0]);
            }

            close(childCommunicationPipes[0]);
            fcntl(childCommunicationPipes[1], F_SETFD, FD_CLOEXEC);

            String_UTF8 application;
            String_UTF8 cwd = currentWorkingDirectory;
            DynamicArray!String_UTF8 argStrings;
            DynamicArray!(char*) argStringPtrs;
            DynamicArray!String_UTF8 envStrings;
            DynamicArray!(char*) envStringPtrs;

            if(!cwd.isPtrNullTerminated())
                cwd = cwd.dup;

            if(currentWorkingDirectory.length > 0) {
                // https://man7.org/linux/man-pages/man2/chdir.2.html
                if(!currentWorkingDirectory.isPtrNullTerminated)
                    currentWorkingDirectory = currentWorkingDirectory.dup;

                if(chdir(currentWorkingDirectory.ptr) != 0)
                    writeError(1);
            }

            {
                if(withShell) {
                    String_UTF8 shell = EnvironmentVariables[String_UTF8(UserShellVar)];
                    if(shell.isNull)
                        shell = String_UTF8(SystemShell);

                    application = shell;
                    argStrings.length = 2 + 1 + arguments.length;
                    argStringPtrs.length = 2 + 1 + arguments.length;
                } else {
                    application = executable;
                    argStrings.length = 2 + arguments.length;
                    argStringPtrs.length = 2 + arguments.length;
                }

                if(application.isPtrNullTerminated())
                    application = application.dup;

                if(!(argStrings[0] = application))
                    writeError(2);
                if(!(argStringPtrs[0] = cast(char*)application.ptr))
                    writeError(3);

                if(withShell) {
                    if(!(argStringPtrs[1] = cast(char*)ShellInvokeSwitch.ptr))
                        writeError(4);

                    foreach(i, arg; arguments) {
                        assert(arg);

                        String_UTF8 val = arg;
                        if(!val.isPtrNullTerminated())
                            val = val.dup;

                        if(!(argStrings[2 + i] = val))
                            writeError(5);
                        if(!(argStringPtrs[2 + i] = cast(char*)val.ptr))
                            writeError(6);
                    }
                } else {
                    foreach(i, arg; arguments) {
                        assert(arg);

                        String_UTF8 val = arg;
                        if(!val.isPtrNullTerminated())
                            val = val.dup;

                        if(!(argStrings[1 + i] = val))
                            writeError(7);
                        if(!(argStringPtrs[1 + i] = cast(char*)val.ptr))
                            writeError(8);
                    }
                }
            }

            {
                // environment is an array of pointers will a null pointer ending it
                // split k/v with =

                HashMap!(String_UTF8, String_UTF8) tempEnv;

                if(!overrideParentEnvironment) {
                    tempEnv = EnvironmentVariables.toHashMap();

                    foreach(k, v; environment) {
                        tempEnv[k] = v;
                    }
                } else {
                    tempEnv = environment;
                }

                envStrings.length = tempEnv.length;
                envStringPtrs.length = tempEnv.length + 1; // null terminator string
                size_t offset;

                foreach(k, v; tempEnv) {
                    assert(k);
                    assert(v);

                    StringBuilder_UTF8 builder;
                    builder ~= k;
                    builder ~= "="c;
                    builder ~= v;

                    String_UTF8 text = builder.asReadOnly; // null terminates

                    (envStrings[offset] = text).assumeOkay;
                    (envStringPtrs[offset++] = cast(char*)text.ptr).assumeOkay;
                }
            }

            // We set the environment variables because we cannot use the arrays
            //  and set the environment variable in a single function,
            // Thanks POSIX!!!
            // The new process will inherit from it being set
            version(Drawin) {
                import core.sys.darwin.crt_externs : _NSGetEnviron;

                *_NSGetEnviron() = envStringPtrs.ptr;
            } else {
                // this should be declared in druntime as char** not const(char**)
                environ = envStringPtrs.ptr;
            }

            // we use two different variants that differ based upon their lookup rules
            if(execv(application.ptr, argStringPtrs.ptr) != 0) {
                if(execvp(application.ptr, argStringPtrs.ptr) != 0) {
                    writeError(9);
                }
            }
        } else if(pid > 0) {
            // parent
            ret.state.id = pid;

            int toRead;

            {
                close(childCommunicationPipes[1]);
                auto error = read(childCommunicationPipes[0], &toRead, 4);
                close(childCommunicationPipes[0]);

                if(error < 0 && (errno != ECONNRESET && errno != ENOTCONN))
                    return typeof(return)(UnknownPlatformBehaviorException("Could not read child process error pipe"));
            }

            switch(toRead) {
            case 1:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set current working directory of child process"));
            case 2:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set application argument"));
            case 3:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set application argument pointer"));
            case 4:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set shell switch argument pointer"));
            case 5:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set shell argument"));
            case 6:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set shell argument pointer"));
            case 7:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set argument"));
            case 8:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set argument pointer"));
            case 9:
                return typeof(return)(UnknownPlatformBehaviorException("Could not set execute"));
            case 10:
                return typeof(return)(UnknownPlatformBehaviorException("Could not configure input pipe for process"));
            case 11:
                return typeof(return)(UnknownPlatformBehaviorException("Could not configure output pipe for process"));
            case 12:
                return typeof(return)(UnknownPlatformBehaviorException("Could not configure error pipe for process"));

            case 0:
            default:
                // ok
                //atomicStore(ret.state.isAlive, true);
                break;
            }

            auto instantiableFuture = acquireInstantiableFuture!int;
            ret.state.result = instantiableFuture.makeInstance(allocator, &ret.state.resultStorage).asFuture;
            assert(ret.state.resultStorage !is null);

            auto waitError = waitOnTrigger(ret.state.result, ret.state.resultStorage);
            assert(waitError);

            requireCleanupTimer;
            addProcessToList(ret);
        } else if(pid < 0) {
            // parent, has error

            close(childCommunicationPipes[0]);
            close(childCommunicationPipes[1]);

            return typeof(return)(UnknownPlatformBehaviorException("Could not fork"));
        }
    }

    return ret;
}

// we have to define our own environ variable, because somebody put const on it in druntime???
version(Posix) {
    extern (C) {
        version(CRuntime_UClibc) {
            extern __gshared char** __environ;
            alias environ = __environ;
        } else {
            extern __gshared char** environ;
        }
    }
}
