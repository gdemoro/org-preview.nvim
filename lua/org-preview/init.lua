--- org-preview.nvim: live browser preview for Org-mode files.
---
--- Public entry points are `setup`, `start`, `stop` and `toggle`, which back
--- the `:OrgPreview`, `:OrgPreviewStop` and `:OrgPreviewToggle` commands.
local M = {}

local server = require("org-preview.server")
local preview = require("org-preview.preview")

--- @type table
M.config = {
  auto_open = true,
  debounce = 300,
  port = 0,
  open_browser = true,
  css = nil,
  -- Org TODO workflow, in pandoc `#+TODO:` syntax. Injected only when the
  -- document does not declare its own #+TODO/#+SEQ_TODO/#+TYP_TODO line.
  -- Set to false to leave Pandoc's built-in TODO/DONE handling only.
  todo_keywords = "TODO DOING WAITING | DONE CANCELLED",
  -- Render Org drawers as collapsible native <details>/<summary> blocks
  -- (via a bundled Pandoc Lua filter). Set to false to keep Pandoc's plain
  -- `<div class="NAME drawer">` output.
  drawers = true,
  pandoc_args = {},
}

local state = {
  server = nil,
  configured = false,
}

--- Resolve `config.css` into literal CSS text.
--- A path to an existing file is read; anything else is treated as raw CSS.
--- @param css string|nil
--- @return string|nil
local function resolve_css(css)
  if not css or css == "" then
    return nil
  end
  local path = vim.fn.expand(css)
  local fd = io.open(path, "r")
  if fd then
    local text = fd:read("*a")
    fd:close()
    return text
  end
  return css
end

--- Read the bundled stylesheet that ships with the plugin.
--- @return string|nil
local function load_default_css()
  local files = vim.api.nvim_get_runtime_file("assets/default.css", false)
  local path = files and files[1]
  if not path then
    return nil
  end
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

--- Resolve the bundled Pandoc drawer filter via the runtime path.
--- @return string|nil
local function resolve_drawer_filter()
  local files = vim.api.nvim_get_runtime_file("assets/org-drawer.lua", false)
  return files and files[1]
end

--- Decide which stylesheet to inject and store it as `config.css_text`.
---
---   css = nil (default)  built-in assets/default.css
---   css = false or ""    no stylesheet at all (bare pandoc output)
---   css = string         path to a .css file, or raw CSS (replaces default)
---
--- @param config table
local function apply_css(config)
  if config.css == nil then
    config.css_text = load_default_css()
  elseif config.css == false or config.css == "" then
    config.css_text = nil
  else
    config.css_text = resolve_css(config.css)
  end
end

--- Merge user options into the active config.
--- @param opts table|nil
function M.setup(opts)
  opts = opts or {}
  for key, value in pairs(opts) do
    M.config[key] = value
  end
  apply_css(M.config)

  if M.config.drawers then
    M.config.drawer_filter = resolve_drawer_filter()
    if not M.config.drawer_filter then
      vim.notify(
        "org-preview: assets/org-drawer.lua not found; drawers render as plain divs",
        vim.log.levels.WARN
      )
      M.config.drawers = false
    end
  else
    M.config.drawer_filter = nil
  end

  state.configured = true
end

--- Start the shared server if needed, then hand it to `callback`.
--- @param callback fun(server: table)
function M._ensure_server(callback)
  if state.server and state.server:is_running() then
    callback(state.server)
    return
  end

  local srv = server.new()
  srv:start(M.config.port, function(err, port)
    if err then
      vim.notify("org-preview: failed to start HTTP server: " .. tostring(err), vim.log.levels.ERROR)
      state.server = nil
      return
    end
    state.server = srv
    callback(srv)
    vim.notify("org-preview: server listening on 127.0.0.1:" .. tostring(port), vim.log.levels.DEBUG)
  end)
end

--- Start (or re-open) a preview for the current Org buffer.
--- @param bufnr integer|nil
function M.start(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not state.configured then
    M.setup({})
  end
  M._ensure_server(function(srv)
    preview.start(bufnr, M.config, srv)
  end)
end

--- Stop the preview for the current buffer, and the server when idle.
--- @param bufnr integer|nil
function M.stop(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  preview.stop(bufnr)
  if preview.count() == 0 and state.server then
    state.server:stop()
    state.server = nil
  end
end

--- Toggle the preview for the current buffer.
--- @param bufnr integer|nil
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if preview.is_active(bufnr) then
    M.stop(bufnr)
  else
    M.start(bufnr)
  end
end

--- Introspection for tests and tooling.
--- @return { server: { port: integer }|nil, previews: table[] }
function M.info()
  return {
    server = state.server and { port = state.server.port } or nil,
    previews = preview.list(),
  }
end

--- Tear everything down. Safe to call more than once.
function M._shutdown()
  preview.stop_all()
  if state.server then
    state.server:stop()
    state.server = nil
  end
end

-- Register exit cleanup as soon as the module is loaded.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("OrgPreviewLifecycle", { clear = true }),
  callback = function()
    M._shutdown()
  end,
})

return M
