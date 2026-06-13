-- minimal_init.lua — headless golden 测试的最小运行时
-- 确保：① 本仓库 lua/ 在 package.path；② markdown / markdown_inline parser 与
-- highlights 查询可用（优先内置；否则探测 nvim-treesitter）。

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path

-- 探测 nvim-treesitter（提供 markdown_inline highlights 查询 / conceal 元数据）
local data = vim.fn.stdpath("data")
for _, p in ipairs({
  data .. "/lazy/nvim-treesitter",
  data .. "/site/pack/packer/start/nvim-treesitter",
  data .. "/site/pack/*/start/nvim-treesitter",
}) do
  for _, hit in ipairs(vim.fn.glob(p, false, true)) do
    if vim.fn.isdirectory(hit) == 1 then
      vim.opt.runtimepath:append(hit)
    end
  end
end

-- 触发 nvim-treesitter 运行时（注册查询）
pcall(vim.cmd, "runtime! plugin/nvim-treesitter.lua")

-- 自检：markdown_inline highlights 查询是否可用（缺失则集成层无法扣 conceal）
if not vim.treesitter.query.get("markdown_inline", "highlights") then
  vim.notify("[mdwrap test] markdown_inline highlights query NOT available — conceal 宽度将不准", vim.log.levels.WARN)
end
