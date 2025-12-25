--[[
    BASM Runtime - Lua Implementation
    Executes .basm files in Lua
    
    Usage:
        local BasmVM = require("basm-runtime")
        local vm = BasmVM.new()
        vm:load(basmCode)
        local result = vm:run("main")
]]

local BasmVM = {}
BasmVM.__index = BasmVM

function BasmVM.new(options)
    options = options or {}
    local self = setmetatable({}, BasmVM)
    
    self.debug = options.debug or false
    self.output = options.output or print
    
    -- Registers (256 general purpose)
    self.registers = {}
    for i = 0, 255 do
        self.registers[i] = 0
    end
    
    -- Flags
    self.flags = { Z = false, N = false }
    
    -- Memory (linear heap)
    self.memory = {}
    self.heapPtr = 0
    self.memorySize = 65536 * 4  -- 256KB default
    
    -- Module state
    self.functions = {}
    self.dataBuilders = {}
    self.dataCache = {}
    self.exports = {}
    
    -- Call stack
    self.callStack = {}
    self.maxCallDepth = 1000
    
    -- Output buffer
    self.outputBuffer = ""
    
    return self
end

-- Parse and load a BASM module
function BasmVM:load(source)
    local lines = {}
    for line in source:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    
    local i = 1
    while i <= #lines do
        local line = lines[i]:match("^%s*(.-)%s*$")  -- trim
        i = i + 1
        
        if line == "" or line:sub(1, 1) == ";" then
            goto continue
        end
        
        -- Module declaration
        if line:match("^module%s+") then
            goto continue
        end
        
        -- Memory declaration
        if line:match("^memory%s+") then
            goto continue
        end
        
        -- Data builder
        if line:match("^data%s+") then
            local result = self:parseDataBuilder(lines, i - 1)
            i = result.nextLine
            goto continue
        end
        
        -- Function
        if line:match("^func%s+") then
            local result = self:parseFunction(lines, i - 1)
            i = result.nextLine
            goto continue
        end
        
        -- Export
        if line:match("^export%s+") then
            local name, alias = line:match("export%s+%$([%w_]+)%s+as%s+\"([^\"]+)\"")
            if name and alias then
                self.exports[alias] = name
            end
        end
        
        ::continue::
    end
    
    if self.debug then
        local funcNames = {}
        for name in pairs(self.functions) do
            table.insert(funcNames, name)
        end
        print("Functions: " .. table.concat(funcNames, ", "))
        
        local exportNames = {}
        for name in pairs(self.exports) do
            table.insert(exportNames, name)
        end
        print("Exports: " .. table.concat(exportNames, ", "))
    end
end

function BasmVM:parseDataBuilder(lines, startLine)
    local line = lines[startLine]:match("^%s*(.-)%s*$")
    local name = line:match("data%s+%$([%w_]+)")
    if not name then
        return { nextLine = startLine + 1 }
    end
    
    local instructions = {}
    local i = startLine + 1
    
    while i <= #lines do
        local l = lines[i]:match("^%s*(.-)%s*$")
        i = i + 1
        if l == "}" then break end
        if l == "" or l:sub(1, 1) == ";" then goto continue end
        
        local op, arg = l:match("^([%w%.]+)%s*(.*)")
        table.insert(instructions, { op = op, arg = arg or "" })
        
        ::continue::
    end
    
    self.dataBuilders[name] = instructions
    return { nextLine = i }
end

function BasmVM:parseFunction(lines, startLine)
    local line = lines[startLine]:match("^%s*(.-)%s*$")
    local name, paramStr = line:match("func%s+%$([%w_]+)%s*%(([^)]*)%)")
    if not name then
        return { nextLine = startLine + 1 }
    end
    
    local params = {}
    if paramStr and paramStr ~= "" then
        for p in paramStr:gmatch("[^,]+") do
            local paramName = p:match("^%s*([%w_]+)")
            if paramName then
                table.insert(params, paramName)
            end
        end
    end
    
    local instructions = {}
    local labels = {}
    local i = startLine + 1
    
    while i <= #lines do
        local l = lines[i]:match("^%s*(.-)%s*$")
        i = i + 1
        if l == "}" then break end
        if l == "" then goto continue end
        
        -- Skip pure comments
        if l:sub(1, 1) == ";" then goto continue end
        
        -- Extract comment
        local commentIdx = l:find(";")
        if commentIdx then
            l = l:sub(1, commentIdx - 1):match("^%s*(.-)%s*$")
        end
        if l == "" then goto continue end
        
        -- Label
        if l:sub(1, 1) == "." and l:sub(-1) == ":" then
            labels[l:sub(1, -2)] = #instructions + 1
            goto continue
        end
        
        -- Parse instruction
        local opcode, rest = l:match("^([%w%.]+)%s*(.*)")
        local operands = self:parseOperands(rest or "")
        
        table.insert(instructions, { opcode = opcode, operands = operands })
        
        ::continue::
    end
    
    self.functions[name] = { name = name, params = params, instructions = instructions, labels = labels }
    return { nextLine = i }
end

function BasmVM:parseOperands(str)
    local operands = {}
    local current = ""
    local bracketDepth = 0
    
    for i = 1, #str do
        local ch = str:sub(i, i)
        if ch == "[" then
            bracketDepth = bracketDepth + 1
            current = current .. ch
        elseif ch == "]" then
            bracketDepth = bracketDepth - 1
            current = current .. ch
        elseif ch == "," and bracketDepth == 0 then
            local trimmed = current:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                table.insert(operands, trimmed)
            end
            current = ""
        else
            current = current .. ch
        end
    end
    
    local trimmed = current:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
        table.insert(operands, trimmed)
    end
    
    return operands
end

-- Execute a function
function BasmVM:run(funcName, args)
    args = args or {}
    local internalName = self.exports[funcName] or funcName
    return self:executeFunction(internalName, args)
end

function BasmVM:executeFunction(funcName, args)
    args = args or {}
    local func = self.functions[funcName]
    if not func then
        error("Function not found: " .. funcName)
    end
    
    if #self.callStack >= self.maxCallDepth then
        error("Call stack overflow")
    end
    
    -- Save registers
    local savedRegisters = {}
    for i = 0, 255 do
        savedRegisters[i] = self.registers[i]
    end
    table.insert(self.callStack, { func = funcName })
    
    -- Load arguments
    for i = 1, math.min(8, #args) do
        self.registers[i - 1] = args[i]
    end
    
    -- Execute
    local pc = 1
    local returnValue = 0
    
    while pc <= #func.instructions do
        local instr = func.instructions[pc]
        
        if self.debug then
            print(string.format("  [%d] %s %s", pc, instr.opcode, table.concat(instr.operands, ", ")))
        end
        
        local result = self:executeInstruction(instr, func)
        
        if result then
            if result.action == "jump" then
                pc = result.target
                goto continue
            elseif result.action == "return" then
                returnValue = result.value
                break
            end
        end
        
        pc = pc + 1
        ::continue::
    end
    
    -- Restore registers, but preserve return values (r0-r6)
    table.remove(self.callStack)
    
    -- Save return values before restoring
    local returnRegs = {}
    for i = 0, 6 do
        returnRegs[i] = self.registers[i]
    end
    
    -- Restore caller's registers
    for i = 0, 255 do
        self.registers[i] = savedRegisters[i]
    end
    
    -- Restore return values (r0-r6 hold function returns)
    for i = 0, 6 do
        self.registers[i] = returnRegs[i]
    end
    
    return returnValue
end

function BasmVM:executeInstruction(instr, func)
    local opcode = instr.opcode
    local ops = instr.operands
    
    -- Data movement
    if opcode == "mov" then
        self:setRegister(ops[1], self:parseValue(ops[2]))
        
    -- Data builder execution
    elseif opcode == "data.load" then
        local name = ops[2]:match("^%$(.+)") or ops[2]
        local ptr = self:executeDataBuilder(name)
        self:setRegister(ops[1], ptr)
        
    -- Memory loads
    elseif opcode:match("^ld") then
        local addr = self:parseMemoryOperand(ops[2])
        local value
        if opcode == "ld.i8" then
            value = self.memory[addr] or 0
        elseif opcode == "ld.i32" then
            value = self:readI32(addr)
        else
            value = self:readI64(addr)
        end
        self:setRegister(ops[1], value)
        
    -- Memory stores (but not str.*)
    elseif opcode == "st" or (opcode:match("^st%.") and not opcode:match("^str%.")) then
        local addr = self:parseMemoryOperand(ops[1])
        local value = self:parseValue(ops[2])
        if opcode == "st.i8" then
            self.memory[addr] = value % 256
        elseif opcode == "st.i32" then
            self:writeI32(addr, value)
        else
            self:writeI64(addr, value)
        end
        
    -- Heap allocation
    elseif opcode == "heap.alloc" then
        local size = self:parseValue(ops[2])
        local ptr = self:heapAlloc(size)
        self:setRegister(ops[1], ptr)
        
    -- Heap reallocation (grows or shrinks memory block)
    elseif opcode == "heap.realloc" then
        local oldPtr = self:parseValue(ops[2])
        local newSize = self:parseValue(ops[3])
        local newPtr = self:heapAlloc(newSize)
        
        -- Copy existing data from old location to new
        -- We copy up to newSize bytes (or whatever was there)
        for i = 0, newSize - 1 do
            self.memory[newPtr + i] = self.memory[oldPtr + i] or 0
        end
        
        self:setRegister(ops[1], newPtr)
        
    -- Arithmetic
    elseif opcode == "add" then
        self:setRegister(ops[1], self:parseValue(ops[2]) + self:parseValue(ops[3]))
    elseif opcode == "sub" then
        self:setRegister(ops[1], self:parseValue(ops[2]) - self:parseValue(ops[3]))
    elseif opcode == "mul" then
        self:setRegister(ops[1], self:parseValue(ops[2]) * self:parseValue(ops[3]))
    elseif opcode == "div" then
        local right = self:parseValue(ops[3])
        if right == 0 then error("Division by zero") end
        self:setRegister(ops[1], math.floor(self:parseValue(ops[2]) / right))
    elseif opcode == "rem" then
        local right = self:parseValue(ops[3])
        if right == 0 then error("Division by zero") end
        self:setRegister(ops[1], self:parseValue(ops[2]) % right)
    elseif opcode == "inc" then
        self:setRegister(ops[1], self:getRegister(ops[1]) + 1)
    elseif opcode == "dec" then
        self:setRegister(ops[1], self:getRegister(ops[1]) - 1)
    elseif opcode == "neg" then
        self:setRegister(ops[1], -self:parseValue(ops[2]))
        
    -- Float arithmetic (f64)
    elseif opcode == "fmov" then
        -- fmov r0, 3.14159
        self:setRegister(ops[1], tonumber(ops[2]) or 0)
    elseif opcode == "fadd" then
        self:setRegister(ops[1], self:parseValue(ops[2]) + self:parseValue(ops[3]))
    elseif opcode == "fsub" then
        self:setRegister(ops[1], self:parseValue(ops[2]) - self:parseValue(ops[3]))
    elseif opcode == "fmul" then
        self:setRegister(ops[1], self:parseValue(ops[2]) * self:parseValue(ops[3]))
    elseif opcode == "fdiv" then
        local right = self:parseValue(ops[3])
        if right == 0 then error("Division by zero") end
        self:setRegister(ops[1], self:parseValue(ops[2]) / right)  -- No floor for float div
    elseif opcode == "frem" then
        local right = self:parseValue(ops[3])
        if right == 0 then error("Division by zero") end
        self:setRegister(ops[1], math.fmod(self:parseValue(ops[2]), right))
    elseif opcode == "ffloor" then
        self:setRegister(ops[1], math.floor(self:parseValue(ops[2])))
    elseif opcode == "fceil" then
        self:setRegister(ops[1], math.ceil(self:parseValue(ops[2])))
    elseif opcode == "fsqrt" then
        self:setRegister(ops[1], math.sqrt(self:parseValue(ops[2])))
    elseif opcode == "fabs" then
        self:setRegister(ops[1], math.abs(self:parseValue(ops[2])))
    elseif opcode == "fneg" then
        self:setRegister(ops[1], -self:parseValue(ops[2]))
        
    -- Type conversion
    elseif opcode == "i2f" then
        -- int to float (in Lua, already the same)
        self:setRegister(ops[1], self:parseValue(ops[2]) + 0.0)
    elseif opcode == "f2i" then
        -- float to int (truncate)
        self:setRegister(ops[1], math.floor(self:parseValue(ops[2])))
        
    -- Comparison
    elseif opcode == "cmp" then
        local result = self:parseValue(ops[1]) - self:parseValue(ops[2])
        self.flags.Z = result == 0
        self.flags.N = result < 0
    elseif opcode == "setz" then
        self:setRegister(ops[1], self.flags.Z and 1 or 0)
    elseif opcode == "setnz" then
        self:setRegister(ops[1], self.flags.Z and 0 or 1)
    elseif opcode == "setl" then
        self:setRegister(ops[1], self.flags.N and 1 or 0)
    elseif opcode == "setle" then
        self:setRegister(ops[1], (self.flags.N or self.flags.Z) and 1 or 0)
    elseif opcode == "setg" then
        self:setRegister(ops[1], (not self.flags.N and not self.flags.Z) and 1 or 0)
    elseif opcode == "setge" then
        self:setRegister(ops[1], (not self.flags.N) and 1 or 0)
        
    -- Bitwise
    elseif opcode == "and" then
        local bit = require("bit")
        self:setRegister(ops[1], bit.band(self:parseValue(ops[2]), self:parseValue(ops[3])))
    elseif opcode == "or" then
        local bit = require("bit")
        self:setRegister(ops[1], bit.bor(self:parseValue(ops[2]), self:parseValue(ops[3])))
    elseif opcode == "xor" then
        local bit = require("bit")
        self:setRegister(ops[1], bit.bxor(self:parseValue(ops[2]), self:parseValue(ops[3])))
    elseif opcode == "not" then
        local bit = require("bit")
        self:setRegister(ops[1], bit.bnot(self:parseValue(ops[2])))
    elseif opcode == "shl" then
        local bit = require("bit")
        self:setRegister(ops[1], bit.lshift(self:parseValue(ops[2]), self:parseValue(ops[3])))
    elseif opcode == "shr" then
        local bit = require("bit")
        self:setRegister(ops[1], bit.rshift(self:parseValue(ops[2]), self:parseValue(ops[3])))
        
    -- Jumps
    elseif opcode == "jmp" then
        if func.labels[ops[1]] then
            return { action = "jump", target = func.labels[ops[1]] }
        end
    elseif opcode == "jz" or opcode == "je" then
        if self.flags.Z and func.labels[ops[1]] then
            return { action = "jump", target = func.labels[ops[1]] }
        end
    elseif opcode == "jnz" or opcode == "jne" then
        if not self.flags.Z and func.labels[ops[1]] then
            return { action = "jump", target = func.labels[ops[1]] }
        end
    elseif opcode == "jl" then
        if self.flags.N and func.labels[ops[1]] then
            return { action = "jump", target = func.labels[ops[1]] }
        end
    elseif opcode == "jle" then
        if (self.flags.N or self.flags.Z) and func.labels[ops[1]] then
            return { action = "jump", target = func.labels[ops[1]] }
        end
    elseif opcode == "jg" then
        if not self.flags.N and not self.flags.Z and func.labels[ops[1]] then
            return { action = "jump", target = func.labels[ops[1]] }
        end
    elseif opcode == "jge" then
        if not self.flags.N and func.labels[ops[1]] then
            return { action = "jump", target = func.labels[ops[1]] }
        end
        
    -- Function calls
    elseif opcode == "call" then
        local targetName = ops[1]:match("^%$(.+)") or ops[1]
        local callArgs = {}
        for i = 0, 7 do
            table.insert(callArgs, self.registers[i])
        end
        local result = self:executeFunction(targetName, callArgs)
        self.registers[0] = result
    
    -- Tail call (efficient - reuses current stack frame)
    elseif opcode == "tailcall" then
        local targetName = ops[1]:match("^%$(.+)") or ops[1]
        local callArgs = {}
        for i = 0, 7 do
            table.insert(callArgs, self.registers[i])
        end
        -- Instead of growing stack, execute directly and return the result
        local result = self:executeFunction(targetName, callArgs)
        return { action = "return", value = result }
        
    -- Return
    elseif opcode == "ret" then
        return { action = "return", value = self:parseValue(ops[1]) }
        
    -- Console output
    elseif opcode == "console.log.str" then
        local ptr = self:parseValue(ops[1])
        local len = self:readI64(ptr)  -- Use I64 for 64-bit string header
        local str = ""
        for i = 0, len - 1 do
            str = str .. string.char(self.memory[ptr + 8 + i] or 0)
        end
        self.outputBuffer = self.outputBuffer .. str
    elseif opcode == "console.log.val" then
        self.outputBuffer = self.outputBuffer .. tostring(self:parseValue(ops[1]))
    elseif opcode == "console.log.space" then
        self.outputBuffer = self.outputBuffer .. " "
    elseif opcode == "console.log.newline" then
        self.output(self.outputBuffer)
        self.outputBuffer = ""
        
    -- String concatenation (supports implicit number-to-string conversion)
    elseif opcode == "str.concat" then
        local val1 = self:parseValue(ops[2])
        local val2 = self:parseValue(ops[3])
        
        -- Helper: convert value to string bytes (either read from string ptr or convert number)
        local function valueToString(val)
            -- Small values (0-1000) are almost certainly plain numbers, not pointers
            -- Heap allocations typically start higher
            if val < 1000 then
                local numStr = tostring(val)
                local bytes = {}
                for i = 1, #numStr do
                    table.insert(bytes, numStr:byte(i))
                end
                return bytes
            end
            
            -- Check if val looks like a valid string pointer
            -- Must have: allocated memory at ptr, reasonable length, actual char data
            local possibleLen = self:readI64(val)
            
            -- Check if this looks like valid allocated memory
            -- If memory[val] is nil, it wasn't allocated
            if self.memory[val] ~= nil and possibleLen >= 0 and possibleLen < 100000 then
                -- Also verify first char exists (proves it was allocated)
                if possibleLen == 0 or self.memory[val + 8] ~= nil then
                    -- Likely a string pointer - extract bytes
                    local bytes = {}
                    for i = 0, possibleLen - 1 do
                        table.insert(bytes, self.memory[val + 8 + i] or 0)
                    end
                    return bytes
                end
            end
            
            -- Treat as number - convert to string
            local numStr = tostring(val)
            local bytes = {}
            for i = 1, #numStr do
                table.insert(bytes, numStr:byte(i))
            end
            return bytes
        end
        
        local bytes1 = valueToString(val1)
        local bytes2 = valueToString(val2)
        local newLen = #bytes1 + #bytes2
        
        local newPtr = self:heapAlloc(8 + newLen)
        self:writeI64(newPtr, newLen)
        
        for i, b in ipairs(bytes1) do
            self.memory[newPtr + 8 + (i - 1)] = b
        end
        for i, b in ipairs(bytes2) do
            self.memory[newPtr + 8 + #bytes1 + (i - 1)] = b
        end
        
        self:setRegister(ops[1], newPtr)
    
    -- Create single-character string from byte value
    elseif opcode == "char.from" then
        local charCode = self:parseValue(ops[2])
        -- Allocate a 1-character string: 8 bytes length + 1 byte char
        local ptr = self:heapAlloc(9)
        self:writeI64(ptr, 1)  -- length = 1
        self.memory[ptr + 8] = charCode % 256
        self:setRegister(ops[1], ptr)
        
    -- String substring: str.sub result, strPtr, startIdx, endIdx
    elseif opcode == "str.sub" then
        local strPtr = self:parseValue(ops[2])
        local startIdx = self:parseValue(ops[3])
        local endIdx = self:parseValue(ops[4])
        
        -- Get original string length
        local origLen = self:readI64(strPtr)
        
        -- Lua uses 1-based indexing, handle negative indices
        if startIdx < 0 then startIdx = origLen + startIdx + 1 end
        if endIdx < 0 then endIdx = origLen + endIdx + 1 end
        
        -- Clamp indices
        if startIdx < 1 then startIdx = 1 end
        if endIdx > origLen then endIdx = origLen end
        
        -- Calculate new length
        local newLen = math.max(0, endIdx - startIdx + 1)
        
        -- Allocate new string
        local newPtr = self:heapAlloc(8 + newLen)
        self:writeI64(newPtr, newLen)
        
        -- Copy bytes (startIdx is 1-based, so offset is startIdx - 1)
        for i = 0, newLen - 1 do
            self.memory[newPtr + 8 + i] = self.memory[strPtr + 8 + (startIdx - 1) + i] or 0
        end
        
        self:setRegister(ops[1], newPtr)
        
    -- String repeat: str.rep result, strPtr, count
    elseif opcode == "str.rep" then
        local strPtr = self:parseValue(ops[2])
        local count = self:parseValue(ops[3])
        
        local origLen = self:readI64(strPtr)
        local newLen = origLen * count
        
        local newPtr = self:heapAlloc(8 + newLen)
        self:writeI64(newPtr, newLen)
        
        local offset = 0
        for rep = 1, count do
            for i = 0, origLen - 1 do
                self.memory[newPtr + 8 + offset] = self.memory[strPtr + 8 + i] or 0
                offset = offset + 1
            end
        end
        
        self:setRegister(ops[1], newPtr)
        
    -- String reverse: str.reverse result, strPtr
    elseif opcode == "str.reverse" then
        local strPtr = self:parseValue(ops[2])
        local len = self:readI64(strPtr)
        
        local newPtr = self:heapAlloc(8 + len)
        self:writeI64(newPtr, len)
        
        for i = 0, len - 1 do
            self.memory[newPtr + 8 + i] = self.memory[strPtr + 8 + (len - 1 - i)] or 0
        end
        
        self:setRegister(ops[1], newPtr)
        
    -- String to uppercase: str.upper result, strPtr
    elseif opcode == "str.upper" then
        local strPtr = self:parseValue(ops[2])
        local len = self:readI64(strPtr)
        
        local newPtr = self:heapAlloc(8 + len)
        self:writeI64(newPtr, len)
        
        for i = 0, len - 1 do
            local byte = self.memory[strPtr + 8 + i] or 0
            -- Convert lowercase a-z (97-122) to uppercase A-Z (65-90)
            if byte >= 97 and byte <= 122 then
                byte = byte - 32
            end
            self.memory[newPtr + 8 + i] = byte
        end
        
        self:setRegister(ops[1], newPtr)
        
    -- String to lowercase: str.lower result, strPtr
    elseif opcode == "str.lower" then
        local strPtr = self:parseValue(ops[2])
        local len = self:readI64(strPtr)
        
        local newPtr = self:heapAlloc(8 + len)
        self:writeI64(newPtr, len)
        
        for i = 0, len - 1 do
            local byte = self.memory[strPtr + 8 + i] or 0
            -- Convert uppercase A-Z (65-90) to lowercase a-z (97-122)
            if byte >= 65 and byte <= 90 then
                byte = byte + 32
            end
            self.memory[newPtr + 8 + i] = byte
        end
        
        self:setRegister(ops[1], newPtr)
        
    -- Integer to string: int.tostring result, intValue
    elseif opcode == "int.tostring" then
        local intVal = self:parseValue(ops[2])
        local numStr = tostring(intVal)
        local len = #numStr
        
        local ptr = self:heapAlloc(8 + len)
        self:writeI64(ptr, len)
        
        for i = 1, len do
            self.memory[ptr + 8 + (i - 1)] = numStr:byte(i)
        end
        
        self:setRegister(ops[1], ptr)
        
    -- String to number: str.tonumber result, strPtr
    elseif opcode == "str.tonumber" then
        local strPtr = self:parseValue(ops[2])
        local len = self:readI64(strPtr)
        
        -- Read string bytes
        local str = ""
        for i = 0, len - 1 do
            str = str .. string.char(self.memory[strPtr + 8 + i] or 0)
        end
        
        -- Convert to number (returns 0 if conversion fails)
        local num = tonumber(str) or 0
        self:setRegister(ops[1], num)
        
    -- Type checking: type.of result, value
    elseif opcode == "type.of" then
        local val = self:parseValue(ops[2])
        -- Simplified type system: 0=nil, 1=number, 2=string, 3=table, 4=function
        -- For now, return 1 (number) for most values, 0 for nil
        local typeCode = val == 0 and 0 or 1
        self:setRegister(ops[1], typeCode)
        
    -- Table concatenation: table.concat result, tablePtr, sepPtr
    elseif opcode == "table.concat" then
        local tablePtr = self:parseValue(ops[2])
        local sepPtr = self:parseValue(ops[3])
        
        local tableLen = self:readI64(tablePtr)
        local sepLen = sepPtr ~= 0 and self:readI64(sepPtr) or 0
        
        -- First pass: calculate total length
        local totalLen = 0
        for i = 1, tableLen do
            local elemPtr = self:readI64(tablePtr + 16 + i * 8)
            if elemPtr ~= 0 then
                totalLen = totalLen + self:readI64(elemPtr)
            end
            if i < tableLen and sepLen > 0 then
                totalLen = totalLen + sepLen
            end
        end
        
        -- Allocate result string
        local resultPtr = self:heapAlloc(8 + totalLen)
        self:writeI64(resultPtr, totalLen)
        
        -- Second pass: copy strings
        local offset = 0
        for i = 1, tableLen do
            local elemPtr = self:readI64(tablePtr + 16 + i * 8)
            if elemPtr ~= 0 then
                local elemLen = self:readI64(elemPtr)
                for j = 0, elemLen - 1 do
                    self.memory[resultPtr + 8 + offset] = self.memory[elemPtr + 8 + j] or 0
                    offset = offset + 1
                end
            end
            if i < tableLen and sepLen > 0 then
                for j = 0, sepLen - 1 do
                    self.memory[resultPtr + 8 + offset] = self.memory[sepPtr + 8 + j] or 0
                    offset = offset + 1
                end
            end
        end
        
        self:setRegister(ops[1], resultPtr)

    -- Function address (for closures)
    elseif opcode == "func.addr" then
        -- Store function name using a unique ID system
        local funcName = ops[2]:match("^%$(.+)") or ops[2]
        
        -- Initialize funcPtrMap if needed
        if not self.funcPtrMap then
            self.funcPtrMap = {}
            self.funcPtrCounter = 1000000  -- Start at 1 million to avoid collisions
        end
        
        -- Create a unique ID for this function
        local funcId = self.funcPtrCounter
        self.funcPtrCounter = self.funcPtrCounter + 1
        self.funcPtrMap[funcId] = funcName
        
        self:setRegister(ops[1], funcId)
        
    -- Indirect call (call via function pointer)
    elseif opcode == "call.indirect" then
        local funcPtr = self:parseValue(ops[1])
        
        -- Initialize funcPtrMap if needed
        if not self.funcPtrMap then
            self.funcPtrMap = {}
        end
        
        local funcName = self.funcPtrMap[funcPtr]
        if not funcName then
            -- Maybe the funcPtr was stored to memory and loaded back
            -- Try to find it in the map anyway
            for id, name in pairs(self.funcPtrMap) do
                if id == funcPtr then
                    funcName = name
                    break
                end
            end
        end
        
        if funcName and self.functions[funcName] then
            -- Check if this is a closure call or regular function call
            -- r0 contains env_ptr - if it's 0, this is a regular function
            -- and we need to shift args (r1 -> r0, r2 -> r1, etc.)
            local envPtr = self.registers[0]
            local callArgs = {}
            
            if envPtr == 0 then
                -- Regular function wrapped as closure - shift args
                for i = 1, 7 do
                    table.insert(callArgs, self.registers[i])
                end
                table.insert(callArgs, 0)  -- Fill the last slot
            else
                -- True closure - pass all args including env
                for i = 0, 7 do
                    table.insert(callArgs, self.registers[i])
                end
            end
            
            local result = self:executeFunction(funcName, callArgs)
            self.registers[0] = result
        else
            error("Invalid function pointer: " .. funcPtr .. " (no mapping found)")
        end
        
    -- Nop
    elseif opcode == "nop" then
        -- Do nothing
    end
    
    return nil
end

function BasmVM:executeDataBuilder(name)
    if self.dataCache[name] then
        return self.dataCache[name]
    end
    
    local instructions = self.dataBuilders[name]
    if not instructions then
        error("Data builder not found: " .. name)
    end
    
    -- Calculate size
    local totalSize = 0
    for _, instr in ipairs(instructions) do
        if instr.op == "write.len" then
            totalSize = totalSize + 8
        elseif instr.op == "write.bytes" then
            local str = self:parseString(instr.arg)
            totalSize = totalSize + #str
        elseif instr.op == "write.i64" then
            totalSize = totalSize + 8
        end
    end
    
    -- Allocate and write
    local ptr = self:heapAlloc(totalSize + 8)
    local offset = 0
    
    for _, instr in ipairs(instructions) do
        if instr.op == "write.len" then
            self:writeI64(ptr + offset, tonumber(instr.arg))
            offset = offset + 8
        elseif instr.op == "write.bytes" then
            local str = self:parseString(instr.arg)
            for i = 1, #str do
                self.memory[ptr + offset + i - 1] = str:byte(i)
            end
            offset = offset + #str
        elseif instr.op == "write.i64" then
            self:writeI64(ptr + offset, tonumber(instr.arg))
            offset = offset + 8
        end
    end
    
    self.dataCache[name] = ptr
    return ptr
end

function BasmVM:parseString(s)
    if s:sub(1, 1) == '"' and s:sub(-1) == '"' then
        s = s:sub(2, -2)
    end
    return s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\\\", "\\")
end

-- Memory helpers
function BasmVM:heapAlloc(size)
    size = math.floor((size + 7) / 8) * 8  -- 8-byte align
    local ptr = self.heapPtr
    self.heapPtr = self.heapPtr + size
    return ptr
end

function BasmVM:readI32(addr)
    return (self.memory[addr] or 0) +
           ((self.memory[addr + 1] or 0) * 256) +
           ((self.memory[addr + 2] or 0) * 65536) +
           ((self.memory[addr + 3] or 0) * 16777216)
end

function BasmVM:writeI32(addr, value)
    value = math.floor(value)
    self.memory[addr] = value % 256
    self.memory[addr + 1] = math.floor(value / 256) % 256
    self.memory[addr + 2] = math.floor(value / 65536) % 256
    self.memory[addr + 3] = math.floor(value / 16777216) % 256
end

function BasmVM:readI64(addr)
    return self:readI32(addr)  -- Simplified for now
end

function BasmVM:writeI64(addr, value)
    self:writeI32(addr, value)
    self:writeI32(addr + 4, value < 0 and -1 or 0)
end

-- Register helpers
function BasmVM:getRegister(op)
    if type(op) == "number" then return op end
    if op:match("^r%d+$") then
        local idx = tonumber(op:sub(2))
        return self.registers[idx] or 0
    end
    return 0
end

function BasmVM:setRegister(op, value)
    if op:match("^r%d+$") then
        local idx = tonumber(op:sub(2))
        self.registers[idx] = value
    end
end

function BasmVM:parseValue(op)
    if not op then return 0 end
    if type(op) == "number" then return op end
    
    op = op:match("^%s*(.-)%s*$")  -- trim
    
    -- Register
    if op:match("^r%d+$") then
        return self:getRegister(op)
    end
    
    -- Null
    if op == "null" or op == "nil" then return 0 end
    
    -- Hexadecimal numbers (0x or 0X prefix, case insensitive)
    -- Also handle hex numbers with underscores for readability (0x00_FF)
    local hexMatch = op:match("^0[xX]([%x_]+)$")
    if hexMatch then
        -- Remove underscores and convert
        local cleaned = hexMatch:gsub("_", "")
        local num = tonumber(cleaned, 16)
        if num then return num end
    end
    
    -- Binary numbers (0b prefix)
    local binMatch = op:match("^0[bB]([01_]+)$")
    if binMatch then
        local cleaned = binMatch:gsub("_", "")
        local num = 0
        for i = 1, #cleaned do
            num = num * 2 + (cleaned:sub(i, i) == "1" and 1 or 0)
        end
        return num
    end
    
    -- Float numbers (with decimal point or scientific notation)
    if op:match("^%-?%d+%.%d+$") or op:match("^%-?%d+[eE][%+%-]?%d+$") then
        return tonumber(op) or 0
    end
    
    -- Regular integer numbers (including negative)
    if op:match("^%-?%d+$") then return tonumber(op) end
    
    return 0
end

function BasmVM:parseMemoryOperand(op)
    local inner = op:match("^%[(.+)%]$")
    if not inner then return 0 end
    
    inner = inner:match("^%s*(.-)%s*$")
    
    if inner:find("+") then
        local base, offset = inner:match("^(.+)%+(.+)$")
        return self:parseValue(base:match("^%s*(.-)%s*$")) + 
               self:parseValue(offset:match("^%s*(.-)%s*$"))
    elseif inner:find("-") then
        local base, offset = inner:match("^(.+)%-(.+)$")
        return self:parseValue(base:match("^%s*(.-)%s*$")) - 
               self:parseValue(offset:match("^%s*(.-)%s*$"))
    end
    
    return self:parseValue(inner)
end

-- API Methods for embedding

-- Call an exported function with given arguments
function BasmVM:callExport(funcName, args)
    args = args or {}
    
    -- Find actual function name if this is an export alias
    local actualName = self.exports[funcName] or funcName
    
    if not self.functions[actualName] then
        error("Function not found: " .. funcName)
    end
    
    -- Set up arguments in registers r0-r7
    for i = 1, math.min(#args, 8) do
        self.registers[i - 1] = args[i] or 0
    end
    
    -- Execute function
    local result = self:executeFunction(actualName, args)
    
    return result
end

-- Reset VM state
function BasmVM:reset()
    -- Clear registers
    for i = 0, 255 do
        self.registers[i] = 0
    end
    
    -- Clear flags
    self.flags = { Z = false, N = false }
    
    -- Clear memory
    self.memory = {}
    self.heapPtr = 0
    
    -- Clear data cache (will be rebuilt on demand)
    self.dataCache = {}
    
    -- Clear call stack
    self.callStack = {}
    
    -- Clear output buffer
    self.outputBuffer = ""
    
    -- Clear function pointer map
    self.funcPtrMap = nil
    self.funcPtrCounter = nil
end

-- Allocate a string in BASM memory
function BasmVM:allocString(str)
    local len = #str
    local ptr = self:heapAlloc(4 + len)  -- 4 bytes for length + string data
    
    -- Write length
    self:writeI32(ptr, len)
    
    -- Write string bytes
    for i = 1, len do
        self.memory[ptr + 4 + (i - 1)] = str:byte(i)
    end
    
    return ptr
end

-- Read a 64-bit value from memory
function BasmVM:readI64(address)
    local lo = self:readI32(address)
    local hi = self:readI32(address + 4)
    return lo + hi * 4294967296
end

return BasmVM
