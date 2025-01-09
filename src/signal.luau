--!optimize 2
--!strict

export type Connection<T...> = {
    _connected: boolean,
    _fn: (T...) -> (),
    _next: Connection<T...>?,
    _prev: Connection<T...>?,
    _signal: Signal<T...>,
    _args: { unknown }?,
    disconnect: (self: Connection<T...>) -> ()
}

export type Signal<T...> = {
    _head: Connection<T...>?,
    connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
    once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
    fire: (self: Signal<T...>, T...) -> (),
    destroy: (self: Signal<T...>) -> ()
}

local THREAD_POOL_SIZE = 256
local free_threads = table.create(THREAD_POOL_SIZE)

local function run_callback<T...>(callback: (T...) -> (), thread: thread, ...: T...): ()
    callback(...)
    table.insert(free_threads, thread)
end

local function yielder()
    while true do
        run_callback(coroutine.yield())
    end
end

for _ = 1, THREAD_POOL_SIZE do
    local thread = coroutine.create(yielder)
    coroutine.resume(thread)
    table.insert(free_threads, thread)
end

local Connection = {}
Connection.__index = Connection

function Connection.disconnect<T...>(self: Connection<T...>)
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

function Signal.connect<T...>(self: Signal<T...>, fn: (T...) -> ()): Connection<T...>
    local cn: any = setmetatable({
        _connected = true,
        _signal = self,
        _fn = fn,
        _next = self._head,
        _prev = false,
        disconnect = Connection.disconnect
    }, Connection)
    
    if self._head then
        self._head._prev = cn
    end
    self._head = cn
    return cn
end

function Signal.Once<T...>(self: Signal<T...>, fn: (T...) -> ()): Connection<T...>
    local cn
    cn = self:connect(function(...)
        if not cn._connected then 
            return
        end
        cn:disconnect()
        fn(...)
    end)
    return cn
end

function Signal.fire<T...>(self: Signal<T...>, ...)
    local cn = self._head
    local args = { ... }
    while cn do
        if cn._connected then
            local thread = table.remove(free_threads) :: thread
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

function Signal.destroy<T...>(self: Signal<T...>)
    local cn = self._head
    while cn do
        cn._connected = false
        cn = cn._next
    end
    self._head = nil
end

return Signal