-- init.lua — 编辑器集成、formatexpr 入口、管线串联
--
-- 管线：blocks.split → （每个 wrap 块）merge_lines → atomize → spacing → layout.wrap → 回写。
-- 回写自底向上逐块替换，避免行号漂移。

local config = require("mdwrap.config")
local blocks = require("mdwrap.blocks")
local atoms = require("mdwrap.atoms")
local spacing = require("mdwrap.spacing")
local layout = require("mdwrap.layout")

local M = {}

---@type mdwrap.Config
M.options = config.defaults()

--- 合并用户配置。
---@param opts mdwrap.Opts?
function M.setup(opts)
  M.options = vim.tbl_extend("force", config.defaults(), opts or {})
end

--- 宽度取值顺序：显式 width ＞ buffer textwidth（非 0）＞ 80。
local function resolve_width(opts, bufnr)
  if opts.width and opts.width > 0 then return opts.width end
  local tw = vim.bo[bufnr].textwidth
  if tw and tw > 0 then return tw end
  return 80
end

--- 是否扣除 conceal 宽度：respect_conceallevel 且（headless 或窗口 conceallevel>0）。
local function conceal_enabled(opts, bufnr)
  if opts.respect_conceallevel == false then return true end
  -- 找到显示该 buffer 的窗口，读其 conceallevel；无窗口（headless）默认按扣除处理
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return (vim.wo[win].conceallevel or 0) > 0
    end
  end
  return true
end

--- 处理一个 wrap 块，返回新的行列表。
---@param b mdwrap.Block
---@param opts mdwrap.Config
---@param width integer
---@param conceal boolean
---@return string[]
local function process_wrap(b, opts, width, conceal)
  local width_fn = vim.fn.strdisplaywidth
  if opts.keep_origin_wrap then
    -- 保留原换行：逐行 atomize + spacing，仅清行尾空白
    local out = {}
    for idx, line in ipairs(b.content_lines) do
      local as = atoms.atomize(line, { width_fn = width_fn, conceal = conceal })
      if opts.cjk_english_spacing then as = spacing.apply(as) end
      local parts = {}
      for _, a in ipairs(as) do parts[#parts + 1] = a.text end
      local prefix = (idx == 1) and b.prefix_first or b.prefix_rest
      out[#out + 1] = (prefix .. table.concat(parts)):gsub("%s+$", "")
    end
    return out
  end
  -- 默认：合并逻辑行 → 原子化 → 盘古空格 → 折行
  local logical = layout.merge_lines(b.content_lines)
  local as = atoms.atomize(logical, { width_fn = width_fn, conceal = conceal })
  if opts.cjk_english_spacing then as = spacing.apply(as) end
  return layout.wrap(as, {
    width = width,
    prefix_first = b.prefix_first,
    prefix_rest = b.prefix_rest,
    wrap_sentence = opts.wrap_sentence,
    width_fn = width_fn,
  })
end

--- 格式化缓冲区（headless / 命令 / formatexpr 共用）。
---@param bufnr integer|nil 0 或 nil 表示当前缓冲区
---@param opts mdwrap.FormatOpts? 覆盖配置；可含 row_start/row_end（0-indexed，闭区间）限定范围
function M.format_buffer(bufnr, opts)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  ---@cast bufnr integer
  opts = vim.tbl_extend("force", M.options, opts or {})
  local bs = blocks.split(bufnr)
  local width = resolve_width(opts, bufnr)
  local conceal = conceal_enabled(opts, bufnr)

  local rs, re = opts.row_start, opts.row_end
  for i = #bs, 1, -1 do
    local b = bs[i]
    local in_range = (not rs) or (b.srow <= (re or rs) and b.erow >= rs)
    if b.action == "wrap" and in_range then
      local new = process_wrap(b, opts, width, conceal)
      vim.api.nvim_buf_set_lines(bufnr, b.srow, b.erow + 1, false, new)
    end
  end
end

--- formatexpr 契约：插入模式回退（返回 1）；正常模式按 v:lnum/v:count 限定范围处理。
function M.formatexpr()
  if vim.fn.mode():match("[iR]") or vim.v.char ~= "" then return 1 end
  local lnum = vim.v.lnum - 1
  local cnt = vim.v.count
  local rend = (cnt > 0) and (lnum + cnt - 1) or lnum
  M.format_buffer(0, { row_start = lnum, row_end = rend })
  return 0
end

--- 创建 :MdwrapFormat 命令（整 buffer 或范围）。
function M.create_commands()
  vim.api.nvim_create_user_command("MdwrapFormat", function(a)
    if a.range > 0 then
      M.format_buffer(0, { row_start = a.line1 - 1, row_end = a.line2 - 1 })
    else
      M.format_buffer(0, {})
    end
  end, { range = true })
end

return M
