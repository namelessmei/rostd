--!optimize 2
--!strict

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Result = require(script.Parent.result)

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
    push: (self: InputHeap, value: InputState) -> Result.Result<nil, StdError>,
    pop: (self: InputHeap) -> Result.Result<InputState, StdError>,
    peek: (self: InputHeap) -> InputState?,
    get_size: (self: InputHeap) -> number,
    get_window: (self: InputHeap, predicate: (value: InputState) -> boolean, maxResults: number?) -> Result.Result<{ InputState }, StdError>,
    heapify_up: (self: InputHeap, p: number) -> (),
    heapify_down: (self: InputHeap, p: number) -> Result.Result<nil, StdError>,
    remove_old: (self: InputHeap, threshold: number) -> ()
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

    register_input: (self: InputManager, input: Enum.UserInputType | Enum.KeyCode, flag: number) -> Result.Result<InputManager, StdError>,
    set_holdable: (self: InputManager, flag: number) -> Result.Result<InputManager, StdError>,
    bind_action: (self: InputManager, flag: number, 
        began: (input: InputState) -> ()?, 
        hold: (input: InputState) -> ()?,
        ended: (input: InputState) -> ()?
    ) -> Result.Result<InputManager, StdError>,
    unbind_action: (self: InputManager, flag: number) -> Result.Result<InputManager, StdError>,
    register_sequence: (
        self: InputManager, 
        flags: { number }, 
        timeWindowMs: number, 
        callback: (inputs: { InputState }) -> (),
        consumeInputs: boolean?
    ) -> Result.Result<SequenceHandle, StdError>,

    get_binds: (self: InputManager) -> { [number]: {
        flag: number,
        input: Enum.UserInputType | Enum.KeyCode,
        isHoldable: boolean
    } },

    get_sequences: (self: InputManager) -> { [number]: {
        flags: { number },
        timeWindowMs: number,
        consumeInputs: boolean
    } },
    process_inputs: (self: InputManager) -> (),
    init: (self: InputManager) -> Result.Result<nil, StdError>,
    destroy: (self: InputManager) -> (),
}

export type SequenceHandle = {
    unbind: (self: SequenceHandle) -> ()
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

function InputHeap.push(self: InputHeap, value: InputState): Result.Result<nil, StdError>
    if self._size >= self._capacity then
        self:pop()
    end

    self._size += 1
    self._heap[self._size] = value
    self:heapify_up(self._size)
    return Result.ok(nil)
end

function InputHeap.pop(self: InputHeap): Result.Result<InputState, StdError>
    if self._size == 0 then
        return Result.err({
            code = ERROR_CODE.HEAP_OVERFLOW, 
            message = "cannot pop from an empty heap", 
            context = { current_size = 0 }
        })
    end

    local result = self._heap[1]
    self._heap[1] = self._heap[self._size]
    self._heap[self._size] = nil
    self._size -= 1
    self:heapify_down(1)
    return Result.ok(result)
end

function InputHeap.remove_old(self: InputHeap, threshold: number): ()
    while self._size > 0 and self._heap[1].timestamp < threshold do
        self:pop()
    end
end

function InputHeap.peek(self: InputHeap): InputState?
    return self._heap[1]
end

function InputHeap.get_size(self: InputHeap): number
    return self._size
end

function InputHeap.heapify_up(self: InputHeap, index: number)
    local parent = math.floor(index / 2)
    while index > 1 and self._heap[index].timestamp < self._heap[parent].timestamp do
        self._heap[index], self._heap[parent] = self._heap[parent], self._heap[index]
        index = parent
        parent = math.floor(index / 2)
    end
end

function InputHeap.heapify_down(self: InputHeap, index: number): Result.Result<nil, StdError>
    if index < 1 or index > self._size then
        return Result.err({
            code = ERROR_CODE.INVALID_INDEX,
            message = "index out of heap bounds",
            context = { 
                index = index, 
                heap_size = self._size 
            }
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

    return Result.ok(nil)
end

function InputHeap.get_window(
    self: InputHeap, 
    predicate: (value: InputState) -> boolean,
    maxResults: number?
): Result.Result<{ InputState }, StdError>
    local result = table.create(maxResults or self._size)
    local count = 0

    if self._size == 0 then
        return Result.ok(result)
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

    return Result.ok(result)
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

function InputManager.register_input(
    self: InputManager, 
    input: Enum.UserInputType | Enum.KeyCode, 
    flag: number
): Result.Result<InputManager, StdError>
    if not flag or typeof(flag) ~= "number" or flag < 1 then
        return Result.err({
            code = ERROR_CODE.INVALID_FLAG,
            message = "invalid flag value: flag must be a positive number",
            context = { flag = flag }
        })
    end

    if self._keymap[input] then
        return Result.err({
            code = ERROR_CODE.INVALID_INPUT,
            message = "input already registered",
            context = { 
                input = input, 
                existing_flag = self._keymap[input] 
            }
        })
    end

    self._keymap[input] = flag
    return Result.ok(self)
end

function InputManager.set_holdable(self: InputManager, flag: number, remove: boolean?): Result.Result<InputManager, StdError>
    if remove then
        self._holdableFlags[flag] = nil
    else
        self._holdableFlags[flag] = true
    end
    return Result.ok(self)
end

function InputManager.bind_action(
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
    return Result.ok(self)
end

function InputManager.unbind_action(self: InputManager, flag: number): Result.Result<InputManager, StdError>
    self._binds[flag] = nil
    self._holdCallbacks[flag] = nil
    self._endCallbacks[flag] = nil
    return Result.ok(self)
end

function InputManager.get_binds(self: InputManager): { [number]: {
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

function InputManager.get_sequences(self: InputManager): { [number]: {
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

function InputManager.register_sequence(
    self: InputManager,
    flags: { number },
    timeWindowMs: number,
    callback: (inputs: { InputState }) -> (),
    consumeInputs: boolean?
): Result.Result<{ unbind: () -> () }, StdError>
    if #flags < 2 then
        return Result.err({
            code = ERROR_CODE.INVALID_SEQUENCE,
            message = "sequence must contain at least 2 inputs",
            context = { flags = flags }
        })
    end

    for _, flag in flags do
        if not (typeof(flag) == "number" and flag >= 1) then
            return Result.err({
                code = ERROR_CODE.INVALID_FLAG,
                message = "invalid flag in sequence: must be a positive number",
                context = { invalid_flag = flag }
            })
        end
    end

    local sequence_id = #self._sequences + 1
    self._sequences[sequence_id] = {
        flags = flags,
        timeWindowMs = timeWindowMs,
        callback = callback,
        consumeInputs = consumeInputs or false,
        id = sequence_id
    }

    local handle = {
        unbind = function()
            table.remove(self._sequences, sequence_id)
            for i = sequence_id, #self._sequences do
                if self._sequences[i] then
                    self._sequences[i].id = i
                end
            end
        end
    }

    return Result.ok(handle)
end

function InputManager.init(self: InputManager): Result.Result<nil, StdError>
    local input_began_connection = UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
        if gpe then return end

        local flag = self._keymap[input.KeyCode] or self._keymap[input.UserInputType]
        if not flag then return end

        local input_state: InputState = {
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

        self._activeInputs[flag] = input_state
        self._inputHeap:push(input_state)
        local began_callback = self._binds[flag]
        if began_callback and not input_state.processed then
            task.spawn(began_callback, input_state)
        end
    end)

    local input_ended_connection = UserInputService.InputEnded:Connect(function(input: InputObject, gpe: boolean)
        if gpe then return end

        local flag = self._keymap[input.KeyCode] or self._keymap[input.UserInputType]
        if not flag then return end

        local input_state = self._activeInputs[flag]
        if input_state then
            input_state.active = false
            input_state.held = false
            input_state.endTimestamp = DateTime.now().UnixTimestampMillis
            input_state.duration = ((input_state.endTimestamp :: number) - input_state.timestamp) / 1000

            local end_callback = self._endCallbacks[flag]
            if end_callback then
                task.spawn(end_callback, input_state)
            end

            self._activeInputs[flag] = nil
        end
    end)

    local heartbeat_connection = RunService.Heartbeat:Connect(function()
        local current_time = DateTime.now().UnixTimestampMillis
        if next(self._activeInputs) == nil then 
            local oldest_input = self._inputHeap:peek()
            if oldest_input and oldest_input.timestamp < (current_time - INPUT_HISTORY_MS) then
                self._inputHeap:remove_old(current_time - INPUT_HISTORY_MS)
            end
            return 
        end

        local oldest_input = self._inputHeap:peek()
        if oldest_input and oldest_input.timestamp < (current_time - INPUT_HISTORY_MS) then
            self._inputHeap:remove_old(current_time - INPUT_HISTORY_MS)
        end

        for _, sequence in self._sequences do
            local result = self._inputHeap:get_window(
                function(input: InputState)
                    return current_time - input.timestamp <= sequence.timeWindowMs 
                        and not input.processed
                end
            )

            if not result.is_ok then continue end
            local recent_inputs = result.value
            if not recent_inputs then continue end
            if #recent_inputs < #sequence.flags then continue end

            local matched_inputs = {}
            local sequence_idx = 1
            local last_match_time = 0
            for _, input in recent_inputs do
                if input.flag == sequence.flags[sequence_idx] then
                    if sequence_idx == 1 or input.timestamp > last_match_time then
                        table.insert(matched_inputs, input)
                        last_match_time = input.timestamp
                        sequence_idx += 1
                        if sequence_idx > #sequence.flags then
                            break
                        end
                    end
                end
            end

            if sequence_idx > #sequence.flags then
                if sequence.consumeInputs then
                    for _, input in matched_inputs do
                        input.processed = true
                    end
                end

                task.spawn(sequence.callback, matched_inputs)
            end
        end

        for flag, input in self._activeInputs do
            if not (input.isHoldable and input.active) then 
                continue 
            end

            if not input.holdStartTime then
                local time_since_start = current_time - input.timestamp
                if time_since_start >= HOLD_START_MS then
                    input.holdStartTime = current_time
                    input.held = true
                    input.duration = time_since_start / 1000
                end
            elseif input.held then
                local hold_callback = self._holdCallbacks[flag]
                if hold_callback then
                    local last_tick = input.lastHoldTick or input.holdStartTime
                    local time_since_tick = current_time - last_tick :: number

                    if time_since_tick >= HOLD_TICK_MS then
                        input.lastHoldTick = current_time
                        input.duration = (current_time - input.timestamp) / 1000
                        task.spawn(hold_callback, input)
                    end
                end
            end
        end
    end)

    table.insert(self._cleanup, function()
        input_began_connection:Disconnect()
        input_ended_connection:Disconnect()
        heartbeat_connection:Disconnect()
    end)
    
    return Result.ok(nil)
end

function InputManager.destroy(self: InputManager)
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