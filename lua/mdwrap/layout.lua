-- layout.lua — 断行核心（纯函数）
--
-- 硬约束：本文件禁止 require 任何 vim.* 模块，必须能在 luajit / lua5.1 下独立加载。
-- 仅依赖纯 Lua 模块 mdwrap.chardata（同样无 vim 依赖）。
-- 设计依据：mdwrap-nvim-design.md 第 4.3 节；用户裁定见 tests/golden/DECISIONS.md。
--
-- 公开 API：
--   M.wrap(atoms, opts)   -> string[]   贪心折行（禁则 / 句末偏好 / 溢出 / ZWSP）
--   M.merge_lines(lines)  -> string     重折前的逻辑行合并（update_when_new_line 规则）
--   M.cleanup(lines)      -> string[]   行尾空白清理 + 三连以上空行压缩为两个
--
-- 原子（atom）模型：{ text=string, width=integer, class=string, break_before=boolean? }
--   class ∈ cjk | word | space | zwsp | atomic
--                | punct_no_break_before | punct_no_break_after
--   width 为视觉宽度（CJK 计 2 等），由上游 atoms.lua 用注入的 width_fn 预先算好；
--   本层只对前缀字符串调用 opts.width_fn 来量宽（前缀通常是 ASCII）。

local chardata = require("mdwrap.chardata")

local M = {}

-- ----------------------------------------------------------------------------
-- UTF-8 工具（取自纯模块 chardata，避免与 atoms.lua 重复实现解码器）
-- ----------------------------------------------------------------------------

local utf8_cp = chardata.utf8_cp

--- 取字符串首个 UTF-8 字符。
local function first_char(s)
  if s == nil or s == "" then return "" end
  return s:sub(1, chardata.utf8_char_len(s:byte(1)))
end

--- 取字符串末个 UTF-8 字符。
local function last_char(s)
  if s == nil or s == "" then return "" end
  local i = #s
  while i > 1 do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then break end -- 非续接字节即字符首字节
    i = i - 1
  end
  return s:sub(i)
end

M._utf8_cp = utf8_cp
M._first_char = first_char
M._last_char = last_char

-- ----------------------------------------------------------------------------
-- 断行机会判定（4.3.1）
-- ----------------------------------------------------------------------------

--- 该原子之后是否允许断行（其末字符不属于禁后断标点）。
local function can_break_after(atom)
  if atom.class == "punct_no_break_after" then return false end
  local ch = last_char(atom.text)
  if chardata.half_break_after[ch] then return false end
  local cp = utf8_cp(ch)
  if cp and chardata.forbit_break_after[cp] then return false end
  return true
end

--- 该原子之前是否允许断行（其首字符不属于禁前断标点）。
local function can_break_before(atom)
  if atom.class == "punct_no_break_before" then return false end
  local ch = first_char(atom.text)
  if chardata.half_break_before[ch] then return false end
  local cp = utf8_cp(ch)
  if cp and chardata.forbit_break_before[cp] then return false end
  return true
end

-- ----------------------------------------------------------------------------
-- 行合并（4.3.3）：update_when_new_line 规则
-- ----------------------------------------------------------------------------

--- 判断某字符是否「宽字符」（CJK 表意文字或全角标点）。
local function is_wide(cp)
  if not cp then return false end
  local attr = chardata.char_attr(cp)
  return attr == "CJK" or attr == "CJK_PUN"
    or attr == "PUN_FORBIT_BREAK_BEFORE" or attr == "PUN_FORBIT_BREAK_AFTER"
end

--- 判断某字符分类是否属于标点类（PUN_* / CJK_PUN）。
local function is_punct_attr(attr)
  return attr == "CJK_PUN"
    or attr == "PUN_FORBIT_BREAK_BEFORE"
    or attr == "PUN_FORBIT_BREAK_AFTER"
end

--- 把多行（块内原有软换行）合并为一条逻辑长行，并产出**段映射**。
--- 换行两侧：右首为宽字符且左末为空/空白/非 OTHER ⇒ 无空格拼接；
--- 左末为标点类 ⇒ 无空格拼接；其余 ⇒ 一个空格连接。
---
--- segs[k] 描述第 k 条 content 行在逻辑串里的占位，供「源行字节偏移 ↔ 逻辑串字节偏移」
--- 互转（extmark 坐标回推用，纯函数、可单测）：
---   * lstart/lend：该行内容在逻辑串中的 [lstart,lend) 字节区间（已去前导/行尾空白后）。
---   * strip_lead：该行被 `^%s+` 去掉的前导空白字节数（首行恒 0；它去的是行尾空白，不挪前导坐标）。
---   * 段内换算：逻辑偏移 = lstart + (源行偏移 − strip_lead)；反向：源行偏移 = 逻辑偏移 − lstart + strip_lead。
---   * empty=true：该行去空白后为空，不贡献内容（lstart==lend）。
---@param lines string[]
---@return string str, table[] segs  -- segs[k] = { lstart, lend, strip_lead, empty? }
function M.merge_lines_mapped(lines)
  if #lines == 0 then return "", {} end
  local segs = {}
  local first = (lines[1]:gsub("%s+$", ""))
  local result = first
  segs[1] = { lstart = 0, lend = #first, strip_lead = 0 }
  for k = 2, #lines do
    local raw = lines[k]
    local right = (raw:gsub("^%s+", ""))
    local strip_lead = #raw - #right
    if right ~= "" then
      local lc = last_char(result)
      local rc = first_char(right)
      local lcp = lc ~= "" and utf8_cp(lc) or nil
      local la = lcp and chardata.char_attr(lcp) or nil
      local rcp = utf8_cp(rc)
      local sep
      if result == "" then
        sep = ""
      elseif lc == "\226\128\139" then
        sep = "" -- 行尾 ZWSP（断点标记）合并时不插空格，保持其为行内断点提示
      elseif is_wide(rcp) and (la == nil or lc == " " or la ~= "OTHER") then
        sep = ""
      elseif la and is_punct_attr(la) then
        sep = ""
      else
        sep = " "
      end
      local lstart = #result + #sep
      result = result .. sep .. right
      segs[k] = { lstart = lstart, lend = #result, strip_lead = strip_lead }
    else
      segs[k] = { lstart = #result, lend = #result, strip_lead = strip_lead, empty = true }
    end
  end
  return result, segs
end

--- 把多行合并为一条逻辑长行（不需要段映射时的薄包装；输出与 merge_lines_mapped 第一返回值一致）。
---@param lines string[]
---@return string
function M.merge_lines(lines)
  return (M.merge_lines_mapped(lines)) -- 括号截断第二返回值（segs）
end

-- ----------------------------------------------------------------------------
-- 输出清理（4.3.2）
-- ----------------------------------------------------------------------------

--- 去每行行尾空白；三连以上空行压缩为两个。
---@param lines string[]
---@return string[]
function M.cleanup(lines)
  local out = {}
  local blank = 0
  for _, l in ipairs(lines) do
    local s = (l:gsub("%s+$", ""))
    if s == "" then
      blank = blank + 1
      if blank <= 2 then out[#out + 1] = s end
    else
      blank = 0
      out[#out + 1] = s
    end
  end
  return out
end

-- ----------------------------------------------------------------------------
-- 折行核心（4.3.1 / 4.3.2 / 4.3.4 / 4.3.6）
-- ----------------------------------------------------------------------------

--- 贪心折行。
---@param atoms mdwrap.Atom[] 原子数组
---@param opts mdwrap.LayoutOpts
---@return string[] lines
function M.wrap(atoms, opts)
  opts = opts or {}
  local width = opts.width or 80
  local prefix_first = opts.prefix_first or ""
  local prefix_rest = opts.prefix_rest or ""
  local wrap_sentence = opts.wrap_sentence or false
  local punct_only = opts.cjk_break_at_punct_only or false
  local bracket_as_unit = opts.bracket_as_unit or false
  local width_fn = opts.width_fn or function(s) return #s end

  -- 短行容忍度（4.3.4），以配置 width 为基准
  local headroom = width - 20
  if headroom < 0 then headroom = 0 end
  local allow_s = math.min(60, headroom)
  local allow_c = math.min(12, headroom)

  -- 1) 原子 → token + gap 元信息。
  --    space 折叠进 token 间隙；ZWSP 是**最高优先级断行机会且保留**：其文本并入前一
  --    token 末尾（断行时留在上一行行尾，零宽），并标记该 token 之后为 zwsp 优先断点。
  local tokens, gap = {}, {}
  local zwsp_after = {}
  local pend_space = false
  local pend_zwsp_text = nil
  for _, a in ipairs(atoms) do
    if a.class == "space" then
      pend_space = true
    elseif a.class == "zwsp" then
      if #tokens > 0 then
        tokens[#tokens].text = tokens[#tokens].text .. a.text
        zwsp_after[#tokens] = true
      else
        pend_zwsp_text = (pend_zwsp_text or "") .. a.text -- 段首 ZWSP：留给下一 token
      end
    else
      local tok = a
      if pend_zwsp_text then
        tok = { text = pend_zwsp_text .. a.text, width = a.width, class = a.class, atomic_kind = a.atomic_kind }
        pend_zwsp_text = nil
      end
      tokens[#tokens + 1] = tok
      gap[#tokens] = { space = pend_space } -- 该 token 之「前」的间隙
      pend_space = false
    end
  end
  local m = #tokens
  if m == 0 then return {} end

  local function gmeta(k) return gap[k] or { space = false } end

  -- 括号配对作整体（bracket_as_unit）：用栈匹配配对括号；组宽 ≤ 续行整行可用宽时，锁定组内
  -- 所有间隙（不在括号内部断），宁可整组移到下一行（组前 `（` 之「前」仍可断）；组宽超一行才
  -- 回退内部断。半角括号紧贴内容时落在 word 原子首/尾字符，故按 token 文本首/末字符判定。
  local locked_gap = {}
  if bracket_as_unit then
    local avail_full = width - (opts.prefix_rest_width or width_fn(prefix_rest))
    if avail_full < 1 then avail_full = 1 end
    local stack = {}
    for idx = 1, m do
      local txt = tokens[idx].text
      local fcp = utf8_cp(first_char(txt))
      local lcp = utf8_cp(last_char(txt))
      if fcp and chardata.bracket_open[fcp] then
        stack[#stack + 1] = { idx = idx, close = chardata.bracket_open[fcp] }
      end
      if lcp and #stack > 0 and stack[#stack].close == lcp then
        local g = stack[#stack]
        stack[#stack] = nil
        if idx > g.idx then -- 组内至少有一个间隙才需锁
          local gw = 0
          for t = g.idx, idx do
            gw = gw + tokens[t].width
            if t > g.idx and gmeta(t).space then gw = gw + 1 end
          end
          if gw <= avail_full then
            for k = g.idx + 1, idx do locked_gap[k] = true end
          end
        end
      end
    end
  end

  -- 宽字符类（参与 CJK 式断行）：CJK 表意文字与全角标点皆属之。
  local function is_wide_class(a)
    local c = a.class
    return c == "cjk" or c == "punct_no_break_before" or c == "punct_no_break_after"
  end

  -- 全角标点类（标点旁恒可断，不受「仅标点断」约束）。
  local function is_punct_class(a)
    local c = a.class
    return c == "punct_no_break_before" or c == "punct_no_break_after"
  end

  -- 本行字间断许可（每行循环开始处按需设定）：
  --   非严格模式恒 true（传统 CJK 字间可断）；
  --   严格模式（punct_only）默认 false，仅当本行拟合区内无任何标点断点时临时置 true 作兜底，
  --   避免「无标点的超长中文子句」无处可断而退化成单字一行。
  local allow_cjk_cur = not punct_only

  -- token k 之「前」的间隙是否可断（k>=2）
  local function gap_breakable(k)
    if zwsp_after[k - 1] then return true end -- ZWSP 优先断点（高于禁则与括号锁定，用户手工标记）
    if locked_gap[k] then return false end    -- 括号组内部：整组作单元，不在内部断
    if gmeta(k).space then return true end
    local a, b = tokens[k - 1], tokens[k]
    if not can_break_after(a) then return false end
    if not can_break_before(b) then return false end
    -- 全角标点旁恒为断行机会（句末/逗号后断；禁前标点的「前」已被 can_break_* 挡掉）。
    if is_punct_class(a) or is_punct_class(b) then return true end
    -- 普通 CJK 字间：仅在许可时可断（严格模式默认禁止，无标点超长子句兜底时放开）。
    if allow_cjk_cur and (is_wide_class(a) or is_wide_class(b)) then return true end
    return false
  end

  -- token t 之「后」的间隙是否可断（或 t 为末 token）
  local function after_breakable(t)
    if t >= m then return true end
    return gap_breakable(t + 1)
  end

  local function level_of(t)
    local txt = tokens[t].text
    local lc = last_char(txt)
    local cp = utf8_cp(lc)
    if cp and chardata.sentence_sep[cp] then
      -- 半角句号触发时走缩写保护：Dr./e.g./单字母首字母缩写不算句末
      if lc == "." and chardata.is_abbrev(txt) then return "normal" end
      return "sentence"
    end
    -- 顿号「、」是并列词语连接符，非子句边界，低于逗号一级：不享受 clause 短行容忍，
    -- 仅在贪心填满到它时才断（严格模式下它仍是合法标点断点）。
    if cp == 0x3001 then return "normal" end
    if cp and chardata.clause_sep[cp] then return "clause" end
    return "normal"
  end

  local lines = {}
  local i = 1
  local line_idx = 0
  while i <= m do
    local prefix = (line_idx == 0) and prefix_first or prefix_rest
    -- 前缀占宽：默认量 prefix 字面宽；若调用方给了 prefix_*_width（前缀被渲染插件
    -- conceal/换图标导致显示宽≠字面宽，M5-B），取覆盖值。输出仍是字面前缀，只改记账。
    local pw
    if line_idx == 0 then
      pw = opts.prefix_first_width or width_fn(prefix)
    else
      pw = opts.prefix_rest_width or width_fn(prefix)
    end
    local avail = width - pw
    if avail < 1 then avail = 1 end

    -- 2) 贪心拟合区 i..k（累计宽 ≤ avail），记录每 token 处累计宽
    local w, k = 0, i - 1
    local cum = {}
    do
      local t = i
      while t <= m do
        local sp = (t > i and gmeta(t).space) and 1 or 0
        local nw = w + sp + tokens[t].width
        if nw > avail and t > i then break end
        w, cum[t], k = nw, nw, t
        t = t + 1
      end
    end

    local endj
    if k < i then
      -- 单 token 自身超宽（长 URL / 超长代码）：独占一行，允许超宽（4.3.6）
      endj = i
    else
      -- 严格模式兜底探测：先以「仅标点」口径（allow_cjk_cur=false）查拟合区 [i,k] 内有无断点；
      -- 若一个都没有（无标点的超长子句），放开字间断作兜底，否则保持「只在标点断」。
      allow_cjk_cur = not punct_only
      if punct_only then
        local has_punct_break = false
        for tt = i, k do
          if after_breakable(tt) then has_punct_break = true; break end
        end
        if not has_punct_break then allow_cjk_cur = true end
      end

      -- 3) 断点优先级扫描：ZWSP（最高，保留）＞ sentence ＞ clause（4.3.4）
      local zbest, sent, clause
      for tt = i, k do
        if after_breakable(tt) then
          if zwsp_after[tt] then zbest = tt end -- 取拟合区内最远的 ZWSP 断点
          local lv = level_of(tt)
          if lv == "sentence" and cum[tt] >= avail - allow_s then sent = tt end
          if lv == "clause" and cum[tt] >= avail - allow_c then clause = tt end
        end
      end
      if zbest then
        endj = zbest
      elseif (not wrap_sentence) and sent then
        endj = sent
      elseif (not wrap_sentence) and clause then
        endj = clause
      elseif after_breakable(k) then
        -- 4) 普通贪心断点
        endj = k
      else
        -- 5) 拟合边界落在不可断间隙：按原因分流（4.3.2）
        local next_no_before = (k + 1 <= m) and (not can_break_before(tokens[k + 1]))
        if next_no_before then
          -- PULL：禁前断标点拉回本行（溢出一个标点位）
          local e = k
          while e < m and not after_breakable(e) and not can_break_before(tokens[e + 1]) do
            e = e + 1
          end
          endj = e
        else
          -- PUSH：禁后断标点回退，推到下一行
          local e = k - 1
          while e > i and not after_breakable(e) do e = e - 1 end
          endj = (e >= i) and e or i
        end
      end
    end

    -- 7) 拼装本行文本（token 间若原有空格则补一个；行尾空白稍后清理）
    local parts = {}
    for tt = i, endj do
      if tt > i and gmeta(tt).space then parts[#parts + 1] = " " end
      parts[#parts + 1] = tokens[tt].text
    end
    lines[#lines + 1] = (prefix .. table.concat(parts)):gsub("%s+$", "")
    i = endj + 1
    line_idx = line_idx + 1
  end

  return lines
end

return M
