-- ignore.lua — 手动关闭折行的标记机制（mdwrap-ignore 系，纯模块）
--
-- 状态：实现。**禁止 require vim**，须在裸 luajit / lua5.1 下加载（与 layout / spacing /
-- chardata / table_align 同级）。验证：
--   luajit -e "package.path='./lua/?.lua;'..package.path; require('mdwrap.ignore')"
--
-- ============================================================================
-- 机制：先扫标记（scan）得出忽略意图，再把与之相交的块改成 preserve（行级则拆块）
-- （apply）。apply_blocks 只处理 wrap / table，preserve 自动跳过——故无需改动下游。
--
-- 四级粒度（载体均为独占一行的 HTML 注释；大小写不敏感、内部空白宽松）：
--   <!-- mdwrap-ignore-file -->  或 frontmatter 顶层 `mdwrap: false`  → 整文件跳过
--   <!-- mdwrap-ignore-start --> … <!-- mdwrap-ignore-end -->         → 区间内块跳过
--   <!-- mdwrap-ignore -->                                            → 其后第一个 wrap/table 块跳过
--   <!-- mdwrap-ignore-line -->                                       → 其下一源行跳过（段内则拆段）
--
-- 实测依据（见 blocks.lua 与设计文档）：标记注释与紧贴的段落即使无空行，仍是独立
-- html_block（preserve）；故 `-line` 标记后所在段的「被保护行」恒为其块首行，三段拆分的
-- 「前段」实际为空，但 apply 仍按通用三段写。
-- ============================================================================

local M = {}

-- 整行匹配单条标记注释，捕获 ignore 之后的后缀分类：
--   ""→块、"-line"、"-start"、"-end"、"-file"（其余后缀视为未知，忽略）。
-- 匹配前先把行整体小写化以实现大小写不敏感（注释内容纯 ASCII，小写化无副作用）。
local MARKER = "^%s*<!%-%-%s*mdwrap%-ignore([%w%-]*)%s*%-%->%s*$"

--- 扫描全文，得出忽略意图。坐标一律 0-indexed。
---@param lines string[]
---@return mdwrap.Ignore
function M.scan(lines)
  ---@type mdwrap.Ignore
  local ig = { file = false, ranges = {}, block_lnums = {}, line_lnums = {} }
  local pending_start = nil -- 尚未配对的 -start 行号
  -- frontmatter：仅当首行恰为 `---` 时成立，至下一 `---` / `...` 止。
  local in_fm = (lines[1] ~= nil) and lines[1]:match("^%-%-%-%s*$") ~= nil

  for i = 1, #lines do
    local lnum = i - 1
    local raw = lines[i]

    -- frontmatter 区间内匹配顶层 `mdwrap: false`（false 大小写不敏感；行首无缩进 ⇒ 顶层键）。
    if in_fm then
      if i > 1 and (raw:match("^%-%-%-%s*$") or raw:match("^%.%.%.%s*$")) then
        in_fm = false
      elseif raw:lower():match("^mdwrap%s*:%s*false%s*$") then
        ig.file = true
      end
    end

    -- 标记注释（小写化后整行匹配）。
    local suffix = raw:lower():match(MARKER)
    if suffix then
      if suffix == "" then
        ig.block_lnums[#ig.block_lnums + 1] = lnum
      elseif suffix == "-line" then
        ig.line_lnums[#ig.line_lnums + 1] = lnum
      elseif suffix == "-file" then
        ig.file = true
      elseif suffix == "-start" then
        if not pending_start then pending_start = lnum end
      elseif suffix == "-end" then
        if pending_start then
          ig.ranges[#ig.ranges + 1] = { pending_start, lnum }
          pending_start = nil
        end
        -- 未配对的 -end：忽略（无害）。
      end
      -- 未知后缀：忽略。
    end
  end

  -- 未配对的 -start：延伸到 EOF。
  if pending_start then
    ig.ranges[#ig.ranges + 1] = { pending_start, #lines - 1 }
  end

  return ig
end

--- 把一个多行 wrap 块按「受保护源行」拆成：连续非保护行的子 wrap 块 + 各受保护行的单行
--- preserve 块，按源行顺序追加到 out。续段子块的 prefix_first 取原块 prefix_rest（悬挂缩进
--- 语义保持）。单行 wrap 块整行受保护时自然退化为一个 preserve 块。
---@param b mdwrap.Block
---@param protected table<integer, boolean>  -- 受保护源行集合（0-indexed）
---@param out mdwrap.Block[]
local function split_wrap(b, protected, out)
  local srow = b.srow
  local cl = b.content_lines or {}
  local cp = b.content_prefix or {}
  local run_start = nil -- 当前连续非保护段的起始源行

  local function flush(run_end)
    if not run_start then return end
    local sub_cl, sub_cp = {}, {}
    for r = run_start, run_end do
      local k = r - srow + 1
      sub_cl[#sub_cl + 1] = cl[k]
      sub_cp[#sub_cp + 1] = cp[k] or ""
    end
    -- 起始即原块首行 ⇒ 沿用 prefix_first；否则为续段 ⇒ 用 prefix_rest 作首行前缀（悬挂缩进）。
    local pf = (run_start == srow) and b.prefix_first or b.prefix_rest
    out[#out + 1] = {
      action = "wrap",
      srow = run_start,
      erow = run_end,
      prefix_first = pf,
      prefix_rest = b.prefix_rest,
      content_lines = sub_cl,
      content_prefix = sub_cp,
    }
    run_start = nil
  end

  for r = srow, b.erow do
    if protected[r] then
      flush(r - 1)
      out[#out + 1] = { action = "preserve", srow = r, erow = r }
    else
      run_start = run_start or r
    end
  end
  flush(b.erow)
end

--- 依扫描结果把受影响的块改成 preserve（行级则拆块），返回新块列表。
--- 纯函数：blocks 是普通表（带 srow/erow/content_lines/content_prefix/prefix_*），无 TSNode、无 vim。
---@param blocks mdwrap.Block[]
---@param scan mdwrap.Ignore
---@param nlines integer  -- 文件总行数（保留参数；EOF 已在 scan 内并入 ranges）
---@return mdwrap.Block[]
function M.apply(blocks, scan, nlines) -- luacheck: ignore 212
  -- 文件级：所有块翻 preserve，直接返回。
  if scan.file then
    for _, b in ipairs(blocks) do b.action = "preserve" end
    return blocks
  end

  -- 区域级：与任一区间相交的块翻 preserve。
  if #scan.ranges > 0 then
    for _, b in ipairs(blocks) do
      if b.action ~= "preserve" then
        for _, r in ipairs(scan.ranges) do
          if b.srow <= r[2] and b.erow >= r[1] then
            b.action = "preserve"
            break
          end
        end
      end
    end
  end

  -- 块级：每个标记 m 把「srow > m 的第一个 wrap/table 块」翻 preserve。
  for _, m in ipairs(scan.block_lnums) do
    local best = nil
    for _, b in ipairs(blocks) do
      if (b.action == "wrap" or b.action == "table") and b.srow > m then
        if not best or b.srow < best.srow then best = b end
      end
    end
    if best then best.action = "preserve" end
  end

  -- 行级：受保护源行 L = m + 1。无行级标记时直接返回（避免无谓重建数组）。
  if #scan.line_lnums == 0 then return blocks end
  local protected = {}
  for _, m in ipairs(scan.line_lnums) do protected[m + 1] = true end

  local out = {}
  for _, b in ipairs(blocks) do
    local has = false
    for r = b.srow, b.erow do
      if protected[r] then has = true; break end
    end
    if not has then
      out[#out + 1] = b
    elseif b.action == "wrap" and b.erow > b.srow then
      -- 多行 wrap 块：拆块。
      split_wrap(b, protected, out)
    else
      -- 单行块 / 非 wrap 块 / table 块：整块 preserve（表格不在内部拆）。
      b.action = "preserve"
      out[#out + 1] = b
    end
  end
  return out
end

return M
