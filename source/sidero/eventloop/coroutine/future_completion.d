module sidero.eventloop.coroutine.future_completion;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.coroutine.condition;
import sidero.base.errors;
import sidero.base.allocators;

export @safe nothrow @nogc:

struct FutureTrigger;

/// The storage for a future trigger, matches internals of a coroutine return value.
alias FutureTriggerStorage(ResultType) = Result!ResultType;

InstanceableCoroutine!(ResultType, FutureTriggerStorage!ResultType**) acquireInstantiableFuture(ResultType)() @trusted {
    import sidero.eventloop.coroutine.internal.state;

    __gshared CoroutineDescriptor!ResultType descriptorStorage;
    __gshared CoroutineAllocatorMemoryDescriptor.FunctionPrototype[1] functionsStorage;

    typeof(return) storage;
    storage.pair = ctfeConstructExternalTriggerState!ResultType(&descriptorStorage, functionsStorage);
    storage.pair.rc(true);

    return storage;
}

ErrorResult waitOnTrigger(ResultType, TriggerStorage = FutureTriggerStorage!ResultType*)(scope Future!ResultType coroutine,
        TriggerStorage triggerStorage) @trusted {
    if(triggerStorage is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    auto co = coroutine.asGeneric();
    return waitOnTrigger(co, cast(FutureTrigger*)triggerStorage);
}

ErrorResult waitOnTrigger(scope GenericCoroutine coroutine, FutureTrigger* trigger) @trusted {
    if(trigger is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));
    else if(coroutine.isNull)
        return ErrorResult(NullPointerException("Coroutine argument is null"));

    checkInit;

    // does not need locking at this level, already handled by the map

    if(triggerableCoroutines.insert(trigger, coroutine))
        return ErrorResult.init;

    return ErrorResult(DuplicateValueException("Future trigger has already been registered"));
}

ErrorResult trigger(ResultType, TriggerStorage = FutureTriggerStorage!ResultType*)(scope TriggerStorage triggerStorage,
        scope return ErrorMessage errorMessage, string moduleName = __MODULE__, int line = __LINE__) @trusted {
    if(triggerStorage is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    *triggerStorage = Result!ResultType(result, moduleName, line);
    return trigger(cast(FutureTrigger*)triggerStorage);
}

ErrorResult trigger(ResultType, TriggerStorage = FutureTriggerStorage!ResultType*)(scope TriggerStorage triggerStorage,
        scope return ResultType result) @trusted {
    if(triggerStorage is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    *triggerStorage = result;
    return trigger(cast(FutureTrigger*)triggerStorage);
}

ErrorResult trigger(ResultType, TriggerStorage = FutureTriggerStorage!ResultType*)(scope TriggerStorage triggerStorage,
        scope return Result!ResultType result) @trusted {
    if(triggerStorage is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    *triggerStorage = result;
    return trigger(cast(FutureTrigger*)triggerStorage);
}

ErrorResult trigger(scope FutureTrigger* trigger) @trusted {
    import sidero.eventloop.internal.workers : coroutineCompletedTask;

    if(trigger is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    // We only need to lock at this level to prevent multiple threads trying to trigger the same coroutine simultaneously
    //  and hitting a mixed state.

    auto err = mutex.lock;
    logAssert(cast(bool)err, "Failed to lock", err.getError());

    GenericCoroutine coroutine;

    {
        auto got = triggerableCoroutines[trigger];
        if(!got) {
            mutex.unlock;
            return ErrorResult(got.getError());
        }

        coroutine = got.get;
    }

    const removed = triggerableCoroutines.remove(trigger);
    assert(removed);
    mutex.unlock;

    ErrorResult errorResult = coroutine.unsafeResume();
    if(!errorResult)
        return errorResult;

    coroutineCompletedTask(coroutine, ErrorResult.init);
    return ErrorResult.init;
}

unittest {
    InstanceableCoroutine!(int, FutureTriggerStorage!int**) instantiable = acquireInstantiableFuture!int();

    FutureTriggerStorage!int* triggerStorage;

    Future!int future = instantiable.makeInstance(RCAllocator.init, &triggerStorage);
    assert(!future.isNull);
    assert(!future.isComplete);
    assert(triggerStorage !is null);
    assert(future.condition.waitingOn == CoroutineCondition.WaitingOn.ExternalTrigger);

    auto errorResult = waitOnTrigger(future, triggerStorage);
    assert(errorResult);

    errorResult = trigger(triggerStorage, 3);
    assert(errorResult);
    assert(future.isComplete());

    auto got = future.result();
    assert(got);
    assert(got == 3);
}

package(sidero.eventloop) {
    void debugFutureCompletions() @trusted {
        auto err = mutex.lock;
        logAssert(cast(bool)err, "Failed to lock", err.getError());

        import sidero.base.console;

        writeln("\\/====future completions====\\/");

        foreach(trigger, co; triggerableCoroutines) {
            assert(co);
            co.debugMe("fc");
        }

        writeln("/\\==========/\\");
        mutex.unlock;
    }
}

private:
import sidero.base.containers.map.concurrenthashmap;
import sidero.base.synchronization.system.lock;
import sidero.base.internal.logassert;

void checkInit() @trusted {
    auto err = mutex.lock;
    logAssert(cast(bool)err, "Failed to lock", err.getError());

    if(triggerableCoroutines.isNull)
        triggerableCoroutines = ConcurrentHashMap!(FutureTrigger*, GenericCoroutine)();

    mutex.unlock;
}

__gshared {
    SystemLock mutex;
    ConcurrentHashMap!(FutureTrigger*, GenericCoroutine) triggerableCoroutines;
}
