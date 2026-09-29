--- Per-buffer preview orchestration.
---
--- Owns the autocmds, debounce timers and pandoc jobs for a single Org
--- buffer, and keeps one entry registered in the shared HTTP server.
local M = {}

local uv = vim.uv or vim.loop
local renderer = require("org-preview.renderer")

--- @type table<integer, table>
local previews = {}
local id_counter = 0

--- @param bufnr integer
--- @return boolean
local function is_org_buffer(bufnr)
  if vim.bo[bufnr].filetype == "org" then
    return true
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:lower():match("%.org$") ~= nil
end

--- @param bufnr integer
--- @return string
local function buffer_content(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

--- Escape text for safe inclusion in HTML.
--- @param text string
--- @return string
local function html_escape(text)
  return (text:gsub("[&<>]", {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
  }))
end

--- A single Unicode character, byte-oriented (the `utf8` library is not
--- available in Neovim's LuaJIT). Equivalent to utf8.charpattern.
local UTF8_CHAR = "[\1-\127\194-\244][\128-\191]*"

--- Rewrite Org priority cookies (`[#A]`) into semantic badges, but only
--- inside heading elements.
---
--- Pandoc renders priorities as literal text, so a document-wide replace
--- would corrupt paragraphs and code blocks. The transform is therefore
--- scoped to the inner HTML of `<h1>..<h6>`. It is deliberately narrow: it
--- recognizes the standard single-character Org priority cookie and does no
--- Org parsing (TODO/DONE and timestamps are untouched).
---
--- @param html string
--- @return string
local function transform_priorities(html)
  return (html:gsub("(<h[1-6][^>]*>)(.-)(</h[1-6]>)", function(open_tag, inner, close_tag)
    local transformed = inner:gsub("%[#(" .. UTF8_CHAR .. ")%]", function(char)
      local key = char:lower()
      return string.format(
        '<span class="org-priority priority-%s" title="Priority %s" aria-label="Priority %s">%s</span>',
        key,
        char,
        char,
        char
      )
    end)
    return open_tag .. transformed .. close_tag
  end))
end

--- Inject the custom stylesheet and the SSE reload client into pandoc's HTML.
---
--- This is deliberately tolerant of non-default templates: closing tags are
--- matched case-insensitively and with optional whitespace, and if no
--- insertion point exists the CSS/script are simply prepended/appended so
--- the page still works (browsers accept trailing scripts outside <body>).
---
--- @param html string
--- @param css string|nil
--- @param events_path string
--- @return string
local function inject_html(html, css, events_path)
  if type(html) ~= "string" then
    html = ""
  end

  local head = ""
  if css and css ~= "" then
    head = "<style>\n" .. css .. "\n</style>\n"
  end

  local script = table.concat({
    "<script>",
    "(function () {",
    "  var source = new EventSource(" .. string.format("%q", events_path) .. ");",
    "  source.addEventListener('reload', function () { window.location.reload(); });",
    "})();",
    "</script>\n",
  }, "\n")

  local head_close = "</[hH][eE][aA][dD]%s*>"
  local head_open = "<[hH][eE][aA][dD][^>]*>"
  local body_close = "</[bB][oO][dD][yY]%s*>"

  if html:find(head_close) then
    html = html:gsub(head_close, function(match)
      return head .. match
    end, 1)
  elseif head ~= "" and html:find(head_open) then
    html = html:gsub(head_open, function(match)
      return match .. "\n" .. head
    end, 1)
  else
    html = head .. html
  end

  if html:find(body_close) then
    html = html:gsub(body_close, function(match)
      return script .. match
    end, 1)
  else
    html = html .. script
  end

  return html
end

--- @param p table
local function cancel_timer(p)
  if p.timer then
    pcall(function()
      p.timer:stop()
    end)
    pcall(function()
      p.timer:close()
    end)
    p.timer = nil
  end
end

--- Render the buffer now. `on_done` runs after the render settles.
--- @param p table
--- @param on_done fun()|nil
local function render_now(p, on_done)
  if not vim.api.nvim_buf_is_valid(p.bufnr) then
    return
  end

  p.generation = p.generation + 1
  local generation = p.generation

  if p.job then
    pcall(function()
      p.job:kill(15)
    end)
    p.job = nil
  end

  p.job = renderer.render({
    content = buffer_content(p.bufnr),
    source_dir = p.source_dir,
    todo_keywords = p.config.todo_keywords,
    drawer_filter = p.config.drawer_filter,
    pandoc_args = p.config.pandoc_args,
  }, function(err, html)
    if generation ~= p.generation then
      return
    end
    p.job = nil

    if err then
      p.html = "<pre>" .. html_escape(err) .. "</pre>"
    else
      p.html = inject_html(transform_priorities(html), p.config.css_text, p.events_path)
    end

    p.server:update(p.id)
    if on_done then
      on_done()
    end
  end)
end

--- Debounce a re-render for this preview.
--- @param p table
local function schedule(p)
  cancel_timer(p)
  p.timer = vim.defer_fn(function()
    p.timer = nil
    render_now(p)
  end, p.config.debounce)
end

--- Recompute the asset root after the buffer is renamed or saved elsewhere.
--- Re-renders so the title and any path-dependent content stay correct.
--- @param p table
--- @return boolean changed
local function refresh_source_dir(p)
  if not vim.api.nvim_buf_is_valid(p.bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(p.bufnr)
  local dir = name ~= "" and vim.fs.dirname(name) or uv.cwd()
  if dir == p.source_dir then
    return false
  end
  p.source_dir = dir
  pcall(function()
    p.server:set_source_dir(p.id, dir)
  end)
  vim.notify("org-preview: assets now resolve from " .. dir, vim.log.levels.INFO)
  render_now(p)
  return true
end

--- Wire up the autocmds that keep the preview in sync with the buffer.
--- @param p table
local function attach_autocmds(p)
  local group = vim.api.nvim_create_augroup("OrgPreviewBuf" .. p.bufnr, { clear = true })
  p.group = group

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = group,
    buffer = p.bufnr,
    callback = function()
      schedule(p)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWritePost", "BufFilePost" }, {
    group = group,
    buffer = p.bufnr,
    callback = function()
      -- A rename already re-renders; only debounce ordinary writes.
      if not refresh_source_dir(p) then
        schedule(p)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = p.bufnr,
    callback = function()
      M.stop(p.bufnr)
    end,
  })
end

--- Is a preview active for this buffer?
--- @param bufnr integer
--- @return boolean
function M.is_active(bufnr)
  return previews[bufnr] ~= nil
end

--- Number of active previews.
--- @return integer
function M.count()
  local n = 0
  for _ in pairs(previews) do
    n = n + 1
  end
  return n
end

--- Describe the active previews.
--- @return table[]
function M.list()
  local out = {}
  for _, p in pairs(previews) do
    out[#out + 1] = {
      bufnr = p.bufnr,
      id = p.id,
      url = p.url,
      source_dir = p.source_dir,
    }
  end
  table.sort(out, function(a, b)
    return a.bufnr < b.bufnr
  end)
  return out
end

--- Start a preview for `bufnr`.
---
--- @param bufnr integer
--- @param config table Resolved org-preview config.
--- @param server table Running org-preview.server instance.
--- @return table|nil preview
function M.start(bufnr, config, server)
  if previews[bufnr] then
    local existing = previews[bufnr]
    if config.auto_open and config.open_browser then
      vim.ui.open(existing.url)
    end
    return existing
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("org-preview: invalid buffer", vim.log.levels.ERROR)
    return nil
  end

  if not is_org_buffer(bufnr) then
    vim.notify("org-preview: current buffer is not an Org buffer (filetype=org or *.org)", vim.log.levels.ERROR)
    return nil
  end

  if not renderer.is_available() then
    vim.notify(
      "org-preview: pandoc was not found in $PATH. Install it from "
        .. "https://pandoc.org/installing.html and make sure Neovim can see it.",
      vim.log.levels.ERROR
    )
    return nil
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local source_dir = name ~= "" and vim.fs.dirname(name) or uv.cwd()
  if name == "" then
    vim.notify(
      "org-preview: buffer has no filename; relative assets will resolve from " .. source_dir,
      vim.log.levels.INFO
    )
  end

  id_counter = id_counter + 1
  local id = string.format("%d-%d", bufnr, id_counter)
  local url = string.format("http://127.0.0.1:%d/preview/%s/", server.port, id)

  local p = {
    bufnr = bufnr,
    id = id,
    config = config,
    server = server,
    source_dir = source_dir,
    url = url,
    events_path = "__events",
    generation = 0,
    html = "<!doctype html><meta charset='utf-8'><p>Rendering&hellip;</p>",
    timer = nil,
    job = nil,
    group = nil,
  }
  previews[bufnr] = p

  server:add_preview(id, {
    name = name ~= "" and name or ("buffer " .. bufnr),
    source_dir = source_dir,
    get_html = function()
      return p.html
    end,
  })

  attach_autocmds(p)

  render_now(p, function()
    if config.auto_open and config.open_browser then
      vim.schedule(function()
        vim.ui.open(url)
      end)
    end
  end)

  vim.notify("org-preview: " .. url, vim.log.levels.INFO)
  return p
end

--- Stop the preview for `bufnr`, cleaning up timers, jobs and autocmds.
--- @param bufnr integer|nil Defaults to the current buffer.
--- @return boolean stopped
function M.stop(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local p = previews[bufnr]
  if not p then
    return false
  end
  previews[bufnr] = nil

  -- Invalidate any in-flight render. Killing the job is best-effort; a
  -- callback that already fired or is queued must not touch p.html or the
  -- server after the preview is gone.
  p.generation = p.generation + 1

  cancel_timer(p)

  if p.job then
    pcall(function()
      p.job:kill(15)
    end)
    p.job = nil
  end

  if p.group then
    pcall(function()
      vim.api.nvim_clear_autocmds({ group = p.group })
    end)
    pcall(function()
      vim.api.nvim_del_augroup_by_id(p.group)
    end)
  end

  pcall(function()
    p.server:remove_preview(p.id)
  end)

  vim.notify("org-preview: stopped", vim.log.levels.INFO)
  return true
end

--- Stop every preview. Used on shutdown.
function M.stop_all()
  local bufnrs = vim.tbl_keys(previews)
  for _, bufnr in ipairs(bufnrs) do
    M.stop(bufnr)
  end
end

return M
