--- Shared test helpers (available as globals from run.lua).
local H = {}

local op = require("org-preview")

--- Wait until `cond` is truthy, pumping the event loop.
--- @param cond fun(): boolean
--- @param timeout integer|nil
--- @return boolean
function H.wait_for(cond, timeout)
  return vim.wait(timeout or 10000, cond, 20)
end

--- Find the preview registered for a specific buffer.
--- @param bufnr integer
--- @return table|nil
function H.preview_for(bufnr)
  for _, p in ipairs(op.info().previews) do
    if p.bufnr == bufnr then
      return p
    end
  end
  return nil
end

--- Strip <style>/<script> blocks so assertions only see markup.
--- @param html string
--- @return string
function H.body_only(html)
  html = html:gsub("<style>.-</style>", "")
  html = html:gsub("<script>.-</script>", "")
  return html
end

--- Create an Org buffer backed by a real file.
--- Note: callers that compare directories should canonicalize with
--- `vim.uv.fs_realpath` first (temp dirs may be symlinks, e.g. /var ->
--- /private/var on macOS).
--- @param dir string
--- @param filename string
--- @param content string|nil
--- @return integer bufnr
function H.open_org(dir, filename, content)
  local file = vim.fs.joinpath(dir, filename)
  local fd = io.open(file, "w")
  fd:write(content or "* Hello\n")
  fd:close()
  vim.cmd("edit! " .. vim.fn.fnameescape(file))
  return vim.api.nvim_get_current_buf()
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
