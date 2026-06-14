-- init.lua — 编辑器集成、formatexpr 入口、管线串联
--
-- 管线：blocks.split → （每个 wrap 块）merge_lines → atomize → spacing → layout.wrap → 回写。
-- 回写自底向上逐块替换，避免行号漂移。

local config = require("mdwrap.config")
local blocks = require("mdwrap.blocks")
local atoms = require("mdwrap.atoms")
local spacing = require("mdwrap.spacing")
local layout = require("mdwrap.layout")
local conceal_mod = require("mdwrap.conceal")

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
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local tw = vim.bo[bufnr].textwidth
    if tw and tw > 0 then return tw end
  end
  return 80
end

--- 是否扣除 conceal 宽度：respect_conceallevel 且（headless / 无 bufnr 或窗口 conceallevel>0）。
local function conceal_enabled(opts, bufnr)
  if opts.respect_conceallevel == false then return true end
  -- 找到显示该 buffer 的窗口，读其 conceallevel；无窗口/无 bufnr（headless）默认按扣除处理
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        return (vim.wo[win].conceallevel or 0) > 0
      end
    end
  end
  return true
end

--- 读取并按 block 的 prefix/merge 映射，把 buffer 坐标的渲染 extmark 翻译成：
---   1) 正文区覆盖（逻辑串坐标 mdwrap.ExtmarkConceal[]，喂 atomize）；
---   2) 前缀区净增量（M5-B：聚成 prefix_first/prefix_rest 的占宽增量）。
--- ctx == nil 或未开 read_extmark ⇒ 返回空，零增量（headless 无渲染插件即此路径）。
---@param b mdwrap.Block
---@param ctx table?  -- { bufnr, read_extmark, expected_lines }
---@return mdwrap.Mark[] marks
local function gather_marks(b, ctx)
  if not (ctx and ctx.read_extmark) then return {} end
  return conceal_mod.gather(ctx.bufnr, b.srow, b.erow, ctx.expected_lines)
end

--- 把**正文区** mark（buffer 坐标）翻译成 seg 逻辑串坐标下的 ExtmarkConceal。
--- 落在前缀区（cs < removed）或越出 seg 内容范围返回 nil。两条折行路径共用：
---   * 默认（合并）路径传该行的真实 seg；
---   * keep_origin_wrap 传恒等 seg `{lstart=0, lend=#line, strip_lead=0}`（不合并，逻辑串即该行）。
---@param mk mdwrap.Mark
---@param removed integer  该行被剥掉的前缀字节数
---@param seg table        -- { lstart, lend, strip_lead }
---@return mdwrap.ExtmarkConceal?
local function body_mark_ex(mk, removed, seg)
  local cs_src = mk.cs - removed
  if cs_src < 0 then return nil end -- 前缀区，留给前缀净增量
  local ce_src = math.max(mk.ce - removed, cs_src)
  local lsc = seg.lstart + (cs_src - seg.strip_lead)
  local lec = seg.lstart + (ce_src - seg.strip_lead)
  if lsc < seg.lstart then lsc = seg.lstart end
  if lec > seg.lend then lec = seg.lend end
  if lsc < seg.lend and (lec > lsc or mk.add > 0) then
    return { sc = lsc, ce = math.max(lec, lsc), add = mk.add }
  end
  return nil
end

--- 处理一个 wrap 块，返回新的行列表。
---@param b mdwrap.Block
---@param opts mdwrap.Config
---@param width integer
---@param conceal boolean
---@param ctx table?  -- { bufnr, read_extmark, expected_lines }
---@return string[]
local function process_wrap(b, opts, width, conceal, ctx)
  local width_fn = vim.fn.strdisplaywidth
  local marks = gather_marks(b, ctx)
  -- 各行被剥掉的前缀串（#prefix = 回推 buffer 列的字节数；其文本量前缀区隐藏宽）。
  local prefix_of = function(k) return (b.content_prefix and b.content_prefix[k]) or "" end
  local removed_of = function(k) return #prefix_of(k) end

  if opts.keep_origin_wrap then
    -- 保留原换行：逐行 atomize + spacing，仅清行尾空白。extmark 按**该行**内容坐标翻译。
    local out = {}
    for idx, line in ipairs(b.content_lines) do
      local removed = removed_of(idx)
      local seg = { lstart = 0, lend = #line, strip_lead = 0 } -- 不合并：逻辑串即该行
      ---@type mdwrap.ExtmarkConceal[]
      local ex = {}
      for _, mk in ipairs(marks) do
        if mk.row - b.srow + 1 == idx then
          local e = body_mark_ex(mk, removed, seg)
          if e then ex[#ex + 1] = e end
        end
      end
      local as = atoms.atomize(line, { width_fn = width_fn, conceal = conceal, extmark_conceal = ex })
      if opts.cjk_english_spacing then as = spacing.apply(as) end
      local parts = {}
      for _, a in ipairs(as) do parts[#parts + 1] = a.text end
      local prefix = (idx == 1) and b.prefix_first or b.prefix_rest
      out[#out + 1] = (prefix .. table.concat(parts)):gsub("%s+$", "")
    end
    return out
  end

  -- 默认：合并逻辑行 → 原子化 → 盘古空格 → 折行。
  -- 每个 mark 按 buffer 列分流：
  --   正文区（cs ≥ removed_k）→ 按 segs 翻译到逻辑串坐标，作 ExtmarkConceal 喂 atomize。
  --     源行偏移 = buffer_col − removed_k；逻辑偏移 = seg.lstart + (源行偏移 − seg.strip_lead)。
  --   前缀区（cs < removed_k）→ 计入该行**前缀净增量** Σadd − Σhidden(前缀字符串切片量)，
  --     换算成 prefix_first_width / prefix_rest_width 覆盖 wrap 的 avail（输出仍是字面前缀）。
  local logical, segs = layout.merge_lines_mapped(b.content_lines)
  ---@type mdwrap.ExtmarkConceal[]
  local ex = {}
  local pdelta = {} -- k -> 该行前缀净增量
  for _, mk in ipairs(marks) do
    local k = mk.row - b.srow + 1
    local removed = removed_of(k)
    if mk.cs < removed then
      -- 前缀区：隐藏宽用该行**真实剥掉的前缀串**切片量（对嵌套/混合前缀也按构造正确）。
      local prefix_text = prefix_of(k)
      local he = math.min(mk.ce, removed)
      local hid = (he > mk.cs) and width_fn(prefix_text:sub(mk.cs + 1, he)) or 0
      pdelta[k] = (pdelta[k] or 0) + mk.add - hid
    else
      local seg = segs[k]
      if seg and not seg.empty then
        local e = body_mark_ex(mk, removed, seg)
        if e then ex[#ex + 1] = e end
      end
    end
  end
  local as = atoms.atomize(logical, { width_fn = width_fn, conceal = conceal, extmark_conceal = ex })
  if opts.cjk_english_spacing then as = spacing.apply(as) end

  ---@type mdwrap.LayoutOpts
  local lopts = {
    width = width,
    prefix_first = b.prefix_first,
    prefix_rest = b.prefix_rest,
    wrap_sentence = opts.wrap_sentence,
    cjk_break_at_punct_only = opts.cjk_break_at_punct_only,
    bracket_as_unit = opts.bracket_as_unit,
    width_fn = width_fn,
  }
  -- 前缀渲染占宽 = 字面宽 + 净增量。首行取 k==1；续行取首个有前缀 mark 的续行（渲染一致，互为代表）。
  if pdelta[1] then lopts.prefix_first_width = width_fn(b.prefix_first or "") + pdelta[1] end
  for k = 2, #b.content_lines do
    if pdelta[k] then
      lopts.prefix_rest_width = width_fn(b.prefix_rest or "") + pdelta[k]
      break
    end
  end
  return layout.wrap(as, lopts)
end

--- 自底向上对落在范围内的 wrap 块做替换；`replace(srow, erow, new_lines)`（0-indexed 闭区间）
--- 由调用方提供——buffer 版用 nvim_buf_set_lines，lines 版改数组。自底向上避免行号漂移。
---@param bs mdwrap.Block[]
---@param opts mdwrap.FormatOpts
---@param width integer
---@param conceal boolean
---@param ctx table?  -- { bufnr, read_extmark, expected_lines }
---@param replace fun(srow: integer, erow: integer, new_lines: string[])
local function apply_blocks(bs, opts, width, conceal, ctx, replace)
  local rs, re = opts.row_start, opts.row_end
  for i = #bs, 1, -1 do
    local b = bs[i]
    local in_range = (not rs) or (b.srow <= (re or rs) and b.erow >= rs)
    if b.action == "wrap" and in_range then
      replace(b.srow, b.erow, process_wrap(b, opts, width, conceal, ctx))
    end
  end
end

--- 把 conform.Range（(1,0) 索引，row 1-indexed 闭区间）换算为 mdwrap 的 0-indexed
--- row_start/row_end，写入 opts（已显式给 row_start 时不覆盖）。
local function range_to_rows(opts)
  local r = opts.range
  if r and opts.row_start == nil then
    opts.row_start = r.start[1] - 1
    opts.row_end = r["end"][1] - 1
  end
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
  -- buffer 路径：buffer 即真相源，extmark 坐标与 buffer 行一致，无需失同步保护。
  local ctx = { bufnr = bufnr, read_extmark = conceal and (opts.respect_extmark_conceal ~= false) }
  apply_blocks(bs, opts, width, conceal, ctx, function(srow, erow, new)
    vim.api.nvim_buf_set_lines(bufnr, srow, erow + 1, false, new)
  end)
end

--- lines 进／出格式化（conform.nvim Lua-formatter 等编排器的入口）。
--- 从内存 lines（而非 bufnr 的 tree-sitter 树）解析，故链式调用中前序 formatter 改过文本也正确。
---@param lines string[]
---@param opts mdwrap.FormatOpts? 可含 bufnr（仅取环境量）、range（conform.Range）或 row_start/row_end
---@return string[] new_lines
function M.format_lines(lines, opts)
  opts = vim.tbl_extend("force", M.options, opts or {})
  range_to_rows(opts)
  local bufnr = opts.bufnr            -- 仅用于取窗口 conceallevel / textwidth，不从中解析文本
  local out = vim.list_extend({}, lines)  -- 浅拷贝，按块就地替换
  local bs = blocks.split_lines(lines)
  local width = resolve_width(opts, bufnr)
  local conceal = conceal_enabled(opts, bufnr)
  -- lines 路径（conform 链式）：从内存 lines 解析，但 extmark 在 live buffer 上。
  -- 仅当有 bufnr 时读 extmark，并传 lines 作失同步保护（前序 formatter 改过的行丢弃其 mark）。
  local ctx = {
    bufnr = bufnr,
    read_extmark = conceal and (opts.respect_extmark_conceal ~= false) and bufnr ~= nil,
    expected_lines = lines,
  }
  apply_blocks(bs, opts, width, conceal, ctx, function(srow, erow, new)
    for _ = srow, erow do table.remove(out, srow + 1) end  -- 删 out[srow+1 .. erow+1]
    for j = #new, 1, -1 do table.insert(out, srow + 1, new[j]) end
  end)
  return out
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
