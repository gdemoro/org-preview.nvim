--- User commands for org-preview.nvim. Commands are always defined so they
--- work even when the plugin is loaded lazily.
if vim.g.loaded_org_preview == 1 then
  return
end
vim.g.loaded_org_preview = 1

vim.api.nvim_create_user_command("OrgPreview", function()
  require("org-preview").start()
end, { desc = "Start live Org preview for the current buffer" })

vim.api.nvim_create_user_command("OrgPreviewStop", function()
  require("org-preview").stop()
end, { desc = "Stop the live preview for the current buffer" })

vim.api.nvim_create_user_command("OrgPreviewToggle", function()
  require("org-preview").toggle()
end, { desc = "Toggle the live Org preview for the current buffer" })
