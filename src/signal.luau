--!optimize 2
--!strict

export type Connection<T...> = {
    _connected: boolean,
    _fn: (T...) -> (),
    _next: Connection<T...>?,
    _prev: Connection<T...>?,
    _signal: Signal<T...>,
    _args: { unknown }?,
    Disconnect: (self: Connection<T...>) -> ()
}

export type Signal<T...> = {
    _head: Connection<T...>?,
    Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
    Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
    Fire: (self: Signal<T...>, T...) -> (),
    Destroy: (self: Signal<T...>) -> ()
}

local THREAD_POOL_SIZE = 256
local freeThreads = table.create(THREAD_POOL_SIZE)

local function RunCallback(callback, thread, ...)
    callback(...)
    table.insert(freeThreads, thread)
end

local function Yielder()
    while true do
        RunCallback(coroutine.yield())
    end
end

for _ = 1, THREAD_POOL_SIZE do
    local thread = coroutine.create(Yielder)
    coroutine.resume(thread)
    table.insert(freeThreads, thread)
end

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect<T...>(self: Connection<T...>)
    if not self._connected then 
        return 
    end
    self._connected = false
    
    local next = self._next
    local prev = self._prev
    if next then 
        next._prev = prev 
    end
    if prev then 
        prev._next = next 
    end
    if self._signal._head == self then
        self._signal._head = next
    end
end

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
    local self = setmetatable({}, Signal)
    self._head = nil
    return self :: any
end

function Signal.Connect<T...>(self: Signal<T...>, fn: (T...) -> ()): Connection<T...>
    local cn: any = setmetatable({
        _connected = true,
        _signal = self,
        _fn = fn,
        _next = self._head,
        _prev = false,
        Disconnect = Connection.Disconnect
    }, Connection)
    
    if self._head then
        self._head._prev = cn
    end
    self._head = cn
    return cn
end

function Signal.Once<T...>(self: Signal<T...>, fn: (T...) -> ()): Connection<T...>
    local cn
    cn = self:Connect(function(...)
        if not cn._connected then 
            return
        end
        cn:Disconnect()
        fn(...)
    end)
    return cn
end

function Signal.Fire<T...>(self: Signal<T...>, ...)
    local cn = self._head
    local args = { ... }
    while cn do
        if cn._connected then
            local thread = table.remove(freeThreads) :: thread
            if not cn._args then
                task.spawn(thread, cn._fn, thread, args)
            else
                local stored = cn._args
                local len = #stored
                local count = len
                for _, v in args do
                    count += 1 
                    stored[count] = v
                end
                task.spawn(thread, cn._fn, thread, table.unpack(stored))
                for i = count, len + 1, -1 do
                    stored[i] = nil
                end
            end
        end
        cn = cn._next
    end
end

function Signal.Destroy<T...>(self: Signal<T...>)
    local cn = self._head
    while cn do
        cn._connected = false
        cn = cn._next
    end
    self._head = nil
end

return Signal