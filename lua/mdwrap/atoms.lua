-- atoms.lua — 行内树 → 原子列表；conceal 宽度计算
--
-- 状态：M2 实现。本文件需要 vim.*（tree-sitter / strdisplaywidth），不在纯 Lua
-- 硬约束之列；纯函数部分（字符分类）复用 chardata.lua。
--
-- ============================================================================
-- 本地实验实测结果（language = 'markdown_inline'）
-- ============================================================================
--
-- 行内（注入子树 lang = 'markdown_inline'）：
--   inline
--     strong_emphasis / emphasis   -- **粗体** / *斜体*
--       emphasis_delimiter         -- 每个 "*" 是独立节点（** 产出两个）；全部 conceal 计 0 宽
--                                  --   强调**不是**原子，内部可断行（设计文档 4.2.3 第 6 条）
--     code_span                    -- `code`；含 code_span_delimiter（两个反引号各一节点）
--                                  --   v2 收紧为不可断 atomic 原子
--     latex_block                  -- 行内数学 $...$（实测节点名是 latex_block，非设计文档
--                                  --   预想的 latex_span）；含 latex_span_delimiter。
--                                  --   整体 atomic 原子；$ 定界符是否扣宽**不再内建**，
--                                  --   交由 opts.extmark_conceal（render-markdown 等渲染插件
--                                  --   注入的持久 conceal extmark）统一决定。见 DECISIONS #4。
--     inline_link                  -- [text](url)；含 link_text + link_destination
--     shortcut_link                -- 一词多义，实测三种结构都落到此节点：
--                                  --   1) citation  [@smith2020] —— link_text "@smith2020"
--                                  --   2) callout   [!note]       —— link_text "!note"
--                                  --   3) wiki      [[t|d]]       —— 内层 [t|d] 为 shortcut_link，
--                                  --      外层多出的 [ ] 留作字面文本（实测）
--
-- 「不被解析、需补正则」的不可断结构（实测无对应节点）：
--   * 裸 citation  @key2020         -- 正则见设计文档 4.2.3 第 3 条
--   * shortcode    {{< ... >}}      -- 正则 %{%{< ... >%}%}
--   * 行内数学在某些写法下若无 latex_block 亦需补正则（要求 $ 紧贴非空白）
--
-- conceal 宽度的权威来源（设计文档 4.2.1）：不要手写「藏了什么」清单。
-- 两个真相源：① markdown_inline 的 highlights 查询里带 conceal 元数据的捕获区间
-- （**/反引号 等，headless 基线）；② 渲染插件（render-markdown/markview）注入的**持久
-- conceal/inline-virt_text extmark**，由上游 conceal.lua 读出、翻译成逻辑串坐标后经
-- opts.extmark_conceal 传入。两源对同段重叠时按字节并集去重；宽度模型 = 自然宽 − 隐藏 + 加宽。
--
-- block_continuation 处理：引用块续行的 "> " 以 block_continuation 节点混入 inline，
-- 原子化前必须按节点类型剔除，不计入正文宽度（前缀由 blocks.lua 单独计算）。
--
-- 零宽空格（U+200B）实测坑：strdisplaywidth('\u{200b}') == 6（nvim 把不可打印字符
--   渲染为 <200b> 转义占位，计 6 列），而非 0。因此 ZWSP 必须在本层特判为
--   width=0 的特殊原子，**不得**经生产 width_fn(strdisplaywidth) 度量，否则布局错乱。
--   ZWSP 是最高优先级断点原子。**用户裁定（偏离设计文档 4.2.4）**：断行处的 ZWSP
--   像空格一样被消费、**不在输出中保留**（golden 23 据此构造）。

local chardata = require("mdwrap.chardata")

local M = {}

-- 整体不可断的行内结构节点类型（markdown_inline）。
local ATOMIC_TYPES = {
  code_span = true,
  latex_block = true,
  inline_link = true,
  full_reference_link = true,
  collapsed_reference_link = true,
  shortcut_link = true,
  image = true,
  uri_autolink = true,
  email_autolink = true,
}

-- bare citation key 的字符集（Pandoc，设计文档 4.2.3）。
local CITE_PAT = "^@[%w_][%w_:%-%.#%$%%&+%?<>~/]*"

-- UTF-8 工具取自纯模块 chardata，避免与 layout.lua 重复实现解码器。
local cp = chardata.utf8_cp
local char_len = chardata.utf8_char_len

--- 收集 atomic 节点的字节区间（0-indexed col，单逻辑行）。
local function collect_atomic(node, spans)
  for child in node:iter_children() do
    if child:named() then
      if ATOMIC_TYPES[child:type()] then
        local _, sc, _, ec = child:range()
        spans[#spans + 1] = { sc = sc, ec = ec, ty = child:type() }
      else
        collect_atomic(child, spans) -- 递归找嵌套 atomic（如 **`code`**）
      end
    end
  end
end

--- 收集 tree-sitter conceal 字节区间（markdown_inline 的 highlights 查询）。
--- `$` 等渲染插件特有的 conceal 不在此处（它们是 decoration provider 查不到的临时标记，
--- 或由 render-markdown/markview 以**持久 extmark** 注入），统一经 opts.extmark_conceal 进入。
local function collect_conceal(root, str)
  local ranges = {}
  local q = vim.treesitter.query.get("markdown_inline", "highlights")
  if q then
    for id, node, md in q:iter_captures(root, str, 0, -1) do
      local c = md.conceal
      if c == nil and md[id] then c = md[id].conceal end
      if c ~= nil then
        local _, sc, _, ec = node:range()
        ranges[#ranges + 1] = { sc = sc, ec = ec }
      end
    end
  end
  return ranges
end

--- 把若干（可能重叠的）隐藏区间合并成排序后的**不相交**区间集。
--- 两个 conceal 源（tree-sitter 查询 + 持久 extmark）对同一段 `**` 各标一次时，
--- 并集只算一次——去重内建于此，宽度模型不会重复扣减。
---@param ranges {sc:integer, ec:integer}[]
---@return {sc:integer, ec:integer}[]
local function merge_ranges(ranges)
  if #ranges == 0 then return {} end
  local r = {}
  for _, x in ipairs(ranges) do r[#r + 1] = { sc = x.sc, ec = x.ec } end
  table.sort(r, function(a, b) return a.sc < b.sc or (a.sc == b.sc and a.ec < b.ec) end)
  local out = { { sc = r[1].sc, ec = r[1].ec } }
  for i = 2, #r do
    local cur = out[#out]
    if r[i].sc <= cur.ec then
      if r[i].ec > cur.ec then cur.ec = r[i].ec end
    else
      out[#out + 1] = { sc = r[i].sc, ec = r[i].ec }
    end
  end
  return out
end

--- 某字节位置是否落在任一隐藏区间内。
local function byte_concealed(ranges, b)
  for _, r in ipairs(ranges) do
    if b >= r.sc and b < r.ec then return true end
  end
  return false
end

--- [sc,ec) 内的 inline virt_text / conceal 替换字符附加宽之和（锚点 at 落在区间内即计入）。
---@param adds {at:integer, w:integer}[]
local function add_in(adds, sc, ec)
  local s = 0
  for _, p in ipairs(adds) do
    if p.at >= sc and p.at < ec then s = s + p.w end
  end
  return s
end

--- 计算 [sc,ec) 子串的视觉宽度 = 总宽 − 隐藏段宽(并集去重) + 附加宽。
--- hidden 须为 merge_ranges 产出的不相交区间集（否则重叠段会被重复扣）。
local function visual_width(str, sc, ec, hidden, adds, width_fn)
  local total = width_fn(str:sub(sc + 1, ec))
  local hid = 0
  for _, r in ipairs(hidden) do
    local a, b = math.max(sc, r.sc), math.min(ec, r.ec)
    if a < b then hid = hid + width_fn(str:sub(a + 1, b)) end
  end
  local w = total - hid + add_in(adds, sc, ec)
  return w < 0 and 0 or w
end

--- 把一条逻辑行字符串原子化。
---@param str string 单逻辑行（无换行）
---@param opts mdwrap.AtomizeOpts?
---@return mdwrap.Atom[] atoms
function M.atomize(str, opts)
  opts = opts or {}
  local width_fn = opts.width_fn or vim.fn.strdisplaywidth
  local conceal_on = opts.conceal ~= false

  local parser = vim.treesitter.get_string_parser(str, "markdown_inline")
  local trees = parser:parse(true)
  ---@diagnostic disable-next-line: need-check-nil  -- 已加载的 parser，其 parse() 必产出至少一棵树
  local root = trees[1]:root()

  local atomic = {}
  collect_atomic(root, atomic)
  table.sort(atomic, function(a, b) return a.sc < b.sc end)
  -- atomic 起点 → span 映射
  local atomic_at = {}
  for _, s in ipairs(atomic) do atomic_at[s.sc] = s end

  -- 两个 conceal 源合一：tree-sitter 查询（**/反引号 等）+ 持久 extmark（链接 url、$、
  -- render-markdown/markview 自盖的 ** 等）。隐藏区间取并集去重，加宽锚点单列。
  local hide_src = conceal_on and collect_conceal(root, str) or {}
  local adds = {} -- {at=逻辑字节偏移, w=附加视觉宽}
  if opts.extmark_conceal then
    for _, e in ipairs(opts.extmark_conceal) do
      if e.ce > e.sc then hide_src[#hide_src + 1] = { sc = e.sc, ec = e.ce } end
      if e.add and e.add > 0 then adds[#adds + 1] = { at = e.sc, w = e.add } end
    end
  end
  local hidden = merge_ranges(hide_src)

  ---@type mdwrap.Atom[]
  local atoms = {}
  local pending = ""      -- 待并入下一可见原子的 conceal 标记文本
  local word = nil        -- 累积中的 word 原子文本
  local word_start = 0    -- 当前 word 的起始字节（add 锚点归属判定用）
  local word_end = 0      -- 当前 word 的结束字节（不含）

  local function flush_word()
    if word then
      atoms[#atoms + 1] = { text = pending .. word, width = width_fn(word) + add_in(adds, word_start, word_end), class = "word" }
      pending = ""
      word = nil
    end
  end
  local function emit(text, width, class, kind)
    flush_word()
    atoms[#atoms + 1] = { text = pending .. text, width = width, class = class, atomic_kind = kind }
    pending = ""
  end

  -- atomic 节点类型 → 子类（spacing 用：仅 code 享受盘古空格）
  local function kind_of(ty)
    if ty == "code_span" then return "code" end
    if ty == "latex_block" then return "math" end
    return "link"
  end

  local n = #str
  local b = 0 -- 0-indexed 字节位置
  while b < n do
    -- 1) atomic 结构
    local span = atomic_at[b]
    if span then
      emit(str:sub(span.sc + 1, span.ec), visual_width(str, span.sc, span.ec, hidden, adds, width_fn),
        "atomic", kind_of(span.ty))
      b = span.ec
    else
      local b1 = str:byte(b + 1)
      local clen = char_len(b1)
      local ch = str:sub(b + 1, b + clen)
      local u = cp(ch)
      if u == 0x200B then
        flush_word()
        atoms[#atoms + 1] = { text = pending .. ch, width = 0, class = "zwsp" }
        pending = ""
        b = b + clen
      elseif byte_concealed(hidden, b) then
        -- 隐藏标记：并入 pending（0 宽），随后并入下一可见原子文本
        pending = pending .. ch
        b = b + clen
      else
        -- 普通文本：先试 shortcode / bare citation 正则（plain 区域）
        local rest = str:sub(b + 1)
        local sc_s, sc_e = rest:find("^{{<.-}}")
        if not sc_s then sc_s, sc_e = rest:find("^{{%%.-%%}}") end
        local cite_s, cite_e = rest:find(CITE_PAT)
        if sc_s then
          local t = rest:sub(sc_s, sc_e)
          emit(t, width_fn(t), "atomic", "shortcode")
          b = b + #t
        elseif cite_s then
          local t = rest:sub(cite_s, cite_e)
          emit(t, width_fn(t), "atomic", "cite")
          b = b + #t
        elseif ch == " " or ch == "\t" then
          flush_word()
          atoms[#atoms + 1] = { text = ch, width = 1, class = "space" }
          b = b + clen
        else
          local attr = chardata.char_attr(u or 0)
          -- 单字符原子（CJK/全角标点）：若有 inline 图标锚定在该字符区间内，并入其宽。
          local cw = width_fn(ch) + add_in(adds, b, b + clen)
          if attr == "CJK" or attr == "CJK_PUN" then
            emit(ch, cw, "cjk")
          elseif attr == "PUN_FORBIT_BREAK_BEFORE" then
            emit(ch, cw, "punct_no_break_before")
          elseif attr == "PUN_FORBIT_BREAK_AFTER" then
            emit(ch, cw, "punct_no_break_after")
          else
            -- OTHER：累积为 word（记录起止字节，flush 时按区间归并 add）
            if not word then word_start = b end
            word = (word or "") .. ch
            word_end = b + clen
          end
          b = b + clen
        end
      end
    end
  end
  flush_word()
  -- 收尾 pending（行末隐藏标记）并入最后一个原子文本
  if pending ~= "" then
    if #atoms > 0 then
      atoms[#atoms].text = atoms[#atoms].text .. pending
    else
      atoms[#atoms + 1] = { text = pending, width = 0, class = "word" }
    end
  end
  return atoms
end

return M
