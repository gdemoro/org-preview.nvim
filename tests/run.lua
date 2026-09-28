--- Tiny dependency-free test runner.
---
--- Usage (from the repository root):
---   nvim --headless -u tests/minimal_init.lua -l tests/run.lua
local passed, failed, skipped = 0, 0, 0
local failures = {}

H = dofile("tests/helpers.lua")

function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    io.write("ok   - " .. name .. "\n")
  else
    failed = failed + 1
    failures[#failures + 1] = name .. "\n" .. tostring(err)
    io.write("FAIL - " .. name .. "\n")
  end
end

local files = {
  "tests/test_renderer.lua",
  "tests/test_server.lua",
  "tests/test_integration.lua",
  "tests/test_hardening.lua",
  "tests/test_styles.lua",
  "tests/test_priorities.lua",
  "tests/test_workflow.lua",
  "tests/test_drawers.lua",
}

for _, file in ipairs(files) do
  local chunk, err = loadfile(file)
  if not chunk then
    failed = failed + 1
    failures[#failures + 1] = file .. "\n" .. tostring(err)
  else
    local ok, run_err = pcall(chunk)
    if not ok then
      failed = failed + 1
      failures[#failures + 1] = file .. "\n" .. tostring(run_err)
    end
  end
end

io.write("\n" .. passed .. " passed, " .. failed .. " failed\n")
if #failures > 0 then
  io.write("\n" .. table.concat(failures, "\n\n") .. "\n")
end

if failed > 0 then
  os.exit(1)
end
os.exit(0)
