-- plugin/mdwrap.lua — FileType 集成与命令注册
if vim.g.loaded_mdwrap then return end
vim.g.loaded_mdwrap = true

require("mdwrap").create_commands()

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "quarto", "pandoc", "rmd" },
  callback = function()
    -- 回调在 setup() 之后触发，读到合并后的配置；set_formatexpr=false 时让 gq 回退默认。
    if require("mdwrap").options.set_formatexpr == false then return end
    vim.bo.formatexpr = "v:lua.require'mdwrap'.formatexpr()"
  end,
})
