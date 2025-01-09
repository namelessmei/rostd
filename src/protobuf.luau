--!optimize 2
--!native
--!strict

local bit = bit32
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local floor, abs = math.floor, math.abs
local char, byte, sub = string.char, string.byte, string.sub
local concat, insert = table.concat, table.insert

local TYPE = {
	NIL = 0,
	NUMBER = 1,
	BOOL = 2,
	STRING = 3,
	TABLE = 4,
	ARRAY = 5,
	STRING_REF = 6,
	RLE = 7
}

local NUMBER_FORMAT = {
	INT32 = 0,
	FLOAT = 1
}

local SHORT_STRING_MAX = 31
local MEDIUM_STRING_MAX = 255
local RLE_MIN_LENGTH = 4

local function write_varint(binary: { string }, value: number)
	while value >= 0x80 do
		insert(binary, char(bor(band(value, 0x7F), 0x80)))
		value = rshift(value, 7)
	end
	insert(binary, char(value))
end

local function read_varint(str: string, offset: number): (number, number)
	local result, shift = 0, 0
	local b
	repeat
		b = byte(str, offset)
		result = bor(result, lshift(band(b, 0x7F), shift))
		shift = shift + 7
		offset = offset + 1
	until band(b, 0x80) == 0
	return result, offset
end

local encode_nil = function(): string
	return char(lshift(TYPE.NIL, 5)) 
end

local decode_nil = function(_: string, offset: number): (nil, number)
	return nil, offset + 1 
end

local encode_bool = function(value: boolean): string
	return char(bor(lshift(TYPE.BOOL, 5), value and 1 or 0))
end

local decode_bool = function(binary_str: string, offset: number): (boolean, number)
	return band(byte(binary_str, offset), 1) == 1, offset + 1
end

local function encode_number(num: number): string
	if num % 1 == 0 and abs(num) <= 0x7FFFFFFF then
		local binary = {
			char(bor(lshift(TYPE.NUMBER, 5), num < 0 and 0x10 or 0)),
			char(NUMBER_FORMAT.INT32)
		}
		write_varint(binary, abs(num))
		return concat(binary)
	end
	return char(bor(lshift(TYPE.NUMBER, 5), num < 0 and 0x10 or 0)) ..
		char(NUMBER_FORMAT.FLOAT) ..
		string.pack("<d", num)
end

local function decode_number(binary_str: string, offset: number): (number, number)
	local is_negative = band(byte(binary_str, offset), 0x10) ~= 0
	local format = byte(binary_str, offset + 1)

	if format == NUMBER_FORMAT.INT32 then
		local magnitude, new_offset = read_varint(binary_str, offset + 2)
		return (is_negative and -magnitude or magnitude), new_offset
	end
	return string.unpack("<d", sub(binary_str, offset + 2, offset + 9)), offset + 10
end

local function encode_string(str: string, string_pool: { string }): string
	local len = #str
	local ref_index = table.find(string_pool, str)
	if len <= SHORT_STRING_MAX then
		return char(bor(lshift(TYPE.STRING, 5), len)) .. str
	end

	if ref_index then
		local header = char(lshift(TYPE.STRING_REF, 5))
		local ref = ref_index > 255 
			and string.pack("<H", ref_index - 1) 
			or char(ref_index - 1)
		return header .. ref
	end

	if len <= MEDIUM_STRING_MAX then
		return char(bor(lshift(TYPE.STRING, 5), 0)) .. char(len) .. str
	end

	table.insert(string_pool, str)
	local ref_i = #string_pool
	local header = char(lshift(TYPE.STRING_REF, 5))
	local ref = ref_i > 255 
		and string.pack("<H", ref_i - 1) 
		or char(ref_i - 1)
	return header .. ref
end

local function decode_string(binary_str: string, offset: number, string_pool: { string }): (string, number)
	local header = byte(binary_str, offset)
	if not header then
		error(string.format("Failed to read header byte at offset %d", offset))
	end
	local type_bits = rshift(header, 5)

	if type_bits == TYPE.STRING then
		local len = band(header, 0x1F)
		if len == 0 then
			return "", offset + 1
		end

		local str = sub(binary_str, offset + 1, offset + len)
		if #str ~= len then
			error(string.format("String length mismatch: expected %d, got %d", len, #str))
		end
		return str, offset + len + 1
	end

	if type_bits == TYPE.STRING_REF then
		local next_byte = byte(binary_str, offset + 1)
		if not next_byte then
			error(string.format("Failed to read reference byte at offset %d", offset + 1))
		end
		if next_byte > 255 then
			local ref_index = string.unpack("<H", sub(binary_str, offset + 1, offset + 2)) + 1
			if not string_pool[ref_index] then
				error(string.format("Invalid string reference: %d (pool size: %d)", ref_index, #string_pool))
			end
			return string_pool[ref_index], offset + 3
		else
			local ref_index = next_byte + 1
			if not string_pool[ref_index] then
				error(string.format("Invalid string reference: %d (pool size: %d)", ref_index, #string_pool))
			end
			return string_pool[ref_index], offset + 2
		end
	end
	error(string.format("Invalid string type bits: %d at offset %d", type_bits, offset))
end

function is_array<T>(tbl: { T }): (boolean, number)
	local len = 0
	for k, _ in tbl do
		if type(k) ~= "number" or k ~= floor(k) or k < 1 then
			return false, 0
		end
		len = math.max(len, k)
	end
	for i = 1, len do
		if tbl[i] == nil then return false, 0 end
	end
	return true, len
end

local function try_rle<T>(arr: { T }, start: number): (boolean, number, any)
	local value = arr[start]
	local length = 1
	local i = start + 1
	while i <= #arr and arr[i] == value do
		length += 1
		i += 1
	end
	return length >= RLE_MIN_LENGTH, length, value
end

local function encode_array<T>(arr: { T }, string_pool: { string }): string
	local binary = {}
	insert(binary, char(lshift(TYPE.ARRAY, 5)))
	write_varint(binary, #arr)

	local i = 1
	while i <= #arr do
		local can_rle, rle_len, rle_value = try_rle(arr, i)
		if can_rle then
			insert(binary, char(lshift(TYPE.RLE, 5)))
			write_varint(binary, rle_len)
			insert(binary, encode_value(rle_value, string_pool))
			i += rle_len
		else
			insert(binary, encode_value(arr[i], string_pool))
			i += 1
		end
	end

	return concat(binary)
end

function encode_table<T>(tbl: { T }, string_pool: { string }): string
	local is_arr, _ = is_array(tbl)
	if is_arr then
		return encode_array(tbl, string_pool)
	end

	local binary = {}
	local count = 0
	local keys = {}
	for k, _ in tbl do
		count += 1
		insert(keys, k)
	end

	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		return a < b
	end)

	insert(binary, char(lshift(TYPE.TABLE, 5)))
	write_varint(binary, count)

	for _, k in keys do
		insert(binary, encode_value(k, string_pool))
		insert(binary, encode_value(tbl[k], string_pool))
	end

	return concat(binary)
end

function decode_array(binary_str: string, offset: number, length: number, string_pool: { string }): ({ any }, number)
	local arr = {}
	local idx = offset

	local i = 1
	while i <= length do
		local val_type = rshift(byte(binary_str, idx), 5)

		if val_type == TYPE.RLE then
			local run_length
			run_length, idx = read_varint(binary_str, idx + 1)
			local value
			value, idx = decode_value(binary_str, idx, string_pool)
			for j = 1, run_length do
				arr[i + j - 1] = value
			end
			i += run_length
		else
			local value
			value, idx = decode_value(binary_str, idx, string_pool)
			arr[i] = value
			i += 1
		end
	end

	return arr, idx
end

function decode_table(binary_str: string, offset: number, string_pool: { string }): ({ any }, number)
	local type_byte = byte(binary_str, offset)
	local is_arr = type_byte == lshift(TYPE.ARRAY, 5)
	local idx = offset + 1
	local count
	count, idx = read_varint(binary_str, idx)

	if is_arr then
		return decode_array(binary_str, idx, count, string_pool)
	end

	local tbl = {}
	for _ = 1, count do
		local key, value
		key, idx = decode_value(binary_str, idx, string_pool)
		value, idx = decode_value(binary_str, idx, string_pool)
		tbl[key] = value
	end

	return tbl, idx
end

function encode_value(v: any, string_pool: { string }): string
	local t = typeof(v)
	if t == "nil" then 
		return encode_nil()
	elseif t == "boolean" then 
		return encode_bool(v)
	elseif t == "number" then 
		return encode_number(v)
	elseif t == "string" then 
		return encode_string(v, string_pool)
	elseif t == "table" then 
		return encode_table(v, string_pool)
	else
		error(string.format("Unsupported type: %s", t))
	end
end

function decode_value(binary_str: string, offset: number, string_pool: { string }): (any, number)
	local val_type = rshift(byte(binary_str, offset), 5)
	if val_type == TYPE.NIL then 
		return decode_nil(binary_str, offset)
	elseif val_type == TYPE.BOOL then 
		return decode_bool(binary_str, offset)
	elseif val_type == TYPE.NUMBER then 
		return decode_number(binary_str, offset)
	elseif val_type == TYPE.STRING or val_type == TYPE.STRING_REF then 
		return decode_string(binary_str, offset, string_pool)
	elseif val_type == TYPE.TABLE or val_type == TYPE.ARRAY then 
		return decode_table(binary_str, offset, string_pool)
	end

	error(string.format("Unknown type: %d", val_type))
end

local string_pool = {}

local function encode(value: any): string
	return encode_value(value, string_pool)
end

local function decode(binary_str: string, offset: number?): any
	return decode_value(binary_str, offset or 1, string_pool)
end

return {
	encode = encode,
	decode = decode
}