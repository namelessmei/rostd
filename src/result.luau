--!optimize 2
--!strict

local Result = {}
Result.__index = Result

export type Result<T, E> = {
    ok: boolean,
    value: T?,
    error: E?,
    Unwrap: (self: Result<T, E>) -> T,
    UnwrapOr: (self: Result<T, E>, default: T) -> T,
}

export type StdError = {
    Code: number,
    Message: string,
    Context: any?
}

function Result.new<T, E>(value: T?, error: E?): Result<T, E>
    local self = setmetatable({}, Result)
    self.ok = error == nil
    self.value = value
    self.error = error
    return self :: any
end

function Result.Ok<T, E>(value: T): Result<T, E>
    return Result.new(value, nil)
end

function Result.Err<T, E>(error: E): Result<T, E>
    return Result.new(nil, error)
end

function Result.Unwrap<T, E>(self: Result<T, E>): T?
    assert(self.ok, "Called Unwrap on an Err value: " .. tostring(self.error))
    return self.value
end

function Result.UnwrapOr<T, E>(self: Result<T, E>, default: T): T
    return self.value or default
end

return Result