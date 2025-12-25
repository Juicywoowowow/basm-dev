-- Test harness for chunks.lua using BASM Runtime API
-- This runs the compiled chunks.basm through the BASM VM

local BasmVM = require("basm-runtime")

-- Read the compiled BASM file
local file = io.open("../../sdk-test/chunks/src/chunks.basm", "r")
if not file then
    error("Could not open chunks.basm")
end
local basmCode = file:read("*a")
file:close()

-- Create VM instance
local vm = BasmVM.new({ debug = false })

-- Load the BASM code
print("Loading chunks.basm...")
vm:load(basmCode)

-- List available functions
print("\nAvailable functions:")
for name, _ in pairs(vm.functions) do
    print("  - " .. name)
end

-- Create a test array in BASM memory [1, 2, 3, 4, 5]
print("\n=== Creating test array ===")
-- Table layout: [0]=length, [8]=capacity, [16]=metatable, [24+]=data
-- Need: 24 byte header + 5 * 8 byte elements = 64 bytes
local arrayPtr = vm:heapAlloc(64)
vm:writeI64(arrayPtr, 5)      -- length = 5
vm:writeI64(arrayPtr + 8, 5)  -- capacity = 5 (exactly 5 slots)
vm:writeI64(arrayPtr + 16, 0) -- no metatable
-- Data starts at offset 24 (index 1 = offset 24, index 2 = offset 32, etc.)
vm:writeI64(arrayPtr + 24, 1)  -- arr[1] = 1
vm:writeI64(arrayPtr + 32, 2)  -- arr[2] = 2
vm:writeI64(arrayPtr + 40, 3)  -- arr[3] = 3
vm:writeI64(arrayPtr + 48, 4)  -- arr[4] = 4
vm:writeI64(arrayPtr + 56, 5)  -- arr[5] = 5

print("Array created at ptr " .. arrayPtr)
print("Array length: " .. vm:readI64(arrayPtr))

-- Test: Chunks.first
print("\n=== Test: Chunks_first ===")
vm.registers[0] = arrayPtr
local first = vm:executeFunction("Chunks_first", {arrayPtr})
print("First element: " .. first)

-- Test: Chunks.last
print("\n=== Test: Chunks_last ===")
local last = vm:executeFunction("Chunks_last", {arrayPtr})
print("Last element: " .. last)

-- Test: Chunks.size
print("\n=== Test: Chunks_size ===")
local size = vm:executeFunction("Chunks_size", {arrayPtr})
print("Size: " .. size)

-- Test: Chunks.has
print("\n=== Test: Chunks_has ===")
local has3 = vm:executeFunction("Chunks_has", {arrayPtr, 3})
print("Has index 3: " .. (has3 == 1 and "yes" or "no"))

local has10 = vm:executeFunction("Chunks_has", {arrayPtr, 10})
print("Has index 10: " .. (has10 == 1 and "yes" or "no"))

print("\n=== All tests complete! ===")
