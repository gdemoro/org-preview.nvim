local server_mod = require("org-preview.server")

local function start_server()
  local srv = server_mod.new()
  local port
  local err
  srv:start(0, function(e, p)
    err, port = e, p
  end)
  assert(H.wait_for(function()
    return port ~= nil or err ~= nil
  end), "server did not start")
  assert(not err, tostring(err))
  return srv, port
end

--- Send a request verbatim to exercise malformed and duplicate Host headers.
local function raw_request(port, headers, path)
  local sock = vim.uv.new_tcp()
  local response = ""
  local connect_error
  sock:connect("127.0.0.1", port, function(err)
    if err then
      connect_error = err
      return
    end
    sock:write("GET " .. (path or "/") .. " HTTP/1.1\r\n" .. headers .. "\r\n\r\n")
  end)
  sock:read_start(function(err, data)
    if err then
      connect_error = err
    elseif data then
      response = response .. data
    end
  end)
  local done = H.wait_for(function()
    return connect_error or response:find("\r\n\r\n", 1, true)
  end)
  sock:close()
  assert(done and not connect_error, tostring(connect_error or "request timed out"))
  return response
end

test("server: binds to 127.0.0.1 on a free port", function()
  local srv, port = start_server()
  assert(type(port) == "number" and port > 0, "expected a port")
  assert(srv:is_running(), "server should report running")
  srv:stop()
  assert(not srv:is_running(), "server should stop")
end)

test("server: accepts loopback Host names with the listening port", function()
  local srv, port = start_server()
  srv:add_preview("p1", {
    name = "notes.org",
    source_dir = vim.uv.cwd(),
    get_html = function()
      return "preview content"
    end,
  })
  for _, host in ipairs({ "127.0.0.1", "localhost", "LOCALHOST" }) do
    local response = raw_request(port, "Host: " .. host .. ":" .. port, "/preview/p1/")
    assert(response:find("HTTP/1.1 200 OK", 1, true), "expected 200 for " .. host)
  end
  srv:stop()
end)

test("server: rejects external, missing, duplicate, and malformed Host headers", function()
  local srv, port = start_server()
  local invalid = {
    "Host: attacker.example:" .. port,
    "Host: localhost.attacker.example:" .. port,
    "Host: 127.0.0.1:" .. (port + 1),
    "Host: localhost", -- A port is required, even for a loopback name.
    "Host: [::1]:" .. port, -- No IPv6 socket is bound.
    "Host:",
    "Host : localhost:" .. port,
    "Host: localhost:" .. port .. "@attacker.example",
    "Host: localhost:" .. port .. "\r\nhOsT: attacker.example:" .. port,
    "Host: localhost:" .. port .. "\nHost: attacker.example:" .. port,
    "Accept: */*", -- Missing Host.
  }
  for _, headers in ipairs(invalid) do
    local response = raw_request(port, headers)
    assert(response:find("HTTP/1.1 403 Forbidden", 1, true), "unexpected Host accepted: " .. headers)
  end
  srv:stop()
end)

test("server: Host check applies to the index, assets, SSE, and multiple previews", function()
  local srv, port = start_server()
  for _, id in ipairs({ "p1", "p2" }) do
    srv:add_preview(id, {
      name = id,
      source_dir = vim.uv.cwd(),
      get_html = function()
        return "html"
      end,
    })
  end
  local paths = { "/", "/preview/p1/", "/preview/p2/", "/preview/p1/__events", "/preview/p2/README.md" }
  for _, path in ipairs(paths) do
    local allowed = raw_request(port, "Host: localhost:" .. port, path)
    assert(allowed:find("HTTP/1.1 200 OK", 1, true), "loopback Host blocked: " .. path)
    local blocked = raw_request(port, "Host: attacker.example:" .. port, path)
    assert(blocked:find("HTTP/1.1 403 Forbidden", 1, true), "invalid Host reached: " .. path)
  end
  srv:stop()
end)

test("server: serves preview HTML from a callback", function()
  local srv, port = start_server()
  srv:add_preview("p1", {
    name = "notes.org",
    source_dir = vim.uv.cwd(),
    get_html = function()
      return "<html><body>live buffer</body></html>"
    end,
  })

  local res = H.curl("http://127.0.0.1:" .. port .. "/preview/p1/")
  assert(res.code == 0, res.stderr)
  assert(res.stdout:match("live buffer"), "expected preview body")

  srv:stop()
end)

test("server: HTML-escapes filenames and displayed names in the index", function()
  local srv, port = start_server()
  local names = {
    { "notes&tasks.org", "notes&amp;tasks.org" },
    { "notes<tasks.org", "notes&lt;tasks.org" },
    { "notes>tasks.org", "notes&gt;tasks.org" },
    { 'notes"tasks.org', "notes&quot;tasks.org" },
    { "notes'tasks.org", "notes&#39;tasks.org" },
    { [[<img src=x onerror=alert(1)>]], "&lt;img src=x onerror=alert(1)&gt;" },
  }
  for i, pair in ipairs(names) do
    srv:add_preview("name-" .. i, {
      name = pair[1],
      source_dir = vim.uv.cwd(),
      get_html = function()
        return "html"
      end,
    })
  end

  local res = H.curl("http://127.0.0.1:" .. port .. "/")
  assert(res.code == 0, res.stderr)
  for i, pair in ipairs(names) do
    local row = string.format('<li><a href="/preview/name-%d/">%s</a></li>', i, pair[2])
    assert(res.stdout:find(row, 1, true), "expected escaped name: " .. pair[1])
  end
  assert(not res.stdout:find("<img", 1, true), "a displayed name must not inject HTML")
  srv:stop()
end)

test("server: HTML-escapes preview IDs used in index links", function()
  local srv, port = start_server()
  srv:add_preview([[id" onclick="alert(1)]], {
    name = "notes.org",
    source_dir = vim.uv.cwd(),
    get_html = function()
      return "html"
    end,
  })

  local res = H.curl("http://127.0.0.1:" .. port .. "/")
  assert(res.code == 0, res.stderr)
  assert(res.stdout:find('href="/preview/id&quot; onclick=&quot;alert(1)/"', 1, true))
  assert(not res.stdout:find('href="/preview/id" onclick=', 1, true))
  srv:stop()
end)

test("server: reflects updated HTML immediately", function()
  local srv, port = start_server()
  local body = "first"
  srv:add_preview("p2", {
    name = "notes.org",
    source_dir = vim.uv.cwd(),
    get_html = function()
      return body
    end,
  })

  local first = H.curl("http://127.0.0.1:" .. port .. "/preview/p2/")
  assert(first.stdout:match("first"))

  body = "second"
  local second = H.curl("http://127.0.0.1:" .. port .. "/preview/p2/")
  assert(second.stdout:match("second"), "expected updated body")

  srv:stop()
end)

test("server: serves static assets from the source directory", function()
  local dir = H.temp_dir("assets")
  local asset = vim.fs.joinpath(dir, "images")
  vim.fn.mkdir(asset, "p")
  local fd = io.open(vim.fs.joinpath(asset, "pic.txt"), "w")
  fd:write("asset payload")
  fd:close()

  local srv, port = start_server()
  srv:add_preview("p3", {
    name = "notes.org",
    source_dir = dir,
    get_html = function()
      return "html"
    end,
  })

  local res = H.curl("http://127.0.0.1:" .. port .. "/preview/p3/images/pic.txt")
  assert(res.stdout:match("asset payload"), "expected asset content")

  srv:stop()
  H.rm_rf(dir)
end)

test("server: refuses path traversal", function()
  local dir = H.temp_dir("traversal")
  local srv, port = start_server()
  srv:add_preview("p4", {
    name = "notes.org",
    source_dir = dir,
    get_html = function()
      return "html"
    end,
  })

  local res = H.curl("http://127.0.0.1:" .. port .. "/preview/p4/..%2f..%2fetc/passwd")
  assert(not res.stdout:match("root:"), "traversal must not leak files")
  assert(res.stdout:match("Not found"), "expected a 404 body")

  srv:stop()
  H.rm_rf(dir)
end)

test("server: refuses encoded path traversal variants", function()
  local dir = H.temp_dir("traversal-encoded")
  local srv, port = start_server()
  srv:add_preview("p4", {
    name = "notes.org",
    source_dir = dir,
    get_html = function()
      return "html"
    end,
  })

  local attacks = {
    "..%2f..%2fetc/passwd",
    "%2e%2e/%2e%2e/etc/passwd",
    "%2E%2E/%2E%2E/etc/passwd",
    "..%5c..%5cetc%5cpasswd",
    "%2e%2e%5c%2e%2e%5cetc%5cpasswd",
  }
  for _, attack in ipairs(attacks) do
    local res = H.curl("http://127.0.0.1:" .. port .. "/preview/p4/" .. attack)
    assert(not res.stdout:match("root:"), "traversal leaked via " .. attack)
    assert(res.stdout:match("Not found"), "expected 404 for " .. attack)
  end

  srv:stop()
  H.rm_rf(dir)
end)

test("server: follows symlinks only while they stay inside the source dir", function()
  local dir = H.temp_dir("symlink")
  local outside = H.temp_dir("outside")

  local fd = io.open(vim.fs.joinpath(outside, "secret.txt"), "w")
  fd:write("top secret")
  fd:close()
  local fd2 = io.open(vim.fs.joinpath(dir, "real.txt"), "w")
  fd2:write("public")
  fd2:close()

  assert(vim.uv.fs_symlink(vim.fs.joinpath(outside, "secret.txt"), vim.fs.joinpath(dir, "escape.txt")))
  assert(vim.uv.fs_symlink("real.txt", vim.fs.joinpath(dir, "inside.txt")))

  local srv, port = start_server()
  srv:add_preview("p6", {
    name = "notes.org",
    source_dir = dir,
    get_html = function()
      return "html"
    end,
  })

  local escaped = H.curl("http://127.0.0.1:" .. port .. "/preview/p6/escape.txt")
  assert(not escaped.stdout:match("top secret"), "symlink escaped the source directory")
  assert(escaped.stdout:match("Not found"), "expected 404 for escaping symlink")

  local allowed = H.curl("http://127.0.0.1:" .. port .. "/preview/p6/inside.txt")
  assert(allowed.stdout:match("public"), "expected an inside symlink to be served")

  srv:stop()
  H.rm_rf(dir)
  H.rm_rf(outside)
end)

test("server: 404s for unknown previews", function()
  local srv, port = start_server()
  local res = H.curl("http://127.0.0.1:" .. port .. "/preview/nope/")
  assert(res.stdout:match("No such preview"), "expected 404 message")
  srv:stop()
end)

test("server: delivers reload events over SSE", function()
  local srv, port = start_server()
  srv:add_preview("p5", {
    name = "notes.org",
    source_dir = vim.uv.cwd(),
    get_html = function()
      return "html"
    end,
  })

  local uv = vim.uv
  local sock = uv.new_tcp()
  local received = ""

  sock:connect("127.0.0.1", port, function(err)
    if err then
      return
    end
    sock:write("GET /preview/p5/__events HTTP/1.1\r\nHost: 127.0.0.1:" .. port .. "\r\n\r\n")
  end)
  sock:read_start(function(err, data)
    if data then
      received = received .. data
    end
  end)

  assert(H.wait_for(function()
    return received:match("connected") ~= nil
  end), "expected the SSE handshake, got: " .. tostring(received))

  srv:update("p5")
  assert(H.wait_for(function()
    return received:match("event: reload") ~= nil
  end), "expected a reload event, got: " .. tostring(received))

  pcall(function()
    sock:close()
  end)
  srv:stop()
end)
