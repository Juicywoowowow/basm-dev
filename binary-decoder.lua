--[[
    BASM Binary Decoder
    Decodes .basmb binary format back to runtime-compatible structure
    
    Returns data in the same format as the text parser would produce,
    allowing the runtime to execute binary files directly.
]]

local BinaryDecoder = {}
BinaryDecoder.__index = BinaryDecoder

-- Opcode to mnemonic mapping (reverse of encoder)
local OPCODES_REVERSE = {
    [0x01] = "mov",
    [0x02] = "data.load",
    [0x10] = "ld.i64",
    [0x11] = "ld.i32",
    [0x20] = "st.i64",
    [0x21] = "st.i32",
    [0x28] = "heap.alloc",
    [0x29] = "heap.realloc",
    [0x30] = "add",
    [0x31] = "sub",
    [0x32] = "mul",
    [0x33] = "div",
    [0x34] = "rem",
    [0x35] = "neg",
    [0x36] = "inc",
    [0x37] = "dec",
    [0x40] = "and",
    [0x41] = "or",
    [0x42] = "xor",
    [0x43] = "not",
    [0x44] = "shl",
    [0x45] = "shr",
    [0x50] = "cmp",
    [0x51] = "setz",
    [0x52] = "setnz",
    [0x53] = "setl",
    [0x54] = "setle",
    [0x55] = "setg",
    [0x56] = "setge",
    [0x60] = "jmp",
    [0x61] = "jz",
    [0x62] = "jnz",
    [0x63] = "jl",
    [0x64] = "jle",
    [0x65] = "jg",
    [0x66] = "jge",
    [0x70] = "call",
    [0x71] = "ret",
    [0x72] = "func.addr",
    [0x73] = "call.indirect",
    [0x80] = "console.log.str",
    [0x81] = "console.log.val",
    [0x82] = "console.log.space",
    [0x83] = "console.log.newline",
    [0x90] = "str.concat",
    [0xFF] = "nop",
}

function BinaryDecoder.new()
    local self = setmetatable({}, BinaryDecoder)
    self.data = nil
    self.pos = 1
    self.strings = {}       -- index -> string value
    self.stringNames = {}   -- index -> name (for data.load references)
    self.functions = {}     -- name -> function data
    self.functionList = {}  -- ordered list
    self.exports = {}       -- alias -> internal name
    return self
end

-- Read a single byte
function BinaryDecoder:readByte()
    if self.pos > #self.data then
        error("Unexpected end of binary data at position " .. self.pos)
    end
    local b = self.data:byte(self.pos)
    self.pos = self.pos + 1
    return b
end

-- Read u16 little-endian
function BinaryDecoder:readU16()
    local lo = self:readByte()
    local hi = self:readByte()
    return lo + hi * 256
end

-- Read u32 little-endian
function BinaryDecoder:readU32()
    local b0 = self:readByte()
    local b1 = self:readByte()
    local b2 = self:readByte()
    local b3 = self:readByte()
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

-- Read i32 little-endian (signed)
function BinaryDecoder:readI32()
    local u = self:readU32()
    if u >= 2147483648 then
        return u - 4294967296
    end
    return u
end

-- Read length-prefixed string
function BinaryDecoder:readString()
    local len = self:readU16()
    local chars = {}
    for i = 1, len do
        table.insert(chars, string.char(self:readByte()))
    end
    return table.concat(chars)
end

-- Decode binary data and return runtime-compatible structure
function BinaryDecoder:decode(binaryData)
    self.data = binaryData
    self.pos = 1
    
    -- Read and verify header
    local magic = self:readString4()
    if magic ~= "BASM" then
        error("Invalid BASM binary: bad magic number '" .. magic .. "'")
    end
    
    local version = self:readU32()
    -- Version check (we support 1.0.x)
    local majorVersion = math.floor(version / 65536)
    if majorVersion ~= 1 then
        error("Unsupported BASM version: " .. majorVersion)
    end
    
    -- Read sections
    while self.pos <= #self.data do
        local sectionId = self:readByte()
        local sectionLen = self:readU32()
        local sectionEnd = self.pos + sectionLen
        
        if sectionId == 0x01 then
            self:decodeStringsSection()
        elseif sectionId == 0x02 then
            self:decodeFunctionsSection()
        elseif sectionId == 0x03 then
            self:decodeExportsSection()
        elseif sectionId == 0x05 then
            self:decodeCodeSection()
        else
            -- Skip unknown section
            self.pos = sectionEnd
        end
    end
    
    return {
        strings = self.strings,
        stringNames = self.stringNames,
        functions = self.functions,
        exports = self.exports,
    }
end

function BinaryDecoder:readString4()
    local chars = {}
    for i = 1, 4 do
        table.insert(chars, string.char(self:readByte()))
    end
    return table.concat(chars)
end

function BinaryDecoder:decodeStringsSection()
    local count = self:readU16()
    for i = 1, count do
        local str = self:readString()
        self.strings[i - 1] = str
        -- Generate a name like "str_1", "str_2", etc.
        self.stringNames[i - 1] = "str_" .. i
    end
end

function BinaryDecoder:decodeFunctionsSection()
    local count = self:readU16()
    for i = 1, count do
        local name = self:readString()
        local paramCount = self:readByte()
        local instrCount = self:readU16()
        
        local func = {
            name = name,
            params = {},
            instructions = {},
            labels = {},
            instrCount = instrCount,
        }
        
        -- Generate param names
        for p = 1, paramCount do
            table.insert(func.params, "arg" .. p)
        end
        
        self.functions[name] = func
        table.insert(self.functionList, func)
    end
end

function BinaryDecoder:decodeExportsSection()
    local count = self:readU16()
    for i = 1, count do
        local alias = self:readString()
        local funcIdx = self:readU16()
        
        -- Map alias to function name
        if self.functionList[funcIdx + 1] then
            self.exports[alias] = self.functionList[funcIdx + 1].name
        end
    end
end

function BinaryDecoder:decodeCodeSection()
    while self.pos <= #self.data do
        -- Check if we've read past the section
        local startPos = self.pos
        
        -- Read function index
        if self.pos + 2 > #self.data then break end
        local funcIdx = self:readU16()
        
        if funcIdx >= #self.functionList then break end
        
        local func = self.functionList[funcIdx + 1]
        if not func then break end
        
        -- Read labels
        local labelCount = self:readU16()
        for i = 1, labelCount do
            local labelName = self:readString()
            local labelPos = self:readU16()
            func.labels[labelName] = labelPos
        end
        
        -- Read instructions
        local instrCount = self:readU16()
        for i = 1, instrCount do
            local instr = self:decodeInstruction()
            table.insert(func.instructions, instr)
        end
    end
end

function BinaryDecoder:decodeInstruction()
    local opcodeNum = self:readByte()
    local opcode = OPCODES_REVERSE[opcodeNum] or "nop"
    
    local operandCount = self:readByte()
    local operands = {}
    
    for i = 1, operandCount do
        local opType = self:readByte()
        local operand = nil
        
        if opType == 0x01 then
            -- Register
            local regNum = self:readByte()
            operand = "r" .. regNum
        elseif opType == 0x02 then
            -- Immediate i32
            local value = self:readI32()
            operand = tostring(value)
        elseif opType == 0x03 then
            -- String index
            local strIdx = self:readU16()
            local strName = self.stringNames[strIdx] or ("str_" .. (strIdx + 1))
            operand = "$" .. strName
        elseif opType == 0x04 then
            -- Function index
            local funcIdx = self:readU16()
            local funcName = self.functionList[funcIdx + 1] and self.functionList[funcIdx + 1].name or "unknown"
            operand = "$" .. funcName
        elseif opType == 0x05 then
            -- Unknown symbol (raw name)
            local name = self:readString()
            operand = "$" .. name
        elseif opType == 0x06 then
            -- Label reference
            local labelName = self:readString()
            operand = labelName
        elseif opType == 0x07 then
            -- Memory operand [base + offset]
            local baseReg = self:readByte()
            local offset = self:readI32()
            if offset ~= 0 then
                operand = "[r" .. baseReg .. " + " .. offset .. "]"
            else
                operand = "[r" .. baseReg .. " + 0]"
            end
        else
            -- Raw/unknown
            local rawLen = self:readU16()
            local rawChars = {}
            for j = 1, rawLen do
                table.insert(rawChars, string.char(self:readByte()))
            end
            operand = table.concat(rawChars)
        end
        
        table.insert(operands, operand)
    end
    
    return { opcode = opcode, operands = operands }
end

-- Convert decoded data to text BASM (for debugging/runtime compatibility)
function BinaryDecoder:toText(decoded)
    local lines = {}
    
    table.insert(lines, "; BASM Decoded from Binary")
    table.insert(lines, "module main")
    table.insert(lines, "")
    table.insert(lines, "memory $heap : 1 .. 256")
    table.insert(lines, "")
    
    -- String data segments
    for idx, str in pairs(decoded.strings) do
        local name = decoded.stringNames[idx] or ("str_" .. (idx + 1))
        table.insert(lines, "data $" .. name .. " : string {")
        table.insert(lines, "    write.len " .. #str)
        -- Escape the string
        local escaped = str:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub('"', '\\"')
        table.insert(lines, '    write.bytes "' .. escaped .. '"')
        table.insert(lines, "}")
        table.insert(lines, "")
    end
    
    -- Functions
    for _, func in ipairs(self.functionList) do
        local paramStr = {}
        for _, p in ipairs(func.params) do
            table.insert(paramStr, p .. ": i64")
        end
        
        table.insert(lines, "; Function: " .. func.name)
        table.insert(lines, "func $" .. func.name .. "(" .. table.concat(paramStr, ", ") .. ") -> i64 {")
        
        -- Build label position map (position -> label name)
        local labelAtPos = {}
        for labelName, pos in pairs(func.labels) do
            labelAtPos[pos] = labelName
        end
        
        -- Output instructions with labels
        for i, instr in ipairs(func.instructions) do
            -- Check if there's a label at this position
            if labelAtPos[i - 1] then
                table.insert(lines, "    " .. labelAtPos[i - 1] .. ":")
            end
            
            local instrLine = "    " .. instr.opcode
            if #instr.operands > 0 then
                instrLine = instrLine .. " " .. table.concat(instr.operands, ", ")
            end
            table.insert(lines, instrLine)
        end
        
        -- Check for label at end
        if labelAtPos[#func.instructions] then
            table.insert(lines, "    " .. labelAtPos[#func.instructions] .. ":")
        end
        
        table.insert(lines, "}")
        table.insert(lines, "")
    end
    
    -- Exports
    for alias, name in pairs(decoded.exports) do
        table.insert(lines, 'export $' .. name .. ' as "' .. alias .. '"')
    end
    
    return table.concat(lines, "\n")
end

return {
    BinaryDecoder = BinaryDecoder,
}
