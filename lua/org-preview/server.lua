--- A tiny libuv HTTP server for org-preview.
---
--- Exactly one server is required per Neovim instance. It listens on
--- 127.0.0.1 only and can host any number of previews, addressed by id:
---
---   GET /                             index of active previews
---   GET /preview/<id>/                the rendered HTML document
---   GET /preview/<id>/__events        Server-Sent Events reload stream
---   GET /preview/<id>/<asset path>    static file from the Org source dir
---
--- The server never reads from disk for the HTML document: the owning
--- preview supplies a `get_html()` callback so unsaved buffer edits are
--- visible immediately.
local M = {}

local uv = vim.uv or vim.loop

local REASONS = {
  [200] = "OK",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [500] = "Internal Server Error",
}

local MIME = {
  html = "text/html; charset=utf-8",
  htm = "text/html; charset=utf-8",
  css = "text/css; charset=utf-8",
  js = "application/javascript; charset=utf-8",
  mjs = "application/javascript; charset=utf-8",
  json = "application/json; charset=utf-8",
  txt = "text/plain; charset=utf-8",
  org = "text/plain; charset=utf-8",
  md = "text/plain; charset=utf-8",
  svg = "image/svg+xml",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  avif = "image/avif",
  bmp = "image/bmp",
  ico = "image/x-icon",
  pdf = "application/pdf",
  mp4 = "video/mp4",
  webm = "video/webm",
  mp3 = "audio/mpeg",
  wav = "audio/wav",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf = "font/ttf",
  otf = "font/otf",
}

local Server = {}
Server.__index = Server

--- Escape text for inclusion in HTML text or a quoted attribute.
--- @param text string
--- @return string
local function html_escape(text)
  return (text:gsub("[&<>\"']", {
    ["&"] = "&amp;",
    ["<"] = "&lt;",
    [">"] = "&gt;",
    ['"'] = "&quot;",
    ["'"] = "&#39;",
  }))
end

--- Percent-decode a URL path component.
--- @param s string
--- @return string
local function urldecode(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Is `path` equal to `base` or nested inside it?
--- Separator-aware so it works with both `/` and `\`.
--- @param base string
--- @param path string
--- @return boolean
local function is_within(base, path)
  if path == base then
    return true
  end
  if #path <= #base or path:sub(1, #base) ~= base then
    return false
  end
  local sep = path:sub(#base + 1, #base + 1)
  return sep == "/" or sep == "\\"
end

--- Join a URL-relative path onto a base directory, refusing traversal.
---
--- The candidate is percent-decoded, backslashes are treated as separators
--- (so `%5c` cannot smuggle a traversal on any platform), then the final
--- path is canonicalized with `uv.fs_realpath` and verified to still live
--- inside the (also canonicalized) source directory. This means symlinks
--- are followed, but a symlink whose real target escapes the source
--- directory is refused.
---
--- @param base string
--- @param rel string
--- @return string|nil real_path
local function safe_join(base, rel)
  rel = urldecode(rel)
  if rel == "" then
    return nil
  end

  rel = rel:gsub("\\", "/")
  local parts = vim.split(rel, "/", { plain = true })
  local out = {}
  for _, part in ipairs(parts) do
    if part == ".." then
      return nil
    end
    if part ~= "" and part ~= "." then
      out[#out + 1] = part
    end
  end
  if #out == 0 then
    return nil
  end

  local candidate = vim.fs.joinpath(vim.fs.normalize(base), table.concat(out, "/"))
  local base_real = uv.fs_realpath(vim.fs.normalize(base))
  local real = uv.fs_realpath(candidate)
  if not base_real or not real or not is_within(base_real, real) then
    return nil
  end
  return real
end

--- Create a new (stopped) server.
--- @return table
function M.new()
  return setmetatable({
    tcp = nil,
    port = nil,
    previews = {},
  }, Server)
end

--- @return boolean
function Server:is_running()
  return self.tcp ~= nil
end

--- Bind and start listening.
---
--- `on_ready(err, port)` is called once the socket is bound. Because bind
--- is asynchronous, callers must wait for the callback before using the URL.
---
--- @param port integer 0 to pick a free port automatically
--- @param on_ready fun(err: string|nil, port: integer|nil)
function Server:start(port, on_ready)
  if self.tcp then
    on_ready(nil, self.port)
    return
  end

  local tcp = uv.new_tcp()

  local bind_ret, bind_err = tcp:bind("127.0.0.1", port or 0)
  if bind_ret == nil then
    pcall(function()
      tcp:close()
    end)
    on_ready(bind_err or "bind failed", nil)
    return
  end

  self.tcp = tcp

  -- luv returns either a table or (ip, port) depending on version.
  local a, b = tcp:getsockname()
  if type(a) == "table" then
    self.port = a.port
  else
    self.port = b
  end

  tcp:listen(128, function(listen_err)
    if listen_err then
      return
    end
    self:_accept()
  end)

  on_ready(nil, self.port)
end

--- @param id string
--- @param spec { name: string, source_dir: string, get_html: fun(): string }
function Server:add_preview(id, spec)
  self.previews[id] = {
    id = id,
    name = spec.name or id,
    source_dir = spec.source_dir,
    get_html = spec.get_html,
    clients = {},
    version = 0,
  }
end

--- Update where a preview's relative assets are resolved from, e.g. after
--- the buffer is renamed or saved to a new directory.
--- @param id string
--- @param dir string
function Server:set_source_dir(id, dir)
  local preview = self.previews[id]
  if preview then
    preview.source_dir = dir
  end
end

--- @param id string
function Server:remove_preview(id)
  local preview = self.previews[id]
  if not preview then
    return
  end
  for _, client in ipairs(preview.clients) do
    pcall(function()
      client:close()
    end)
  end
  preview.clients = {}
  self.previews[id] = nil
end

--- Tell every connected browser to reload. Called after new HTML is ready.
--- @param id string
function Server:update(id)
  local preview = self.previews[id]
  if not preview then
    return
  end

  preview.version = preview.version + 1
  local message = "event: reload\ndata: " .. preview.version .. "\n\n"

  local alive = {}
  for _, client in ipairs(preview.clients) do
    local ok = pcall(function()
      client:write(message)
    end)
    if ok then
      alive[#alive + 1] = client
    end
  end
  preview.clients = alive
end

--- Stop listening and drop every preview/client.
function Server:stop()
  for id in pairs(self.previews) do
    self:remove_preview(id)
  end
  if self.tcp then
    pcall(function()
      self.tcp:close()
    end)
    self.tcp = nil
  end
  self.port = nil
end

-- Internal ------------------------------------------------------------------

function Server:_accept()
  local client = uv.new_tcp()
  local ok = self.tcp:accept(client)
  if not ok then
    pcall(function()
      client:close()
    end)
    return
  end

  local buffer = ""
  client:read_start(function(err, chunk)
    if err or not chunk then
      pcall(function()
        client:close()
      end)
      return
    end

    buffer = buffer .. chunk
    if #buffer > 1024 * 1024 then
      pcall(function()
        client:close()
      end)
      return
    end

    local header_end = buffer:find("\r\n\r\n", 1, true)
    if not header_end then
      return
    end

    client:read_stop()
    self:_handle(client, buffer:sub(1, header_end - 1))
  end)
end

--- Require one well-formed Host header for the address and port we serve.
--- Binding to loopback alone does not stop DNS rebinding via an attacker Host.
--- This server binds IPv4 only, so [::1] is intentionally not accepted.
--- @param head string HTTP request headers without the terminating CRLFCRLF
--- @param port integer
--- @return boolean
local function valid_host_header(head, port)
  local lines = vim.split(head, "\r\n", { plain = true })
  if lines[1]:find("[\r\n]") then
    return false
  end
  local host
  for i = 2, #lines do
    local line = lines[i]
    if line:find("[\r\n]") then
      return false
    end
    local field, value = line:match("^([^:%s]+):[ \t]*(.-)[ \t]*$")
    if not field then
      return false
    end
    if field:lower() == "host" then
      if host then
        return false
      end
      host = value:lower()
    end
  end
  local suffix = ":" .. tostring(port)
  return host == "127.0.0.1" .. suffix or host == "localhost" .. suffix
end

function Server:_handle(client, head)
  local request_line = head:match("^([^\r\n]+)")
  local method, target
  if request_line then
    method, target = request_line:match("^(%u+)%s+(%S+)")
  end
  if not method then
    return self:_respond(client, 400, "Malformed request")
  end
  if not valid_host_header(head, self.port) then
    return self:_respond(client, 403, "Invalid Host header")
  end
  if method ~= "GET" then
    return self:_respond(client, 405, "Only GET is supported")
  end
  self:_route(client, target)
end

function Server:_route(client, target)
  local path = target:match("^([^?]*)") or "/"
  if path == "/" then
    return self:_index(client)
  end

  local id, rest = path:match("^/preview/([^/]+)/?(.*)$")
  if not id then
    return self:_respond(client, 404, "Not found")
  end

  local preview = self.previews[id]
  if not preview then
    return self:_respond(client, 404, "No such preview")
  end

  if rest == "" then
    return self:_respond(client, 200, preview.get_html(), "text/html; charset=utf-8")
  end
  if rest == "__events" then
    return self:_sse(client, preview)
  end
  return self:_asset(client, preview, rest)
end

function Server:_respond(client, code, body, ctype)
  body = body or ""
  local head = table.concat({
    "HTTP/1.1 " .. code .. " " .. (REASONS[code] or ""),
    "Content-Type: " .. (ctype or "text/plain; charset=utf-8"),
    "Content-Length: " .. #body,
    "Cache-Control: no-store",
    "Connection: close",
  }, "\r\n") .. "\r\n\r\n"

  client:write(head .. body)
  client:shutdown(function()
    pcall(function()
      client:close()
    end)
  end)
end

function Server:_index(client)
  local rows = {}
  for id, preview in pairs(self.previews) do
    rows[#rows + 1] = string.format(
      '<li><a href="/preview/%s/">%s</a></li>',
      html_escape(id),
      html_escape(preview.name)
    )
  end
  table.sort(rows)
  local body = "<!doctype html><meta charset='utf-8'><title>org-preview</title>"
    .. "<h1>org-preview</h1><ul>" .. table.concat(rows) .. "</ul>"
  self:_respond(client, 200, body, "text/html; charset=utf-8")
end

function Server:_sse(client, preview)
  client:write(table.concat({
    "HTTP/1.1 200 OK",
    "Content-Type: text/event-stream",
    "Cache-Control: no-cache",
    "Connection: keep-alive",
    "X-Accel-Buffering: no",
  }, "\r\n") .. "\r\n\r\n")
  client:write(": connected\n\n")

  preview.clients[#preview.clients + 1] = client

  -- Keep reading so we notice when the browser goes away.
  client:read_start(function(err, chunk)
    if err or not chunk then
      for i, c in ipairs(preview.clients) do
        if c == client then
          table.remove(preview.clients, i)
          break
        end
      end
      pcall(function()
        client:close()
      end)
    end
  end)
end

function Server:_asset(client, preview, rest)
  local path = safe_join(preview.source_dir, rest)
  if not path then
    return self:_respond(client, 404, "Not found")
  end

  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return self:_respond(client, 404, "Not found")
  end

  local fd = io.open(path, "rb")
  if not fd then
    return self:_respond(client, 404, "Not found")
  end
  local data = fd:read("*a")
  fd:close()

  local ext = path:match("%.([%w]+)$")
  local ctype = ext and MIME[ext:lower()] or "application/octet-stream"
  self:_respond(client, 200, data, ctype)
end

return M
