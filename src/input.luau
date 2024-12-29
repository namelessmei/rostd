--!optimize 2
--!strict

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Result = require("@std/result")

export type InputState = {
    flag: number,
    timestamp: number,
    processed: boolean,
    held: boolean,
    duration: number?,
    combo: number?,
    holdStartTime: number?,
    lastHoldTick: number?,
    isHoldable: boolean,
    active: boolean,
    endTimestamp: number?,
    inputType: (Enum.UserInputType | Enum.KeyCode)?
}

export type InputHeap = {
    _heap: { InputState },
    _size: number,
    _capacity: number,
    Push: (self: InputHeap, value: InputState) -> Result.Result<nil, StdError>,
    Pop: (self: InputHeap) -> Result.Result<InputState, StdError>,
    Peek: (self: InputHeap) -> InputState?,
    GetSize: (self: InputHeap) -> number,
    GetWindow: (self: InputHeap, predicate: (value: InputState) -> boolean, maxResults: number?) -> Result.Result<{ InputState }, StdError>,
    HeapifyUp: (self: InputHeap, p: number) -> (),
    HeapifyDown: (self: InputHeap, p: number) -> Result.Result<nil, StdError>,
    RemoveOld: (self: InputHeap, threshold: number) -> ()
}

export type InputManager = {
    _inputHeap: InputHeap,
    _binds: { [number]: (input: InputState) -> () },
    _holdCallbacks: { [number]: (input: InputState) -> () },
    _endCallbacks: { [number]: (input: InputState) -> () },
    _keymap: { [Enum.UserInputType | Enum.KeyCode]: number },
    _holdableFlags: { [number]: boolean },
    _activeInputs: { [number]: InputState },
    _sequences: { InputSequence },
    _cleanup: { () -> () },

    RegisterInput: (self: InputManager, input: Enum.UserInputType | Enum.KeyCode, flag: number) -> Result.Result<InputManager, StdError>,
    SetHoldable: (self: InputManager, flag: number) -> Result.Result<InputManager, StdError>,
    BindAction: (self: InputManager, flag: number, 
        began: (input: InputState) -> ()?, 
        hold: (input: InputState) -> ()?,
        ended: (input: InputState) -> ()?
    ) -> Result.Result<InputManager, StdError>,
    UnbindAction: (self: InputManager, flag: number) -> Result.Result<InputManager, StdError>,
    RegisterSequence: (
        self: InputManager, 
        flags: { number }, 
        timeWindowMs: number, 
        callback: (inputs: { InputState }) -> (),
        consumeInputs: boolean?
    ) -> Result.Result<SequenceHandle, StdError>,

    GetBinds: (self: InputManager) -> { [number]: {
        flag: number,
        input: Enum.UserInputType | Enum.KeyCode,
        isHoldable: boolean
    } },

    GetSequences: (self: InputManager) -> { [number]: {
        flags: { number },
        timeWindowMs: number,
        consumeInputs: boolean
    } },
    ProcessInputs: (self: InputManager) -> (),
    Init: (self: InputManager) -> Result.Result<nil, StdError>,
    Destroy: (self: InputManager) -> (),
}

export type SequenceHandle = {
    Unbind: (self: SequenceHandle) -> ()
}

export type InputSequence = {
    flags: { number },
    timeWindowMs: number,
    callback: (inputs: { InputState }) -> (),
    consumeInputs: boolean,
    id: number
}

export type StdError = Result.StdError

local HOLD_START_DURATION = 0.5
local HOLD_TICK_INTERVAL = 0.1
local HOLD_START_MS = HOLD_START_DURATION * 1000
local HOLD_TICK_MS = HOLD_TICK_INTERVAL * 1000
local INPUT_HISTORY_MS = 5000

local ERROR_CODE = {
    INVALID_INPUT = 1,
    HEAP_OVERFLOW = 2,
    INVALID_FLAG = 3,
    NOT_INITIALIZED = 4,
    ALREADY_INITIALIZED = 5,
    INVALID_INDEX = 6,
    INVALID_SEQUENCE = 7
}

local InputHeap = {}
InputHeap.__index = InputHeap

function InputHeap.new(capacity: number): InputHeap
    return setmetatable({
        _heap = table.create(capacity),
        _size = 0,
        _capacity = capacity
    }, InputHeap) :: any
end

function InputHeap.Push(self: InputHeap, value: InputState): Result.Result<nil, StdError>
    if self._size >= self._capacity then
        self:Pop()
    end

    self._size += 1
    self._heap[self._size] = value
    self:HeapifyUp(self._size)
    return Result.Ok(nil)
end

function InputHeap.Pop(self: InputHeap): Result.Result<InputState, StdError>
    if self._size == 0 then
        return Result.Err({ Code = ERROR_CODE.HEAP_OVERFLOW, Message = "Heap is empty" })
    end

    local result = self._heap[1]
    self._heap[1] = self._heap[self._size]
    self._heap[self._size] = nil
    self._size -= 1
    self:HeapifyDown(1)
    return Result.Ok(result)
end

function InputHeap.RemoveOld(self: InputHeap, threshold: number): ()
    while self._size > 0 and self._heap[1].timestamp < threshold do
        self:Pop()
    end
end

function InputHeap.Peek(self: InputHeap): InputState?
    return self._heap[1]
end

function InputHeap.GetSize(self: InputHeap): number
    return self._size
end

function InputHeap.HeapifyUp(self: InputHeap, index: number)
    local parent = math.floor(index / 2)
    while index > 1 and self._heap[index].timestamp < self._heap[parent].timestamp do
        self._heap[index], self._heap[parent] = self._heap[parent], self._heap[index]
        index = parent
        parent = math.floor(index / 2)
    end
end

function InputHeap.HeapifyDown(self: InputHeap, index: number): Result.Result<nil, StdError>
    if index < 1 or index > self._size then
        return Result.Err({
            Code = ERROR_CODE.INVALID_INDEX,
            Message = "Index out of bounds",
            Context = { index = index, size = self._size }
        })
    end

    local heap = self._heap
    local size = self._size

    while true do
        local smallest = index
        local left = 2 * index
        local right = left + 1

        if left <= size and heap[left].timestamp < heap[smallest].timestamp then
            smallest = left
        end

        if right <= size and heap[right].timestamp < heap[smallest].timestamp then
            smallest = right
        end

        if smallest == index then
            break
        end

        heap[index], heap[smallest] = heap[smallest], heap[index]
        index = smallest
    end

    return Result.Ok(nil)
end

function InputHeap.GetWindow(
    self: InputHeap, 
    predicate: (value: InputState) -> boolean,
    maxResults: number?
): Result.Result<{ InputState }, StdError>
    local result = table.create(maxResults or self._size)
    local count = 0

    if self._size == 0 then
        return Result.Ok(result)
    end
    
    for i = 1, self._size do
        local input = self._heap[i]
        if predicate(input) then
            count += 1
            result[count] = input
            if maxResults and count >= maxResults then
                break
            end
        end
    end
    for i = count + 1, #result do
        result[i] = nil
    end

    return Result.Ok(result)
end

local InputManager = {}
InputManager.__index = InputManager

function InputManager.new(): InputManager
    local self = setmetatable({
        _inputHeap = InputHeap.new(32),
        _binds = {},
        _holdCallbacks = {},
        _endCallbacks = {},
        _keymap = {},
        _holdableFlags = {},
        _activeInputs = {},
        _cleanup = {},
        _sequences = {}
    }, InputManager)
    return self :: any
end

function InputManager.RegisterInput(
    self: InputManager, 
    input: Enum.UserInputType | Enum.KeyCode, 
    flag: number
): Result.Result<InputManager, StdError>
    if not flag or typeof(flag) ~= "number" or flag < 1 then
        return Result.Err({
            Code = ERROR_CODE.INVALID_FLAG,
            Message = "Invalid flag value",
            Context = { flag = flag }
        })
    end

    if self._keymap[input] then
        return Result.Err({
            Code = ERROR_CODE.INVALID_INPUT,
            Message = "Input already registered",
            Context = { input = input, existingFlag = self._keymap[input] }
        })
    end

    self._keymap[input] = flag
    return Result.Ok(self)
end

function InputManager.SetHoldable(self: InputManager, flag: number, remove: boolean?): Result.Result<InputManager, StdError>
	if remove then
		self._holdableFlags[flag] = nil
	else
		self._holdableFlags[flag] = true
	end
	return Result.Ok(self)
 end

function InputManager.BindAction(
    self: InputManager, 
    flag: number, 
    began: ((input: InputState) -> ())?,
    hold: ((input: InputState) -> ())?,
    ended: ((input: InputState) -> ())?
): Result.Result<InputManager, StdError>
    if began then
        self._binds[flag] = began
    end
    if hold then
        self._holdCallbacks[flag] = hold
    end
    if ended then
        self._endCallbacks[flag] = ended
    end
	return Result.Ok(self)
end

function InputManager.UnbindAction(self: InputManager, flag: number): Result.Result<InputManager, StdError>
    self._binds[flag] = nil
    self._holdCallbacks[flag] = nil
    self._endCallbacks[flag] = nil
	return Result.Ok(self)
end

function InputManager.GetBinds(self: InputManager): { [number]: {
	flag: number,
	input: Enum.UserInputType | Enum.KeyCode,
	isHoldable: boolean
} }
    local binds = {}
    for input, flag in self._keymap do
        table.insert(binds, {
            flag = flag,
            input = input,
            isHoldable = self._holdableFlags[flag] or false
        })
    end
    return binds
end

function InputManager.GetSequences(self: InputManager): { [number]: {
	flags: { number },
	timeWindowMs: number,
	consumeInputs: boolean
} }
    local sequences = {}
    for _, seq in self._sequences do
        table.insert(sequences, {
            flags = table.clone(seq.flags),
            timeWindowMs = seq.timeWindowMs,
            consumeInputs = seq.consumeInputs
        })
    end
    return sequences
end

function InputManager.RegisterSequence(
    self: InputManager,
    flags: { number },
    timeWindowMs: number,
    callback: (inputs: { InputState }) -> (),
    consumeInputs: boolean?
): Result.Result<{ Unbind: () -> () }, StdError>
    if #flags < 2 then
        return Result.Err({
            Code = ERROR_CODE.INVALID_SEQUENCE,
            Message = "Sequence must contain at least 2 inputs",
            Context = { flags = flags }
        })
    end

    for _, flag in flags do
        if not (typeof(flag) == "number" and flag >= 1) then
            return Result.Err({
                Code = ERROR_CODE.INVALID_FLAG,
                Message = "Invalid flag in sequence",
                Context = { invalidFlag = flag }
            })
        end
    end

    local sequenceId = #self._sequences + 1
    self._sequences[sequenceId] = {
        flags = flags,
        timeWindowMs = timeWindowMs,
        callback = callback,
        consumeInputs = consumeInputs or false,
        id = sequenceId
    }

    local handle = {
        Unbind = function()
            table.remove(self._sequences, sequenceId)
            for i = sequenceId, #self._sequences do
                if self._sequences[i] then
                    self._sequences[i].id = i
                end
            end
        end
    }

    return Result.Ok(handle)
end

function InputManager.Init(self: InputManager): Result.Result<nil, StdError>
    local inputBeganConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
        if gpe then return end

        local flag = self._keymap[input.KeyCode] or self._keymap[input.UserInputType]
        if not flag then return end

        local inputState: InputState = {
            flag = flag,
            timestamp = DateTime.now().UnixTimestampMillis,
            processed = false,
            held = false,
            duration = nil,
            combo = nil,
            holdStartTime = nil,
            lastHoldTick = nil,
            isHoldable = self._holdableFlags[flag] or false,
            active = true,
            endTimestamp = nil,
            inputType = input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode or input.UserInputType
        }

        self._activeInputs[flag] = inputState
        self._inputHeap:Push(inputState)
        local beganCallback = self._binds[flag]
        if beganCallback and not inputState.processed then
            task.spawn(beganCallback, inputState)
        end
    end)

    local inputEndedConnection = UserInputService.InputEnded:Connect(function(input: InputObject, gpe: boolean)
        if gpe then return end

        local flag = self._keymap[input.KeyCode] or self._keymap[input.UserInputType]
        if not flag then return end

        local inputState = self._activeInputs[flag]
        if inputState then
            inputState.active = false
            inputState.held = false
            inputState.endTimestamp = DateTime.now().UnixTimestampMillis
            inputState.duration = ((inputState.endTimestamp :: number) - inputState.timestamp) / 1000

            local endCallback = self._endCallbacks[flag]
            if endCallback then
                task.spawn(endCallback, inputState)
            end

            self._activeInputs[flag] = nil
        end
    end)

    local heartbeatConnection = RunService.Heartbeat:Connect(function()
        local currentTime = DateTime.now().UnixTimestampMillis
		if next(self._activeInputs) == nil then 
			local oldestInput = self._inputHeap:Peek()
			if oldestInput and oldestInput.timestamp < (currentTime - INPUT_HISTORY_MS) then
				self._inputHeap:RemoveOld(currentTime - INPUT_HISTORY_MS)
			end
			return 
		end

		local oldestInput = self._inputHeap:Peek()
		if oldestInput and oldestInput.timestamp < (currentTime - INPUT_HISTORY_MS) then
			self._inputHeap:RemoveOld(currentTime - INPUT_HISTORY_MS)
		end

		for _, sequence in self._sequences do
			local result = self._inputHeap:GetWindow(
				function(input: InputState)
					return currentTime - input.timestamp <= sequence.timeWindowMs 
						and not input.processed
				end
			)

			if not result.ok then continue end
			local recentInputs = result.value
			if not recentInputs then continue end
			if #recentInputs < #sequence.flags then continue end

			local matchedInputs = {}
			local sequenceIdx = 1
			local lastMatchTime = 0
			for _, input in recentInputs do
				if input.flag == sequence.flags[sequenceIdx] then
					if sequenceIdx == 1 or input.timestamp > lastMatchTime then
						table.insert(matchedInputs, input)
						lastMatchTime = input.timestamp
						sequenceIdx += 1
						if sequenceIdx > #sequence.flags then
							break
						end
					end
				end
			end

			if sequenceIdx > #sequence.flags then
				if sequence.consumeInputs then
					for _, input in matchedInputs do
						input.processed = true
					end
				end

				task.spawn(sequence.callback, matchedInputs)
			end
		end

		for flag, input in self._activeInputs do
			if not (input.isHoldable and input.active) then 
				continue 
			end

			if not input.holdStartTime then
				local timeSinceStart = currentTime - input.timestamp
				if timeSinceStart >= HOLD_START_MS then
					input.holdStartTime = currentTime
					input.held = true
					input.duration = timeSinceStart / 1000
				end
			elseif input.held then
				local holdCallback = self._holdCallbacks[flag]
				if holdCallback then
					local lastTick = input.lastHoldTick or input.holdStartTime
					local timeSinceTick = currentTime - lastTick :: number

					if timeSinceTick >= HOLD_TICK_MS then
						input.lastHoldTick = currentTime
						input.duration = (currentTime - input.timestamp) / 1000
						task.spawn(holdCallback, input)
					end
				end
			end
		end
    end)

    table.insert(self._cleanup, function()
        inputBeganConnection:Disconnect()
        inputEndedConnection:Disconnect()
        heartbeatConnection:Disconnect()
    end)
    
    return Result.Ok(nil)
end

function InputManager.Destroy(self: InputManager)
    for _, cleanup in self._cleanup do
        cleanup()
    end
    table.clear(self._cleanup)
    table.clear(self._activeInputs)
    table.clear(self._binds)
    table.clear(self._holdCallbacks)
    table.clear(self._endCallbacks)
end

return InputManager