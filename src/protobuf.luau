--!strict
--!optimize 2

export type FieldType = "varint" | "string" | "message" | "map"
export type WireType = number

export type SchemaField<T = any, K = any, V = any> = {
	id: number,
	type: FieldType,
	wireType: WireType,
	messageSchema: Schema<T>?,
	keyType: FieldType?,
	valueType: FieldType?,
	_valueType: V
}

export type Schema<T = any> = { [string]: any }

local WIRE_VARINT = 0
local WIRE_STRING = 2

local function EncodeVarint(num: number): string
	local bytes: { number } = {}
	while num >= 0x80 do
		table.insert(bytes, bit32.bor(bit32.band(num, 0x7F), 0x80))
		num = bit32.rshift(num, 7)
	end
	table.insert(bytes, num)
	return string.char(unpack(bytes))
end

local function EncodeString(str: string): string
	return EncodeVarint(#str) .. str
end

local function EncodeLengthPrefixed(bytes: string): string
	return EncodeVarint(#bytes) .. bytes
end

local function DecodeVarint(bytes: string, offset: number): (number, number)
	local result = 0
	local shift = 0
	local pos = offset

	while true do
		local byte = string.byte(bytes, pos)
		if not byte then 
			error("Incomplete varint")
		end
		pos += 1

		result = bit32.bor(result, bit32.lshift(bit32.band(byte, 0x7F), shift))

		if bit32.band(byte, 0x80) == 0 then
			break
		end

		shift += 7
	end

	return result, pos
end

local function DecodeString(bytes: string, offset: number): (string, number)
	local length, pos = DecodeVarint(bytes, offset)
	if pos + length - 1 > #bytes then 
		error("String extends beyond buffer")
	end
	return string.sub(bytes, pos, pos + length - 1), pos + length
end

local function field_<T>(id: number, fieldType: FieldType, messageSchema: Schema<T>?): SchemaField<T>
	if fieldType == "message" and not messageSchema then
		error("Message type requires schema")
	end

	return {
		id = id,
		type = fieldType,
		wireType = if fieldType == "varint" then WIRE_VARINT else WIRE_STRING,
		messageSchema = messageSchema,
		keyType = nil,
		valueType = nil,
		_valueType = nil :: any
	}
end

local function map_<K, V>(
	id: number, 
	keyType: FieldType, 
	valueType: FieldType, 
	messageSchema: Schema<V>?
): SchemaField<any, K, V>
	if not ({string = true, varint = true})[keyType] then
		error("Map keys must be string or varint")
	end

	if not ({varint = true, string = true, message = true, map = true})[valueType] then
		error("Invalid map value type")
	end

	if (valueType == "message" or valueType == "map") and not messageSchema then
		error("Message/Map value type requires schema")
	end

	return {
		id = id,
		type = "map",
		wireType = WIRE_STRING,
		messageSchema = messageSchema,
		keyType = keyType,
		valueType = valueType
	} :: any
end

export type Protobuf<T> = {
	schema: Schema<T>,
	EncodeField: (self: Protobuf<T>, field: SchemaField<T>, value: any) -> string,
	DecodeField: (self: Protobuf<T>, field: SchemaField<T>, bytes: string, offset: number) -> (any, number),
	Serialize: (self: Protobuf<T>, data: T) -> string,
	Deserialize: (self: Protobuf<T>, bytes: string) -> T
} & typeof(setmetatable({}, {}))

local Protobuf = {}
Protobuf.__index = Protobuf

function Protobuf.new<T>(schema: Schema<T>): Protobuf<T>
	local self = setmetatable({
		schema = schema
	}, Protobuf) :: any
	return self
end

function Protobuf:EncodeField(field: SchemaField<any>, value: any): string
	local bytes = EncodeVarint(bit32.bor(bit32.lshift(field.id, 3), field.wireType))

	if field.type == "varint" then
		if typeof(value) ~= "number" then
			error(`Expected number for varint field, got {type(value)}`)
		end
		bytes ..= EncodeVarint(value)

	elseif field.type == "string" then
		if typeof(value) ~= "string" then
			error(`Expected string field, got {type(value)}`)
		end
		bytes ..= EncodeString(value)

	elseif field.type == "message" and field.messageSchema then
		if typeof(value) ~= "table" then
			error(`Expected table for message field, got {type(value)}`)
		end
		local nested = Protobuf.new(field.messageSchema)
		bytes ..= EncodeLengthPrefixed(nested:Serialize(value))

	elseif field.type == "map" and field.keyType and field.valueType then
		if type(value) ~= "table" then
			error(`Expected table for map field, got {typeof(value)}`)
		end
		local mapBytes = {}

		for k, v in value :: any do
			local entryBytes = {}

			if field.keyType == "string" then
				if typeof(k) ~= "string" then
					error(`Expected string key in map, got {type(k)}`)
				end
				table.insert(entryBytes, EncodeString(k))
			else
				if typeof(k) ~= "number" then
					error(`Expected number key in map, got {type(k)}`)
				end
				table.insert(entryBytes, EncodeVarint(k))
			end

			if field.valueType == "string" then
				if typeof(v) ~= "string" then
					error(`Expected string value in map, got {type(v)}`)
				end
				table.insert(entryBytes, EncodeString(v))
			elseif field.valueType == "varint" then
				if typeof(v) ~= "number" then
					error(`Expected number value in map, got {type(v)}`)
				end
				table.insert(entryBytes, EncodeVarint(v))
			elseif field.valueType == "message" and field.messageSchema then
				if typeof(v) ~= "table" then
					error(`Expected table value in map, got {type(v)}`)
				end
				local nested = Protobuf.new(field.messageSchema)
				table.insert(entryBytes, EncodeLengthPrefixed(nested:Serialize(v)))
			end

			table.insert(mapBytes, table.concat(entryBytes))
		end

		bytes ..= EncodeLengthPrefixed(table.concat(mapBytes))
	end

	return bytes
end

function Protobuf:DecodeField(field: SchemaField<any>, bytes: string, offset: number): (any, number)
	if field.type == "varint" then
		return DecodeVarint(bytes, offset)

	elseif field.type == "string" then
		return DecodeString(bytes, offset)

	elseif field.type == "message" and field.messageSchema then
		local length, pos = DecodeVarint(bytes, offset)
		local messageBytes = string.sub(bytes, pos, pos + length - 1)
		local nested = Protobuf.new(field.messageSchema)
		return nested:Deserialize(messageBytes), pos + length

	elseif field.type == "map" and field.keyType and field.valueType then
		local length, pos = DecodeVarint(bytes, offset)
		local mapBytes = string.sub(bytes, pos, pos + length - 1)
		local mapPos = 1
		local result = {}

		while mapPos <= #mapBytes do
			local key: any, value: any

			if field.keyType == "string" then
				key, mapPos = DecodeString(mapBytes, mapPos)
			else
				key, mapPos = DecodeVarint(mapBytes, mapPos)
			end

			if field.valueType == "string" then
				value, mapPos = DecodeString(mapBytes, mapPos)
			elseif field.valueType == "varint" then
				value, mapPos = DecodeVarint(mapBytes, mapPos)
			elseif field.valueType == "message" and field.messageSchema then
				local messageLength
				messageLength, mapPos = DecodeVarint(mapBytes, mapPos)
				local messageBytes = string.sub(mapBytes, mapPos, mapPos + messageLength - 1)
				local nested = Protobuf.new(field.messageSchema)
				value = nested:Deserialize(messageBytes)
				mapPos += messageLength
			end

			result[key] = value
		end

		return result, pos + length
	end

	error("Invalid field type")
end

function Protobuf:Serialize<T>(data: T): string
	local bytes = {}

	for fieldName, f in self.schema :: Schema<T> do
		if (data :: any)[fieldName] ~= nil then
			table.insert(bytes, self:EncodeField(f, (data :: any)[fieldName]))
		end
	end

	return table.concat(bytes)
end

function Protobuf:Deserialize<T>(bytes: string): T
	local pos = 1
	local result = {} :: any

	while pos <= #bytes do
		local tag, newPos = DecodeVarint(bytes, pos)
		local fieldNum = bit32.rshift(tag, 3)
		pos = newPos

		local fieldName, fi
		for name, f in self.schema :: Schema<T> do
			if f.id == fieldNum then
				fieldName = name
				fi = f
				break
			end
		end

		if fieldName and fi then
			result[fieldName], pos = self:DecodeField(fi, bytes, pos)
		end
	end

	return result :: T
end

return {
	new = Protobuf.new,
	field = field_,
	map = map_
}