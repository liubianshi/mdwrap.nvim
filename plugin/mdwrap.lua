-- plugin/mdwrap.lua — FileType 集成与命令注册
if vim.g.loaded_mdwrap then return end
vim.g.loaded_mdwrap = true

require("mdwrap").create_commands()

local FTS = { markdown = true, quarto = true, pandoc = true, rmd = true }

--- 对单个 buffer 设置 formatexpr（set_formatexpr=false 时让 gq 回退默认）。
local function set_formatexpr(buf)
  if require("mdwrap").options.set_formatexpr == false then return end
  vim.bo[buf].formatexpr = "v:lua.require'mdwrap'.formatexpr()"
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "quarto", "pandoc", "rmd" },
  -- 回调在 setup() 之后触发，读到合并后的配置；set_formatexpr=false 时让 gq 回退默认。
  callback = function(args) set_formatexpr(args.buf) end,
})

-- 懒加载补偿：lazy.nvim 以 `ft=` 懒加载本插件时，是 FileType 事件本身触发了加载，而上面的
-- autocmd 此刻才注册，错过了那次事件 → 首个 buffer 漏设 formatexpr（需手动 `:set ft=markdown`
-- 重新触发才生效）。故对所有已加载的匹配 buffer 补设一次。用 vim.schedule 延后到本轮加载
-- （含 lazy 的 config/setup）跑完，确保读到的是合并后的 set_formatexpr。
vim.schedule(function()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and FTS[vim.bo[buf].filetype] then
      set_formatexpr(buf)
    end
  end
end)
