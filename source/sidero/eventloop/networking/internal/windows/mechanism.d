module sidero.eventloop.networking.internal.windows.mechanism;
import sidero.eventloop.networking.sockets;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.containers.queue.concurrentqueue;

__gshared {
    package(sidero.eventloop.networking.internal.windows) {
        LoggerReference logger;
    }

    private {
        FiFoConcurrentQueue!Socket socketRetryQueue;

        version(Windows) {
            import sidero.eventloop.internal.windows.bindings;

            HANDLE timerHandle;
        }
    }
}

@safe nothrow @nogc:

bool startUpNetworkingMechanism() @trusted {
    version(Windows) {
        {
            logger = Logger.forName(String_UTF8(__MODULE__));
            if(!logger)
                return false;

            enum WSAVersion = MAKEWORD(2, 2);

            WSADATA wsaData;
            int nResult = WSAStartup(WSAVersion, &wsaData);

            if(nResult != NO_ERROR) {
                logger.warning("Error occured while executing WSAStartup with code", WSAGetLastError(), " ", nResult);
                return false;
            } else {
                logger.info("WSA initialized successfully");
            }
        }

        {
            import sidero.eventloop.internal.event_waiting;

            // unfortunately there can be a case where sockets need to be re-triggered at a later date
            // so lets use a waitable timer object to retrigger it

            timerHandle = CreateWaitableTimerW(null, false, null);
            if(timerHandle is null) {
                logger.warning("Error occured while attempting to create a waitable timer for retrying read/write ", WSAGetLastError());
                shutdownNetworkingMechanism;
                return false;
            }

            // wait 15 seconds and then reactive every 15 seconds
            LARGE_INTEGER dueTime;
            dueTime.QuadPart = -150000000;

            if(SetWaitableTimer(timerHandle, &dueTime, 15_000, null, null, false) == 0) {
                logger.warning("Error occured while attempting to set time timer for retrying read/write ", WSAGetLastError());
                shutdownNetworkingMechanism;
                return false;
            }

            addEventWaiterHandle(timerHandle, &onTimerFunction, null);
        }

        return true;
    } else
        assert(0);
}

void shutdownNetworkingMechanism() @trusted {
    version(Windows) {
        {
            WSACleanup;
            logger.info("WSA uninitialized");
        }

        if(timerHandle !is null) {
            import sidero.eventloop.internal.event_waiting;

            removeEventWaiterHandle(timerHandle);
            CloseHandle(timerHandle);
        }
    } else
        assert(0);
}

void addSocketToRetrigger(Socket socket) @trusted {
    version(Windows) {
        socketRetryQueue.push(socket);
    } else
        assert(0);
}

private:

void onTimerFunction(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version(Windows) {
        while(!socketRetryQueue.empty) {
            auto got = socketRetryQueue.pop;
            if(got) {
                got.state.haveBeenRetriggered(got.state);
            }
        }
    } else
        assert(0);
}
