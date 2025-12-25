--[[
    BASM - Based Assembly Lua API
    
    Allows Lua code to load and call BASM modules,
    similar to how JavaScript interacts with WebAssembly.
    
    Usage:
        local basm = require("basm")
        local mod = basm.load("program.basmb")
        local result = mod.exports.main()
        local sum = mod.exports.add(10, 20)
]]

local BasmVM = require("basm-runtime")
local BinaryDecoder = require("binary-decoder").BinaryDecoder

local basm = {}

-- Module metatable for exports
local ModuleMeta = {}
ModuleMeta.__index = ModuleMeta

-- Exports metatable for callable functions
local ExportsMeta = {}

function ExportsMeta.__index(self, key)
    local module = rawget(self, "_module")
    if module.exportedFuncs[key] then
        -- Return a callable function
        return function(...)
            return module:call(key, ...)
        end
    end
    return nil
end

function ExportsMeta.__pairs(self)
    local module = rawget(self, "_module")
    local funcs = {}
    for name, _ in pairs(module.exportedFuncs) do
        funcs[name] = { type = "function", name = name }
    end
    return pairs(funcs)
end

-- Memory accessor
local MemoryMeta = {}
MemoryMeta.__index = MemoryMeta

function MemoryMeta:read(address)
    local vm = rawget(self, "_vm")
    return vm:readI64(address)
end

function MemoryMeta:readI32(address)
    local vm = rawget(self, "_vm")
    return vm:readI32(address)
end

function MemoryMeta:readBytes(address, length)
    local vm = rawget(self, "_vm")
    local bytes = {}
    for i = 0, length - 1 do
        table.insert(bytes, vm.memory[address + i] or 0)
    end
    return bytes
end

function MemoryMeta:readString(address)
    local vm = rawget(self, "_vm")
    local len = vm:readI32(address)
    local chars = {}
    for i = 0, len - 1 do
        local byte = vm.memory[address + 4 + i]
        if byte then
            table.insert(chars, string.char(byte))
        end
    end
    return table.concat(chars)
end

function MemoryMeta:write(address, value)
    local vm = rawget(self, "_vm")
    vm:writeI64(address, value)
end

function MemoryMeta:writeI32(address, value)
    local vm = rawget(self, "_vm")
    vm:writeI32(address, value)
end

-- Module object
function ModuleMeta:call(funcName, ...)
    local args = {...}
    
    -- Convert Lua values to BASM values
    local basmArgs = {}
    for i, arg in ipairs(args) do
        if type(arg) == "number" then
            basmArgs[i] = math.floor(arg)
        elseif type(arg) == "boolean" then
            basmArgs[i] = arg and 1 or 0
        elseif type(arg) == "nil" then
            basmArgs[i] = 0
        elseif type(arg) == "string" then
            -- Allocate string in BASM memory
            local ptr = self.vm:allocString(arg)
            basmArgs[i] = ptr
        else
            basmArgs[i] = 0
        end
    end
    
    -- Call the function
    local result = self.vm:callExport(funcName, basmArgs)
    
    return result
end

function ModuleMeta:reset()
    -- Reset VM state
    self.vm:reset()
end

function ModuleMeta:getExports()
    local list = {}
    for name, _ in pairs(self.exportedFuncs) do
        table.insert(list, name)
    end
    return list
end

-- Read file helper
local function readFile(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local content = file:read("*all")
    file:close()
    return content
end

-- Detect if content is binary format
local function isBinary(content)
    if #content >= 4 then
        return content:sub(1, 4) == "BASM"
    end
    return false
end

--[[
    Load a BASM module from file
    
    @param path string - Path to .basm or .basmb file
    @param options table - Optional settings
    @return module object
]]
function basm.load(path, options)
    options = options or {}
    
    local content, err = readFile(path)
    if not content then
        error("Failed to load BASM module: " .. (err or "unknown error"))
    end
    
    local source = content
    local format = "text"
    
    -- Check if binary and decode
    if isBinary(content) then
        format = "binary"
        local decoder = BinaryDecoder.new()
        local decoded = decoder:decode(content)
        source = decoder:toText(decoded)
    end
    
    -- Create VM and load
    local vm = BasmVM.new({
        debug = options.debug or false,
        silent = true,  -- Don't print output by default
    })
    
    -- Capture output if needed
    local outputBuffer = {}
    if options.captureOutput then
        vm.output = function(text)
            table.insert(outputBuffer, text)
        end
    end
    
    -- Load the source
    vm:load(source)
    
    -- Build exports map
    local exportedFuncs = {}
    for alias, name in pairs(vm.exports or {}) do
        exportedFuncs[alias] = name
    end
    
    -- Also export all functions that aren't internal
    for name, func in pairs(vm.functions or {}) do
        if not name:match("^__") then  -- Skip internal functions
            exportedFuncs[name] = name
        end
    end
    
    -- Create module object
    local module = setmetatable({
        name = path:match("([^/\\]+)$"):gsub("%.basmb?$", ""),
        path = path,
        format = format,
        vm = vm,
        exportedFuncs = exportedFuncs,
        outputBuffer = outputBuffer,
    }, ModuleMeta)
    
    -- Create exports accessor
    local exports = setmetatable({
        _module = module,
    }, ExportsMeta)
    module.exports = exports
    
    -- Create memory accessor
    local memory = setmetatable({
        _vm = vm,
        size = 256 * 65536,  -- 256 pages * 64KB
    }, MemoryMeta)
    module.memory = memory
    
    return module
end

--[[
    Load BASM from a string
    
    @param source string - BASM source code
    @param options table - Optional settings
    @return module object
]]
function basm.loadString(source, options)
    options = options or {}
    
    local format = "text"
    
    -- Check if binary and decode
    if isBinary(source) then
        format = "binary"
        local decoder = BinaryDecoder.new()
        local decoded = decoder:decode(source)
        source = decoder:toText(decoded)
    end
    
    -- Create VM and load
    local vm = BasmVM.new({
        debug = options.debug or false,
        silent = true,
    })
    
    local outputBuffer = {}
    if options.captureOutput then
        vm.output = function(text)
            table.insert(outputBuffer, text)
        end
    end
    
    vm:load(source)
    
    -- Build exports map
    local exportedFuncs = {}
    for alias, name in pairs(vm.exports or {}) do
        exportedFuncs[alias] = name
    end
    for name, func in pairs(vm.functions or {}) do
        if not name:match("^__") then
            exportedFuncs[name] = name
        end
    end
    
    local module = setmetatable({
        name = "inline",
        path = nil,
        format = format,
        vm = vm,
        exportedFuncs = exportedFuncs,
        outputBuffer = outputBuffer,
    }, ModuleMeta)
    
    local exports = setmetatable({
        _module = module,
    }, ExportsMeta)
    module.exports = exports
    
    local memory = setmetatable({
        _vm = vm,
        size = 256 * 65536,
    }, MemoryMeta)
    module.memory = memory
    
    return module
end

-- Version info
basm.version = "1.0.0"

return basm
