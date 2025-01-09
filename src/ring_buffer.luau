--!strict
--!optimize 2

export type Container<T> = {
	_buffer: { T },
	_head: number,
	_tail: number,
	_size: number,
	_capacity: number,
	new: (capacity: number?) -> Container<T>,
	push: (self: Container<T>, value: T) -> boolean,
	pop: (self: Container<T>) -> T?,
	is_empty: (self: Container<T>) -> boolean,
	is_full: (self: Container<T>) -> boolean,
	contains: (self: Container<T>, value: T) -> boolean,
	index_of: (self: Container<T>, value: T) -> number,
	clear: (self: Container<T>) -> (),
	peek: (self: Container<T>) -> T?,
	get_size: (self: Container<T>) -> number,
	get_capacity: (self: Container<T>) -> number,
	to_array: (self: Container<T>) -> { T },
}

local Container = {}
Container.__index = Container

local function next_pow_of_2(n: number): number
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
	local actualCapacity = next_pow_of_2(requestedCapacity)

	local self = setmetatable({}, Container)
	self._buffer = table.create(actualCapacity)
	self._head = 0
	self._tail = 0
	self._size = 0
	self._capacity = actualCapacity
	return self :: any
end

function Container.push<T>(self: Container<T>, value: T): boolean
	if self:is_full() then
		return false
	end
	self._buffer[self._tail + 1] = value
	self._tail = bit32.band(self._tail + 1, self._capacity - 1)
	self._size += 1
	return true
end

function Container.pop<T>(self: Container<T>): T?
	if self:is_empty() then
		return nil
	end
	local value = self._buffer[self._head + 1]
	self._buffer[self._head + 1] = nil
	self._head = bit32.band(self._head + 1, self._capacity - 1)
	self._size -= 1
	return value
end

function Container.Peek<T>(self: Container<T>): T?
	if self:is_empty() then
		return nil
	end
	return self._buffer[self._head + 1]
end

function Container.is_empty<T>(self: Container<T>): boolean
	return self._size == 0
end

function Container.is_full<T>(self: Container<T>): boolean
	return self._size == self._capacity
end

function Container.contains<T>(self: Container<T>, value: T): boolean
	if self:is_empty() then
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

function Container.index_of<T>(self: Container<T>, value: T): number
	if self:is_empty() then
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

function Container.clear<T>(self: Container<T>): ()
	table.clear(self._buffer)
	self._head = 0
	self._tail = 0
	self._size = 0
end

function Container.get_size<T>(self: Container<T>): number
	return self._size
end

function Container.get_capacity<T>(self: Container<T>): number
	return self._capacity
end

function Container.to_array<T>(self: Container<T>): { T }
	if self:is_empty() then
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