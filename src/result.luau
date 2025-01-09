--!optimize 2
--!strict

local Result = {}
Result.__index = Result

export type Result<T, E> = {
    is_ok: boolean,
    value: T?,
    error: E?,
    unwrap: (self: Result<T, E>) -> T,
    unwrap_or: (self: Result<T, E>, default: T) -> T,
}

export type StdError = {
    code: number,
    message: string,
    context: any?
}

function Result.new<T, E>(value: T?, error: E?): Result<T, E>
    local self = setmetatable({}, Result)
    self.is_ok = error == nil
    self.value = value
    self.error = error
    return self :: any
end

function Result.ok<T, E>(value: T): Result<T, E>
    return Result.new(value, nil)
end

function Result.err<T, E>(error: E): Result<T, E>
    return Result.new(nil, error)
end

function Result.unwrap<T, E>(self: Result<T, E>): T
    if not self.is_ok then
        error(string.format(
            "Attempted to unwrap an Err value: %s", 
            self.error and tostring(self.error) or "Unknown error"
        ), 2)
    end
    return self.value :: T
end

function Result.unwrap_or<T, E>(self: Result<T, E>, default: T): T
    return self.value or default
end

return Result