-- plugin/mdwrap.lua — FileType 集成与命令注册
if vim.g.loaded_mdwrap then return end
vim.g.loaded_mdwrap = true

require("mdwrap").create_commands()

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "quarto", "pandoc", "rmd" },
  callback = function()
    vim.bo.formatexpr = "v:lua.require'mdwrap'.formatexpr()"
  end,
})
