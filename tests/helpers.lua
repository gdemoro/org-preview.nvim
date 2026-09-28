--- Shared test helpers (available as globals from run.lua).
local H = {}

--- Wait until `cond` is truthy, pumping the event loop.
--- @param cond fun(): boolean
--- @param timeout integer|nil
--- @return boolean
function H.wait_for(cond, timeout)
  return vim.wait(timeout or 10000, cond, 20)
end

--- Run a one-shot async `vim.system` call and wait for it.
--- @param cmd string[]
--- @return table
function H.run(cmd)
  local done = false
  local result = nil
  vim.system(cmd, { text = true }, function(obj)
    result = obj
    done = true
  end)
  H.wait_for(function()
    return done
  end)
  return result
end

--- Fetch a URL with curl.
--- @param url string
--- @param timeout integer|nil
--- @return table result with .code, .stdout, .stderr
function H.curl(url, timeout)
  return H.run({
    "curl",
    "-sS",
    "--max-time",
    tostring(timeout or 5),
    url,
  })
end

--- Create a unique temporary directory.
--- @param prefix string
--- @return string
function H.temp_dir(prefix)
  local dir = vim.fn.tempname() .. "-" .. prefix
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Recursively remove a directory.
--- @param dir string
function H.rm_rf(dir)
  vim.fn.delete(dir, "rf")
end

return H
