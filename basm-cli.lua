#!/usr/bin/env luajit
--[[
    BASM Runtime CLI
    Executes .basm (text) and .basmb (binary) files
    
    Usage: luajit basm-cli.lua <file.basm|file.basmb>
           luajit basm-cli.lua -e "<basm code>"
           luajit basm-cli.lua -c <file.lua>
    
    Now uses the basm.lua API internally.
]]

-- Add current directory to package path
local scriptPath = arg[0]:match("(.*[/\\])") or "./"
package.path = scriptPath .. "?.lua;" .. package.path

local basm = require("basm")

local VERSION = "1.2.0"

local function printUsage()
    print("BASM Runtime v" .. VERSION)
    print("")
    print("Usage: luajit basm-cli.lua <file> [options]")
    print("       luajit basm-cli.lua -e \"<basm code>\"")
    print("       luajit basm-cli.lua -c \"<lua code>\"")
    print("")
    print("Supported formats:")
    print("  .basm   - Text format (human-readable)")
    print("  .basmb  - Binary format (compact)")
    print("")
    print("Options:")
    print("  -e, --eval      Execute BASM code directly from string")
    print("  -c, --compile   Compile Lua code to BASM and run immediately")
    print("  -d, --debug     Enable debug mode (trace execution)")
    print("  -v, --verbose   Show loading info")
    print("  -h, --help      Show this help message")
    print("")
    print("Examples:")
    print("  luajit basm-cli.lua program.basm")
    print("  luajit basm-cli.lua -e 'func $main() { mov r0, 42; ret r0 }'")
    print([[  luajit basm-cli.lua -c 'print("hello world")']])
end

local function parseArgs()
    local args = {
        file = nil,
        eval = nil,      -- BASM code to execute directly
        compile = nil,   -- Lua file to compile and run
        debug = false,
        verbose = false,
        help = false,
    }
    
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "-d" or a == "--debug" then
            args.debug = true
        elseif a == "-v" or a == "--verbose" then
            args.verbose = true
        elseif a == "-h" or a == "--help" then
            args.help = true
        elseif a == "-e" or a == "--eval" then
            i = i + 1
            args.eval = arg[i]
        elseif a == "-c" or a == "--compile" then
            i = i + 1
            args.compile = arg[i]
        elseif a:sub(1, 1) ~= "-" then
            args.file = a
        end
        i = i + 1
    end
    
    return args
end

-- Execute BASM code from a string
local function runBasm(code, options)
    -- Wrap code in minimal module if needed
    if not code:match("module") then
        code = "module main\n" .. code .. "\nexport $main as \"main\""
    end
    
    local mod = basm.loadString(code, {
        debug = options.debug,
        captureOutput = false,
    })
    
    local success, result = pcall(function()
        return mod.exports.main()
    end)
    
    if not success then
        io.stderr:write("Runtime error: " .. tostring(result) .. "\n")
        os.exit(1)
    end
    
    return result
end

-- Compile Lua source code and run immediately (takes source string directly)
local function compileAndRun(source, options)
    -- Load compiler modules
    package.path = scriptPath .. "../../SDK-Compilers/Lua/?.lua;" .. package.path
    
    local ok, result = pcall(function()
        local lexerMod = require("lexer")
        local parserMod = require("parser")
        local codegenMod = require("codegen")
        local Optimizer = require("optimizer")
        
        local Lexer = lexerMod.Lexer
        local Parser = parserMod.Parser
        local CodeGenerator = codegenMod.CodeGenerator
        
        -- Compile
        local lexer = Lexer.new(source)
        local tokens = lexer:tokenize()
        
        local parser = Parser.new(tokens)
        local ast = parser:parse()
        
        local optimizer = Optimizer.new({ level = 2 })
        ast = optimizer:optimize(ast)
        
        local codegen = CodeGenerator.new()
        local basmCode = codegen:generate(ast)
        
        if options.verbose then
            print("=== Generated BASM ===")
            print(basmCode)
            print("======================")
            print("")
        end
        
        return basmCode
    end)
    
    if not ok then
        io.stderr:write("Compile error: " .. tostring(result) .. "\n")
        os.exit(1)
    end
    
    -- Execute using basm API
    local mod = basm.loadString(result, {
        debug = options.debug,
        captureOutput = false,
    })
    
    local execOk, execResult = pcall(function()
        return mod.exports.main()
    end)
    
    if not execOk then
        io.stderr:write("Runtime error: " .. tostring(execResult) .. "\n")
        os.exit(1)
    end
    
    print("Program returned: " .. tostring(execResult))
end

local function main()
    local args = parseArgs()
    
    if args.help then
        printUsage()
        os.exit(0)
    end
    
    -- Handle -e (eval BASM directly)
    if args.eval then
        if args.verbose then
            print("BASM Runtime v" .. VERSION)
            print("Executing inline BASM...")
            print("")
        end
        local result = runBasm(args.eval, args)
        print("Program returned: " .. tostring(result))
        os.exit(0)
    end
    
    -- Handle -c (compile Lua and run)
    if args.compile then
        if args.verbose then
            print("BASM Runtime v" .. VERSION)
            print("Compiling and running: " .. args.compile)
            print("")
        end
        compileAndRun(args.compile, args)
        os.exit(0)
    end
    
    -- Normal file execution
    if not args.file then
        printUsage()
        os.exit(1)
    end
    
    if args.verbose then
        print("BASM Runtime v" .. VERSION)
        print("File: " .. args.file)
        print("")
    end
    
    -- Load module using the BASM API
    local ok, mod = pcall(basm.load, args.file, {
        debug = args.debug,
        captureOutput = false,  -- Let output go to stdout
    })
    
    if not ok then
        io.stderr:write("Error loading module: " .. tostring(mod) .. "\n")
        os.exit(1)
    end
    
    if args.verbose then
        print("Format: " .. mod.format)
        print("Exports: " .. table.concat(mod:getExports(), ", "))
        print("")
        print("Executing main()...")
        print("")
    end
    
    -- Run the main function
    local success, result = pcall(function()
        return mod.exports.main()
    end)
    
    if not success then
        io.stderr:write("Runtime error: " .. tostring(result) .. "\n")
        os.exit(1)
    end
    
    print("Program returned: " .. tostring(result))
end

main()

