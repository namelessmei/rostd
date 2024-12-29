--!strict
--!optimize 2

export type Container<T> = {
	_buffer: { T },
	_head: number,
	_tail: number,
	_size: number,
	_capacity: number,
	new: (capacity: number?) -> Container<T>,
	Push: (self: Container<T>, value: T) -> boolean,
	Pop: (self: Container<T>) -> T?,
	IsEmpty: (self: Container<T>) -> boolean,
	IsFull: (self: Container<T>) -> boolean,
	Contains: (self: Container<T>, value: T) -> boolean,
	IndexOf: (self: Container<T>, value: T) -> number,
	Clear: (self: Container<T>) -> (),
	Peek: (self: Container<T>) -> T?,
	GetSize: (self: Container<T>) -> number,
	GetCapacity: (self: Container<T>) -> number,
	ToArray: (self: Container<T>) -> { T },
}

local Container = {}
Container.__index = Container

local function NextPowerOfTwo(n: number): number
	n = n - 1
	n = bit32.bor(n, bit32.rshift(n, 1))
	n = bit32.bor(n, bit32.rshift(n, 2))
	n = bit32.bor(n, bit32.rshift(n, 4))
	n = bit32.bor(n, bit32.rshift(n, 8))
	n = bit32.bor(n, bit32.rshift(n, 16))
	return n + 1
end

function Container.new<T>(capacity: number?): Container<T>
	local requestedCapacity = capacity or 32
	local actualCapacity = NextPowerOfTwo(requestedCapacity)

	local self = setmetatable({}, Container)
	self._buffer = table.create(actualCapacity)
	self._head = 0
	self._tail = 0
	self._size = 0
	self._capacity = actualCapacity
	return self :: any
end

function Container.Push<T>(self: Container<T>, value: T): boolean
	if self:IsFull() then
		return false
	end
	self._buffer[self._tail + 1] = value
	self._tail = bit32.band(self._tail + 1, self._capacity - 1)
	self._size += 1
	return true
end

function Container.Pop<T>(self: Container<T>): T?
	if self:IsEmpty() then
		return nil
	end
	local value = self._buffer[self._head + 1]
	self._buffer[self._head + 1] = nil
	self._head = bit32.band(self._head + 1, self._capacity - 1)
	self._size -= 1
	return value
end

function Container.Peek<T>(self: Container<T>): T?
	if self:IsEmpty() then
		return nil
	end
	return self._buffer[self._head + 1]
end

function Container.IsEmpty<T>(self: Container<T>): boolean
	return self._size == 0
end

function Container.IsFull<T>(self: Container<T>): boolean
	return self._size == self._capacity
end

function Container.Contains<T>(self: Container<T>, value: T): boolean
	if self:IsEmpty() then
		return false
	end

	local index = self._head
	local count = 0
	while count < self._size do
		if self._buffer[index + 1] == value then
			return true
		end
		index = bit32.band(index + 1, self._capacity - 1)
		count += 1
	end
	return false
end

function Container.IndexOf<T>(self: Container<T>, value: T): number
	if self:IsEmpty() then
		return -1
	end

	local index = self._head
	local count = 0
	while count < self._size do
		if self._buffer[index + 1] == value then
			return count + 1
		end
		index = bit32.band(index + 1, self._capacity - 1)
		count += 1
	end
	return -1
end

function Container.Clear<T>(self: Container<T>): ()
	table.clear(self._buffer)
	self._head = 0
	self._tail = 0
	self._size = 0
end

function Container.GetSize<T>(self: Container<T>): number
	return self._size
end

function Container.GetCapacity<T>(self: Container<T>): number
	return self._capacity
end

function Container.ToArray<T>(self: Container<T>): { T }
	if self:IsEmpty() then
		return {}
	end

	local result = table.create(self._size)
	local index = self._head
	local count = 0
	while count < self._size do
		result[count + 1] = self._buffer[index + 1]
		index = bit32.band(index + 1, self._capacity - 1)
		count += 1
	end
	return result
end

function Container.__tostring<T>(self: Container<T>): string
	return string.format(
		"Container(size=%d, capacity=%d, head=%d, tail=%d)",
		self._size,
		self._capacity,
		self._head,
		self._tail
	)
end

return Container