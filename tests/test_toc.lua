--- Regression tests for the client-side table of contents.
---
--- The JavaScript runtime behavior is verified by executing the *actual*
--- injected client script (extracted from served HTML) inside a dependency-free
--- Node `fs`/`vm` harness (`tests/toc_client.js`).  When `node` is not
--- available those cases print a clear skip line and the Lua integration /
--- structure cases still run.  No npm packages are ever required.
local op = require("org-preview")

local HAVE_NODE = vim.fn.executable("node") == 1
local skipped_node = 0

--- Register a Node-backed test, or clearly skip it when node is absent.
local function node_test(name, fn)
  if not HAVE_NODE then
    skipped_node = skipped_node + 1
    io.write("skip - " .. name .. " (node not available)\n")
    return
  end
  test(name, fn)
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

--- Fetch the served HTML for a buffer.
local function serve(bufnr)
  local p = H.preview_for(bufnr)
  assert(p, "expected an active preview")
  local res = H.curl(p.url)
  assert(res.code == 0, "curl failed: " .. tostring(res.stderr))
  return res.stdout
end

--- Start a preview and wait until `predicate(html)` holds.
local function wait_for_html(bufnr, predicate)
  local html
  assert(H.wait_for(function()
    html = serve(bufnr)
    return predicate(html)
  end), "preview HTML did not satisfy the predicate")
  return html
end

--- Extract the injected TOC client script from served HTML.
local function extract_toc_script(html)
  for block in html:gmatch("<script>.-</script>") do
    if block:find("op-toc-toggle", 1, true) then
      return block:match("^<script>(.*)</script>$") or block
    end
  end
  return nil
end

local toc_script_cache = nil

--- The actual script injected into served pages (cached across cases).
local function actual_toc_script()
  if toc_script_cache then
    return toc_script_cache
  end
  local dir = H.temp_dir("toc-script")
  local bufnr = H.open_org(dir, "notes.org", "* Alpha\n** Beta\n")
  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)
  local html = wait_for_html(bufnr, function(h)
    return h:find("op-toc-toggle", 1, true) ~= nil
  end)
  op.stop(bufnr)
  H.rm_rf(dir)
  toc_script_cache = extract_toc_script(html)
  assert(toc_script_cache, "could not extract the injected TOC script")
  return toc_script_cache
end

local function write_file(path, data)
  local fd = io.open(path, "w")
  assert(fd, "could not write " .. path)
  fd:write(data)
  fd:close()
end

--- Run the injected TOC script over `html` via the Node harness.
--- @param html string
--- @param opts table|nil  { ready = "complete"|"loading", wide = boolean }
--- @return table decoded snapshot
local function run_toc(html, opts)
  opts = opts or {}
  local dir = H.temp_dir("toc-js")
  local htmlfile = vim.fs.joinpath(dir, "fixture.html")
  local scriptfile = vim.fs.joinpath(dir, "toc.js")
  write_file(htmlfile, html)
  write_file(scriptfile, actual_toc_script())
  local harness = vim.fs.joinpath(vim.fn.getcwd(), "tests", "toc_client.js")
  local res = H.run({
    "node",
    harness,
    "--html",
    htmlfile,
    "--script",
    scriptfile,
    "--ready",
    opts.ready or "complete",
    "--wide",
    opts.wide and "1" or "0",
  })
  H.rm_rf(dir)
  assert(res.code == 0, "node harness failed: " .. tostring(res.stderr))
  return vim.json.decode(res.stdout)
end

local function heading(tag, id, text)
  if id then
    return string.format('<%s id="%s">%s</%s>', tag, id, text, tag)
  end
  return string.format('<%s>%s</%s>', tag, text, tag)
end

local function fixture(headings)
  return '<!DOCTYPE html>\n<html><head></head><body>\n'
    .. headings
    .. "\n</body></html>"
end

--- Count injected <script> blocks whose body contains `needle`.
local function count_scripts(haystack, needle)
  local n = 0
  for block in haystack:gmatch("<script>.-</script>") do
    if block:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

----------------------------------------------------------------------
-- JS runtime behavior: structural cases
----------------------------------------------------------------------

node_test("toc: H1-H6 with skipped levels produce flat data-level items", function()
  local html = fixture(
    heading("h1", "one", "One")
      .. heading("h2", "two", "Two")
      .. heading("h4", "four", "Four")
      .. heading("h6", "six", "Six")
      .. heading("h3", "three", "Three")
      .. heading("h5", "five", "Five")
  )
  local r = run_toc(html, { wide = true })
  assert(r.navCount == 1, "expected exactly one sidebar")
  assert(#r.links == 6, "expected six entries, got " .. #r.links)
  -- Document order is preserved; levels are flattened so a skipped level
  -- (h4/h6 before h3/h5) still yields one flat list entry per heading.
  local want_levels = { "1", "2", "4", "6", "3", "5" }
  local want_hrefs = { "#one", "#two", "#four", "#six", "#three", "#five" }
  for i = 1, 6 do
    assert(r.links[i].level == want_levels[i], "level mismatch at " .. i)
    assert(r.links[i].href == want_hrefs[i], "href mismatch at " .. i)
  end
end)

node_test("toc: duplicate labels keep distinct existing IDs", function()
  local html = fixture(
    heading("h2", "alpha", "Same")
      .. heading("h2", "beta", "Same")
  )
  local r = run_toc(html, { wide = true })
  assert(#r.links == 2, "expected two entries")
  assert(r.links[1].text == "Same" and r.links[2].text == "Same", "labels should match")
  assert(r.links[1].href == "#alpha", "first href")
  assert(r.links[2].href == "#beta", "second href")
  -- Each link must scroll its own heading, by direct reference.
  assert(r.scrollTargets[1] == "alpha", "first link scrolled wrong heading")
  assert(r.scrollTargets[2] == "beta", "second link scrolled wrong heading")
end)

node_test("toc: special heading IDs are URI-encoded in hrefs", function()
  local html = fixture(
    heading("h1", "a b/c", "Slashy")
      .. heading("h2", "tab\tx", "Tabbed")
      .. heading("h3", "pct%hash#café", "Mixed")
  )
  local r = run_toc(html, { wide = true })
  assert(r.links[1].href == "#a%20b%2Fc", "space/slash encoding, got " .. r.links[1].href)
  assert(r.links[2].href == "#tab%09x", "tab encoding, got " .. r.links[2].href)
  -- Percent, hash and non-ASCII characters are all component-encoded; the
  -- link must still resolve to the untouched heading id when clicked.
  assert(r.links[3].href == "#pct%25hash%23caf%C3%A9",
    "percent/hash/unicode encoding, got " .. r.links[3].href)
  assert(r.scrollTargets[3] == "pct%hash#café",
    "encoded link must scroll the original id, got " .. tostring(r.scrollTargets[3]))
end)

node_test("toc: heading IDs are never modified", function()
  local html = fixture(
    heading("h1", "keep-one", "One")
      .. heading("h2", "keep-two", "Two")
  )
  local r = run_toc(html, { wide = true })
  local ids = {}
  for _, h in ipairs(r.headings) do
    ids[h.tag .. ":" .. tostring(h.id)] = true
  end
  assert(ids["H1:keep-one"], "h1 id changed or missing")
  assert(ids["H2:keep-two"], "h2 id changed or missing")
end)

node_test("toc: no UI for heading-less, unlinkable, or title-only documents", function()
  -- No headings at all.
  local r = run_toc(fixture("<p>Just a paragraph.</p>"), { wide = true })
  assert(r.navCount == 0 and not r.hasToggle, "headless doc must have no UI")

  -- Headings without IDs, or with an empty id, are unlinkable (nothing to
  -- link to), so they must not produce any UI.
  local r2 = run_toc(fixture(
    heading("h1", nil, "A")
      .. heading("h2", "", "B")
      .. heading("h3", nil, "C")
  ), { wide = true })
  assert(r2.navCount == 0 and not r2.hasToggle, "unlinkable/empty-id headings must have no UI")

  -- Only the Pandoc title block (an ID-bearing heading inside it).
  local r3 = run_toc(
    fixture('<header id="title-block-header"><h1 class="title" id="doc">Doc</h1></header>'),
    { wide = true }
  )
  assert(r3.navCount == 0 and not r3.hasToggle, "title-only doc must have no UI")
end)

node_test("toc: title block is excluded, real outline heading is included", function()
  local html = fixture(
    '<header id="title-block-header"><h1 class="title" id="the-title">Doc</h1></header>'
      .. heading("h1", "intro", "Intro")
  )
  local r = run_toc(html, { wide = true })
  assert(#r.links == 1, "only the outline heading should be listed")
  assert(r.links[1].href == "#intro", "outline heading missing")
  assert(r.scrollTargets[1] == "intro", "outline heading not scrollable")

  -- A `.title`-classed heading *outside* the title block is a normal outline
  -- heading and must be included.  The fixture must actually carry
  -- class="title" for the case to genuinely exercise that condition.
  local title_html = '<h1 class="title" id="real-title">Real</h1>'
  assert(title_html:find('class="title"', 1, true), "fixture must carry class=title")
  local r2 = run_toc(fixture(title_html), { wide = true })
  assert(#r2.links == 1 and r2.links[1].href == "#real-title", "title-class heading dropped")
  assert(r2.headings[1].className == "title", "fixture/stub must report the title class")
end)

node_test("toc: standalone heading id=title-block-header is retained", function()
  -- A real Org outline heading whose own id happens to be
  -- 'title-block-header' must still be linked/clickable; only a heading inside
  -- the Pandoc `header#title-block-header` container is excluded.
  local html = fixture(
    '<header id="title-block-header"><h1 class="title" id="the-title">Doc</h1></header>'
      .. heading("h1", "title-block-header", "Collision")
  )
  local r = run_toc(html, { wide = true })
  assert(r.navCount == 1 and r.hasToggle, "collision heading must still produce UI")
  assert(#r.links == 1, "only the standalone collision heading should be listed")
  assert(r.links[1].href == "#title-block-header", "collision heading missing")
  assert(r.scrollTargets[1] == "title-block-header", "collision heading not clickable")
  local ids = {}
  for _, h in ipairs(r.headings) do
    ids[h.id] = true
  end
  assert(ids["title-block-header"], "collision heading id must be unchanged")
  assert(ids["the-title"], "title id must be unchanged")
end)

node_test("toc: nav/control IDs avoid collisions and the toggle stays ID-less", function()
  local html = fixture(
    '<div id="op-toc">taken</div><div id="op-toc-1">taken too</div>'
      .. heading("h1", "x", "X")
  )
  local r = run_toc(html, { wide = true })
  assert(r.navCount == 1, "expected one generated sidebar")
  assert(r.navIds[1] == "op-toc-2", "collision-free nav id, got " .. tostring(r.navIds[1]))
  assert(r.toggle.ariaControls == "op-toc-2", "aria-controls must point at the nav id")
  assert(r.toggle.hasId == false, "the toggle must not carry an id")
end)

----------------------------------------------------------------------
-- JS runtime behavior: open/closed state
----------------------------------------------------------------------

node_test("toc: wide viewport defaults to open", function()
  local r = run_toc(fixture(heading("h1", "a", "A")), { wide = true })
  assert(r.hasToggle, "expected a toggle")
  assert(r.initial.expanded == "true", "expected aria-expanded=true")
  assert(r.initial.hidden == false, "expected nav visible")
  assert(r.initial.bodyOpen == true, "expected body.op-toc-open")
end)

node_test("toc: narrow viewport defaults to closed", function()
  local r = run_toc(fixture(heading("h1", "a", "A")), { wide = false })
  assert(r.hasToggle, "expected a toggle")
  assert(r.initial.expanded == "false", "expected aria-expanded=false")
  assert(r.initial.hidden == true, "expected nav hidden")
  assert(r.initial.bodyOpen == false, "expected no body.op-toc-open")
end)

node_test("toc: toggle keeps hidden/aria/body class in sync", function()
  local r = run_toc(fixture(heading("h1", "a", "A")), { wide = true })
  assert(r.initial.expanded == "true" and r.initial.bodyOpen == true, "initial open state")
  -- First click closes everything.
  assert(r.afterFirst.expanded == "false", "aria-expanded after close")
  assert(r.afterFirst.hidden == true, "nav hidden after close")
  assert(r.afterFirst.bodyOpen == false, "layout class removed after close")
  -- Second click reopens.
  assert(r.afterSecond.expanded == "true", "aria-expanded after reopen")
  assert(r.afterSecond.hidden == false, "nav visible after reopen")
  assert(r.afterSecond.bodyOpen == true, "layout class restored after reopen")
end)

node_test("toc: initializes after DOMContentLoaded when still loading", function()
  local loading = run_toc(fixture(heading("h1", "a", "A")), { wide = true, ready = "loading" })
  assert(loading.deferred == true, "expected deferred initialization")
  assert(loading.navCountBefore == 0, "no sidebar before DOMContentLoaded")
  assert(loading.navCount == 1, "sidebar built after DOMContentLoaded")
  assert(loading.initial.expanded == "true", "default state applied after load")

  local ready = run_toc(fixture(heading("h1", "a", "A")), { wide = true, ready = "complete" })
  assert(ready.deferred == false, "expected immediate initialization")
  assert(ready.navCountBefore == 1, "sidebar built immediately")
end)

----------------------------------------------------------------------
-- Integration: served HTML, CSS, live reload
----------------------------------------------------------------------

test("toc: injected CSS carries hierarchy, theme and open-only layout", function()
  local dir = H.temp_dir("toc-css")
  local bufnr = H.open_org(dir, "notes.org", "* Alpha\n** Beta\n*** Gamma\n")
  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find("op-toc-toggle", 1, true) ~= nil
  end)

  assert(html:find("--op-toc-width: 280px", 1, true), "TOC width token missing")
  assert(html:find(".op-toc-toggle", 1, true), "toggle style missing")
  assert(html:find(".op-toc-list", 1, true), "list style missing")
  assert(html:find(".op-toc-item", 1, true), "item style missing")
  assert(html:find(".op-toc-link", 1, true), "link style missing")
  assert(html:find('[data-level="2"]', 1, true), "level-2 indentation missing")
  assert(html:find('[data-level="6"]', 1, true), "level-6 indentation missing")
  assert(html:find("var(--op-surface)", 1, true), "themed surface token missing")
  assert(html:find("var(--op-border)", 1, true), "themed border token missing")
  assert(html:find("var(--op-link)", 1, true), "themed link token missing")

  -- The body offset is scoped to the open state and lives inside the wide
  -- media query, so a closed sidebar restores the original layout.
  local media = html:find("@media (min-width: 721px)", 1, true)
  local open_rule = html:find("body.op-toc-open {", 1, true)
  assert(media and open_rule and open_rule > media, "open-state offset must be inside the wide query")

  -- The closed-state toggle is anchored to the bottom-right corner (so it
  -- never covers the first heading/title), while the open-state toggle keeps
  -- its top-left origin inside the sidebar's reserved padding.
  local closed_sel = '.op-toc-toggle[aria-expanded="false"]'
  local closed_at = html:find(closed_sel, 1, true)
  assert(closed_at, "closed-state toggle rule missing")
  local closed_block = html:sub(closed_at, html:find("}", closed_at, true))
  assert(closed_block:find("bottom: 0.75rem", 1, true), "closed toggle must anchor to bottom")
  assert(closed_block:find("right: 0.75rem", 1, true), "closed toggle must anchor to right")
  assert(closed_block:find("top: auto", 1, true), "closed toggle must reset top")
  assert(closed_block:find("left: auto", 1, true), "closed toggle must reset left")

  -- No closed-state body layout offset: the only body margin offset is the
  -- open-state rule inside the wide media query.
  assert(not html:find("body:not(.op-toc-open)", 1, true),
    "closed body must not carry a layout offset")
  local offset_at = html:find("margin-left: var(--op-toc-width)", 1, true)
  assert(offset_at and offset_at > open_rule,
    "body offset must exist only inside the open-state rule")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("toc: real pandoc output exposes linkable headings and reload script", function()
  local dir = H.temp_dir("toc-pandoc")
  local bufnr = H.open_org(dir, "notes.org", "* First Section\n\nBody.\n\n** Nested\n")
  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  local html = wait_for_html(bufnr, function(h)
    return h:find('id="first-section"', 1, true) ~= nil
  end)
  assert(html:find('id="nested"', 1, true), "nested heading id missing")
  assert(html:find("op-toc-toggle", 1, true), "TOC client missing")
  assert(html:find("EventSource(", 1, true), "SSE reload client missing")
  assert(html:find("__events", 1, true), "SSE endpoint missing")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

test("toc: client rebuilds on live buffer update and SSE stays unchanged", function()
  local dir = H.temp_dir("toc-live")
  local bufnr = H.open_org(dir, "notes.org", "* First\n")
  op.config.css = nil
  op.setup({ open_browser = false, auto_open = false, debounce = 10 })
  op.start(bufnr)

  wait_for_html(bufnr, function(h)
    return h:find('id="first"', 1, true) ~= nil
  end)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "* Renamed Section", "** Child Heading" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })

  local html = wait_for_html(bufnr, function(h)
    return h:find('id="renamed-section"', 1, true) ~= nil
  end)
  assert(html:find('id="child-heading"', 1, true), "fresh heading id missing after update")
  assert(count_scripts(html, "op-toc-toggle") == 1, "the TOC script must be injected exactly once")
  assert(count_scripts(html, "EventSource(") == 1, "the reload script must be unchanged")

  op.stop(bufnr)
  H.rm_rf(dir)
end)

if skipped_node > 0 then
  io.write("\n(test_toc: " .. skipped_node .. " Node-backed case(s) skipped)\n")
end
