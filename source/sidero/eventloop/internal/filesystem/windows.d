module sidero.eventloop.internal.filesystem.windows;
import sidero.eventloop.internal.filesystem.defs;
import sidero.eventloop.internal.filesystem.state;
import sidero.eventloop.filesystem.file;
import sidero.eventloop.threads;
import sidero.base.errors;
import sidero.base.text;
import sidero.base.logger;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import sidero.eventloop.internal.workers.kernelwait.windows : associateWithIOCP, IOCPwork;
}

@safe nothrow @nogc:

struct PlatformFile {
    version(Windows) {
        HANDLE handle;
        OVERLAPPED readOverlapped, alwaysReadingOverlapped, writeOverlapped;
        IOCPwork iocpWork;
    }

    enum keepAReadAlwaysGoing = true;
    bool havePendingAlwaysWaitingRead, havePendingRead;

@safe nothrow @nogc:

    // NOTE: must be guarded
    void notifiedOfReadComplete(scope FileState* fileState) scope @trusted {
        this.havePendingAlwaysWaitingRead = false;
        this.havePendingRead = false;

        initiateAConstantlyRunningReadRequest(fileState);
    }

    void initiateAConstantlyRunningReadRequest(scope FileState* fileState) @trusted {
        version(Windows) {
            import sidero.base.internal.atomic : atomicLoad;

            if(atomicLoad(fileState.isClosed) || fileState.havePendingAlwaysWaitingRead || fileState.havePendingRead)
                return;

            fileState.alwaysReadingOverlapped = OVERLAPPED.init;
            fileState.havePendingAlwaysWaitingRead = true;

            logger.debug_("Starting a constantly running read request for ", fileState.handle, " on ", Thread.self);

            DWORD flags;

            ubyte[1] buf;
            auto result = ReadFile(fileState.handle, buf.ptr, 0, null, &fileState.alwaysReadingOverlapped);

            if(result != 0) {
                // completed, IOCP will be notified of completion
                logger.trace("Immediate completion of read ", fileState.handle, " on ", Thread.self);
                fileState.pinExtra;
            } else {
                const errorCode = GetLastError();

                switch(errorCode) {
                case ERROR_IO_PENDING:
                    // this is okay, its delayed via IOCP
                    logger.debug_("Reading delayed via IOCP for ", fileState.handle, " on ", Thread.self);
                    fileState.pinExtra;
                    return;

                default:
                    havePendingAlwaysWaitingRead = false;
                    logger.notice("Unknown error while reading ", errorCode, " for ", fileState.handle, " on ", Thread.self);
                    fileState.pinExtra;
                    return;
                }
            }
        } else
            assert(0);
    }
}

ErrorResult openFile(File file) @trusted {
    version(Windows) {
        String_UTF16 path16 = file.state.filePath.toStringUTF16();

        DWORD access = GENERIC_READ;
        DWORD shareMode = FILE_SHARE_READ | FILE_SHARE_WRITE;

        if(file.state.fileRights.write)
            access |= GENERIC_WRITE;

        if(file.state.fileRights.forceAppend)
            access |= FILE_APPEND_DATA;

        if(file.state.fileRights.create) {
            if(file.state.fileRights.createAsExecutable)
                access |= FILE_EXECUTE;

            file.state.handle = CreateFileW(path16.ptr, access, shareMode, null, CREATE_NEW, FILE_FLAG_OVERLAPPED, null);
        } else {
            file.state.handle = CreateFileW(path16.ptr, access, shareMode, null, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, null);
        }

        if(file.state.handle is INVALID_HANDLE_VALUE) {
            switch(GetLastError()) {
            case ERROR_SHARING_VIOLATION:
                return typeof(return)(
                        UnknownPlatformBehaviorException("Could not open/create a file given the path due to sharing violation"));

            default:
                return typeof(return)(UnknownPlatformBehaviorException("Could not open/create a file given the path"));
            }
        }

        if(!associateWithIOCP(file)) {
            file.state.forceClose;
            return ErrorResult(UnknownPlatformBehaviorException("Could not associate file with IOCP workers"));
        } else {
            logger.debug_("Associated file with IOCP ", file.state.handle, " on ", Thread.self);
        }

        file.state.pin();
        file.state.initiateAConstantlyRunningReadRequest(file.state);
        return ErrorResult.init;
    } else
        assert(0);
}

void forceClose(scope FileState* fileState) @trusted {
    version(Windows) {
        import sidero.base.internal.atomic;

        if(cas(fileState.isClosed, false, true)) {
            logger.debug_("Forcing closed file ", fileState.handle);

            if(fileState.rawReading.inProgress) {
                CancelIoEx(fileState.handle, &fileState.readOverlapped);

                if(CancelIoEx(fileState.handle, &fileState.readOverlapped) != 0) {
                    logger.debug_("Successfully cancelled read for file ", fileState.handle, " on ", Thread.self);

                    DWORD transferred;
                    GetOverlappedResult(fileState.handle, &fileState.readOverlapped, &transferred, false);
                } else {
                    logger.info("Read for file ", fileState.handle, " failed to cancel ", &fileState.readOverlapped,
                            " with error ", GetLastError(), " on thread ", Thread.self);
                }
            }

            if(fileState.havePendingAlwaysWaitingRead) {
                if(CancelIoEx(fileState.handle, &fileState.alwaysReadingOverlapped) != 0) {
                    logger.debug_("Successfully cancelled always reading read for file ", fileState.handle, " on ", Thread.self);

                    DWORD transferred;
                    GetOverlappedResult(fileState.handle, &fileState.alwaysReadingOverlapped, &transferred, false);
                } else {
                    logger.info("Always pending read for file ", fileState.handle, " failed to cancel ",
                            &fileState.alwaysReadingOverlapped, " with error ", GetLastError(), " on thread ", Thread.self);
                }
            }

            if(CancelIoEx(fileState.handle, null) != 0) {
                logger.debug_("Successfully cancelled any file operations for ", fileState.handle, " on ", Thread.self);
            } else {
                logger.info("File operations for ", fileState.handle, " failed to cancel with error ", GetLastError(),
                        " on thread ", Thread.self);
            }

            fileState.reading.cleanup(fileState);
            fileState.performReadWrite();
            forceClose(fileState);

            CloseHandle(fileState.handle);
        }
    } else
        assert(0);
}

bool tryWriteMechanism(scope FileState* fileState, ubyte[] buffer, long position) @trusted {
    version(Windows) {
        import sidero.base.internal.atomic;

        if(atomicLoad(fileState.isClosed))
            return false;

        fileState.writeOverlapped = OVERLAPPED.init;
        fileState.writeOverlapped.Offset = cast(uint)position;
        fileState.writeOverlapped.OffsetHigh = cast(uint)(position >> 32);

        DWORD transferredBytes;
        auto result = WriteFile(fileState.handle, buffer.ptr, cast(uint)buffer.length, &transferredBytes, &fileState.writeOverlapped);

        if(result == 0) {
            // completed, transferredBytes will have the amount of data that was sent
            logger.debug_("Immediate completion of write ", fileState.handle, " on ", Thread.self);
            fileState.pinExtra;
            return true;
        } else {
            const errorCode = GetLastError();

            switch(errorCode) {
            case ERROR_IO_PENDING:
                // this is okay, its delayed via IOCP
                logger.debug_("Writing delayed via IOCP for ", fileState.handle, " on ", Thread.self);
                fileState.pinExtra;
                return true;

            default:
                logger.notice("Unknown error while writing ", errorCode, " for ", fileState.handle, " on ", Thread.self);
                fileState.pinExtra;
                break;
            }

            return false;
        }
    } else
        assert(0);
}

bool tryReadMechanism(scope FileState* fileState, ubyte[] buffer, long position) @trusted {
    assert(buffer.length > 0);

    version(Windows) {
        import sidero.base.internal.atomic;

        if(atomicLoad(fileState.isClosed))
            return false;

        if(fileState.havePendingAlwaysWaitingRead) {
            if(CancelIoEx(fileState.handle, &fileState.alwaysReadingOverlapped) != 0) {
                logger.debug_("Successfully cancelled always reading read for file ", fileState.handle, " on ", Thread.self);

                // This is required otherwise the receive is going to fail with a very
                //  non-understandable error of: ERROR_PATH_NOT_FOUND.

                DWORD transferred;
                GetOverlappedResult(fileState.handle, &fileState.alwaysReadingOverlapped, &transferred, false);
            } else {
                auto error = GetLastError();

                switch(error) {
                case ERROR_NOT_FOUND:
                    break; // all ok, it isn't being used

                default:
                    logger.debug_("Always pending read for file ", fileState.handle, " failed to cancel ",
                            &fileState.alwaysReadingOverlapped, " with error ", GetLastError(), " on thread ", Thread.self);
                }
            }

            fileState.havePendingAlwaysWaitingRead = false;
        }

        fileState.havePendingRead = true;
        fileState.readOverlapped = OVERLAPPED.init;
        fileState.readOverlapped.Offset = cast(uint)position;
        fileState.readOverlapped.OffsetHigh = cast(uint)(position >> 32);

        auto result = ReadFile(fileState.handle, buffer.ptr, cast(uint)buffer.length, null, &fileState.readOverlapped);

        if(result != 0) {
            // completed, IOCP will be notified of completion
            logger.debug_("Immediate completion of read ", fileState.handle, " on ", Thread.self);
            fileState.pinExtra;
            return true;
        } else {
            const errorCode = GetLastError();

            switch(errorCode) {
            case ERROR_IO_PENDING:
                // this is okay, its delayed via IOCP
                logger.debug_("Reading delayed via IOCP for ", fileState.handle, " with buffer length ", buffer.length,
                        " on ", Thread.self);
                fileState.pinExtra;
                return true;

            default:
                logger.notice("Unknown error while reading ", errorCode, " for ", fileState.handle, " on ", Thread.self);
                fileState.pinExtra;
                fileState.reading.rawReadFailed(fileState);
                break;
            }

            return false;
        }
    } else
        assert(0);
}

// does not need guarding
ulong getFileSize(scope FileState* fileState) {
    version(Windows) {
        return fileState.guard(() @trusted {
            LARGE_INTEGER i;
            if(!GetFileSizeEx(fileState.handle, &i))
                return 0;

            return i.QuadPart;
        });
    } else
        assert(0);
}
