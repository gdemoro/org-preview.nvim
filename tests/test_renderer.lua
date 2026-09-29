local renderer = require("org-preview.renderer")

if not renderer.is_available() then
  test("renderer: pandoc is available", function()
    -- Skipped: pandoc is not installed in this environment.
  end)
  return
end

test("renderer: renders Org headings to HTML", function()
  local done = false
  local err, html
  renderer.render({
    content = "* Hello world\n\nSome *bold* text.\n",
    source_dir = vim.uv.cwd(),
  }, function(e, h)
    err, html = e, h
    done = true
  end)

  assert(H.wait_for(function()
    return done
  end), "render timed out")
  assert(not err, err)
  assert(html:match("<h1"), "expected an <h1> in pandoc output")
  assert(html:match("Hello world"), "expected heading text")
  assert(html:match("<strong>bold</strong>"), "expected bold markup")
end)

test("renderer: preserves relative image paths", function()
  local done = false
  local err, html
  renderer.render({
    content = "[[./images/pic.png]]\n",
    source_dir = vim.uv.cwd(),
  }, function(e, h)
    err, html = e, h
    done = true
  end)

  assert(H.wait_for(function()
    return done
  end), "render timed out")
  assert(not err, err)
  assert(html:match("images/pic%.png"), "expected the relative image path to survive")
end)

test("renderer: reports a clear error when conversion fails", function()
  local done = false
  local err
  -- An unknown reader makes pandoc exit non-zero.
  renderer.render({
    content = "hello",
    source_dir = vim.uv.cwd(),
    pandoc_args = { "--from=nope-not-a-format" },
  }, function(e)
    err = e
    done = true
  end)

  assert(H.wait_for(function()
    return done
  end), "render timed out")
  assert(err and err:match("pandoc"), "expected a pandoc error, got: " .. tostring(err))
end)
