-- blocks.lua — tree-sitter 块级切分与前缀计算
--
-- 状态：M2 实现。依赖 vim.*（tree-sitter / buffer API）。
--
-- ============================================================================
-- 本地实验实测结果（nvim 0.12.3，内置 markdown / markdown_inline parser）
-- 实验方法：headless 加载样本，遍历 parser:trees() 与注入子树打印 node:type()
-- 与 range。以下为「实测为准」的事实，凡与设计文档第 4 节预期值不符者，以此为准。
-- ============================================================================
--
-- 块级（language = 'markdown'）：
--   document
--     minus_metadata            -- YAML 头（--- ... ---），整体 preserve
--     section                   -- 标题及其辖下内容的包裹节点（非可格式化单位本身）
--       paragraph               -- 主要 wrap 对象；其下唯一具名子节点是 `inline`
--         inline                -- 行内内容，注入 markdown_inline 子树的锚点
--       block_quote             -- 引用块；可嵌套
--         block_quote_marker    -- "> " 前缀（仅出现在引用首行）
--         paragraph
--           inline
--           block_continuation  -- 续行的 "> " 前缀，**混在 paragraph/inline 内部**，
--                               --   atoms 化时必须剔除（实测：见 callout 与多行引用）
--         block_quote           -- 嵌套引用作为子节点逐层下沉
--       list
--         list_item
--           list_marker_minus / list_marker_dot   -- "- " / "1. "
--           task_list_marker_unchecked            -- "[ ]"（checked 为 _checked）
--           paragraph
--             inline
--       pipe_table              -- preserve；子节点 pipe_table_header /
--                               --   pipe_table_delimiter_row / pipe_table_row /
--                               --   pipe_table_cell / pipe_table_delimiter_cell
--       atx_heading             -- preserve；含 atx_h{1..6}_marker + inline
--       setext_heading          -- preserve；含 paragraph + setext_h{1,2}_underline
--       link_reference_definition  -- preserve；含 link_label + link_destination
--       html_block              -- preserve；HTML 注释 <!-- ... --> 落在此节点
--
-- 重要的「无独立节点」实测发现（必须按文本特征在块层处理）：
--   * 数学块 $$...$$  —— 无独立节点，被解析为普通 `paragraph`，其 inline 文本
--     以 "$$" 开头/结尾。按设计文档 4.1 预案：段落内容以 $$ 起止时整块 preserve。
--   * ::: 围栏 div    —— 完全不被识别。`::: {.callout-tip}` 连同其后内容直到 `:::`
--     被吞成**单个 paragraph**（inline 文本含换行）。必须在块层用 `^:::+` 正则
--     切分：围栏开/闭行各自 preserve，中间内容另立为独立 wrap 块。
--   * shortcode {{< ... >}} —— 不被解析为节点，作为普通文本，需补正则（见 atoms.lua）。
--
-- 节点名与设计文档第 4 节预期值的对照：
--   设计文档写 `fenced_code_block` —— 实测同名（样本未含围栏代码块，名称沿用社区标准）。
--   设计文档写「minus_metadata/plus_metadata」—— 实测 YAML 为 minus_metadata，确认。

local M = {}

-- 原样保留的叶块节点类型。
local PRESERVE_TYPES = {
  fenced_code_block = true,
  indented_code_block = true,
  minus_metadata = true,
  plus_metadata = true,
  pipe_table = true,
  atx_heading = true,
  setext_heading = true,
  link_reference_definition = true,
  html_block = true,
  thematic_break = true,
}

-- 结构 token：不是块、在块级遍历中跳过（标记由所属块的前缀逻辑处理）。
local IGNORE_TYPES = {
  list_marker_minus = true, list_marker_plus = true, list_marker_star = true,
  list_marker_dot = true, list_marker_parenthesis = true,
  task_list_marker_checked = true, task_list_marker_unchecked = true,
  block_quote_marker = true, block_continuation = true,
}

--- 节点占用的行范围（0-indexed，闭区间 [sr, er]）。
---@param node TSNode
---@return integer sr, integer er
local function rows_of(node)
  local sr, _, er, ec = node:range()
  if ec == 0 and er > sr then er = er - 1 end
  return sr, er
end

--- 子树内是否含 ERROR / 缺失节点（畸形）。
---@param node TSNode
---@return boolean
local function has_error(node)
  if node:type() == "ERROR" or node:missing() then return true end
  for child in node:iter_children() do
    if has_error(child) then return true end
  end
  return false
end

--- 计算 paragraph 的前缀（引用标记 + 列表标记）。
--- 返回 prefix_first（首行完整前缀）、prefix_rest（续行前缀：引用标记 + 列表标记等宽空格）。
---@param para TSNode
---@param get_line fun(r:integer):string
---@return string prefix_first, string prefix_rest, string quote_part
local function compute_prefix(para, get_line)
  local psr, psc = para:range()
  local first_line = get_line(psr)
  local prefix_first = first_line:sub(1, psc) -- 首行 inline 起点之前的全部
  -- 逐字符分离引用标记部分（前导的 `> ` 串）与其后的列表标记部分
  local quote_part
  do
    local qp, i = {}, 1
    while i <= #prefix_first do
      local c = prefix_first:sub(i, i)
      if c == ">" then
        qp[#qp + 1] = ">"
        i = i + 1
        if prefix_first:sub(i, i):match("%s") then qp[#qp + 1] = prefix_first:sub(i, i); i = i + 1 end
      elseif c:match("%s") and #qp > 0 then
        -- 引用标记间的空格已并入
        break
      else
        break
      end
    end
    quote_part = table.concat(qp)
  end
  local list_part = prefix_first:sub(#quote_part + 1)
  local prefix_rest = quote_part .. string.rep(" ", vim.fn.strdisplaywidth(list_part))
  return prefix_first, prefix_rest, quote_part
end

--- 去除某行的前缀，返回正文内容与**被剥掉的前缀字节数** removed。
--- removed 供 extmark buffer 列坐标回推：source_col = buffer_col − removed（见 init.process_wrap）。
--- 续行：剥去引用标记串；首行已知 prefix_first。
---@return string content, integer removed
local function strip_prefix(line, is_first, prefix_first, quote_part)
  if is_first then
    return line:sub(#prefix_first + 1), #prefix_first
  end
  -- 续行：剥去引用前缀（与 quote_part 等量的 `>%s?`）
  local s = line
  local qn = select(2, quote_part:gsub(">", ">"))
  local removed = 0
  for _ = 1, qn do
    local before = #s
    s = s:gsub("^>%s?", "", 1)
    removed = removed + (before - #s)
  end
  return s, removed
end

--- 判定一个顶层 paragraph 的特殊类型（数学块 / div 围栏 / shortcode）。
---@param lines string[]
---@return "math"|"divfence"|"shortcode"|nil
local function special_paragraph(lines)
  local first = lines[1] or ""
  if first:match("^%s*%$%$") then return "math" end
  for _, l in ipairs(lines) do
    if l:match("^%s*:::") then return "divfence" end
  end
  if #lines == 1 and first:match("^%s*{{<.->}}%s*$") then return "shortcode" end
  return nil
end

--- 处理一个 wrap 候选 paragraph，可能因特殊类型拆成多个块。
---@param para TSNode
---@param get_line fun(r:integer):string
---@param out mdwrap.Block[]
local function handle_paragraph(para, get_line, out)
  local psr, per = rows_of(para)
  local lines = {}
  for r = psr, per do lines[#lines + 1] = get_line(r) end

  -- 顶层 paragraph（无前缀）才检测 math/divfence/shortcode
  local _, psc = para:range()
  local top = (psc == 0) and (para:parent() == nil or para:parent():type() == "section"
    or para:parent():type() == "document")

  if top then
    local sp = special_paragraph(lines)
    if sp == "math" or sp == "shortcode" then
      out[#out + 1] = { action = "preserve", srow = psr, erow = per }
      return
    elseif sp == "divfence" then
      -- 逐行拆：::: 行 preserve，其余连续行作为 wrap 子块
      local r = psr
      local buf_wrap = nil
      -- 一趟构造：遇 ::: 行就收口当前 wrap 子块（连同 content_lines）并落一个 preserve 行。
      local function flush_wrap()
        if buf_wrap then
          local cl, pf = {}, {}
          for rr = buf_wrap, r - 1 do cl[#cl + 1] = get_line(rr); pf[#pf + 1] = "" end -- 无前缀
          out[#out + 1] = { action = "wrap", srow = buf_wrap, erow = r - 1,
            prefix_first = "", prefix_rest = "", content_lines = cl, content_prefix = pf }
          buf_wrap = nil
        end
      end
      while r <= per do
        if get_line(r):match("^%s*:::") then
          flush_wrap()
          out[#out + 1] = { action = "preserve", srow = r, erow = r }
        else
          buf_wrap = buf_wrap or r
        end
        r = r + 1
      end
      flush_wrap()
      return
    end
  end

  -- 普通 wrap paragraph（含引用 / 列表前缀）
  local prefix_first, prefix_rest, quote_part = compute_prefix(para, get_line)
  local content, prefixes = {}, {}
  for idx, l in ipairs(lines) do
    local rm
    content[idx], rm = strip_prefix(l, idx == 1, prefix_first, quote_part)
    prefixes[idx] = l:sub(1, rm) -- 实际剥掉的前缀串（量前缀区隐藏宽用）
  end
  out[#out + 1] = {
    action = "wrap",
    srow = psr, erow = per,
    prefix_first = prefix_first,
    prefix_rest = prefix_rest,
    content_lines = content,
    content_prefix = prefixes,
  }
end

--- 处理 block_quote：识别 callout 标题行，递归处理内部块。
---@param bq TSNode
---@param get_line fun(r:integer):string
---@param out mdwrap.Block[]
local function handle_block_quote(bq, get_line, out)
  -- callout：引用内首个 paragraph 的首行匹配 [!NAME]
  for child in bq:iter_children() do
    local t = child:type()
    if child:named() then
      if t == "paragraph" then
        local psr = rows_of(child)
        local first = get_line(psr)
        if first:match("^%s*>?%s*%[!") then
          -- callout 标题行独立 preserve，正文从下一行起
          out[#out + 1] = { action = "preserve", srow = psr, erow = psr }
          -- 其余行作为 wrap（带 > 前缀）
          local _, per = rows_of(child)
          if per > psr then
            local _, _, quote_part = compute_prefix(child, get_line)
            -- callout 正文沿用引用前缀（quote_part，如 "> "）
            local bf = quote_part
            local content, prefixes = {}, {}
            for r = psr + 1, per do
              local line = get_line(r)
              local c, rm = strip_prefix(line, false, bf, quote_part)
              content[#content + 1] = c
              prefixes[#prefixes + 1] = line:sub(1, rm)
            end
            out[#out + 1] = { action = "wrap", srow = psr + 1, erow = per,
              prefix_first = bf, prefix_rest = bf, content_lines = content, content_prefix = prefixes }
          end
        else
          handle_paragraph(child, get_line, out)
        end
      elseif t == "block_quote" then
        handle_block_quote(child, get_line, out)
      end
    end
  end
end

--- 递归遍历，产出块列表。
---@param node TSNode
---@param get_line fun(r:integer):string
---@param out mdwrap.Block[]
local function walk(node, get_line, out)
  for child in node:iter_children() do
    if child:named() then
      local t = child:type()
      if PRESERVE_TYPES[t] then
        local sr, er = rows_of(child)
        out[#out + 1] = { action = "preserve", srow = sr, erow = er }
      elseif t == "paragraph" then
        if has_error(child) then
          local sr, er = rows_of(child)
          out[#out + 1] = { action = "preserve", srow = sr, erow = er }
        else
          handle_paragraph(child, get_line, out)
        end
      elseif t == "block_quote" then
        handle_block_quote(child, get_line, out)
      elseif t == "list" or t == "list_item" or t == "section" or t == "document" then
        walk(child, get_line, out)
      elseif IGNORE_TYPES[t] then
        -- 结构 token：跳过
      elseif t == "ERROR" then
        local sr, er = rows_of(child)
        out[#out + 1] = { action = "preserve", srow = sr, erow = er }
      else
        -- 其余未知块：保守 preserve
        local sr, er = rows_of(child)
        out[#out + 1] = { action = "preserve", srow = sr, erow = er }
      end
    end
  end
end

--- 共享核心：给定语法树根与按行取文本的闭包，产出排序后的块列表。
---@param root TSNode
---@param get_line fun(r: integer): string  -- r 为 0-indexed 行号
---@return mdwrap.Block[]
local function split_core(root, get_line)
  ---@type mdwrap.Block[]
  local out = {}
  walk(root, get_line, out)
  table.sort(out, function(a, b) return a.srow < b.srow end)
  return out
end

--- 从 buffer 解析并切块（formatexpr / :MdwrapFormat / format_buffer 用）。
---@param bufnr integer
---@return mdwrap.Block[]
function M.split(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, "markdown")
  ---@diagnostic disable-next-line: need-check-nil  -- 已加载的 parser，其 parse() 必产出至少一棵树
  local root = parser:parse(true)[1]:root()
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local function get_line(r)
    return all_lines[r + 1] or ""
  end
  return split_core(root, get_line)
end

--- 从内存 lines 解析并切块（conform 链式集成用：不依赖 buffer 树，避免前序 formatter
--- 改过文本后 buffer 树相对 lines 失同步）。
---@param lines string[]
---@return mdwrap.Block[]
function M.split_lines(lines)
  local parser = vim.treesitter.get_string_parser(table.concat(lines, "\n"), "markdown")
  ---@diagnostic disable-next-line: need-check-nil  -- 已加载的 parser，其 parse() 必产出至少一棵树
  local root = parser:parse(true)[1]:root()
  local function get_line(r)
    return lines[r + 1] or ""
  end
  return split_core(root, get_line)
end

return M
