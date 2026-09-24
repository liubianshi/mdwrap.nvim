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
local spacing = require("mdwrap.spacing") -- 仅取 is_pangu_boundary；同为纯模块，无 vim 依赖

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
-- 静态断点档位：adm / qual / wide 三数组
-- ----------------------------------------------------------------------------
--
-- 断点判定曾由三套重叠的谓词各管一段：`gap_breakable`（这个间隙能不能断）、`level_of`
-- （断在哪一级标点）、`punct_break`/`needs_punct_end`（行尾落在这里合不合法）。三者谁都
-- 看不见全貌，于是每加一条规则要在三处各补一刀，而四个决定 endj 的出口只有两个接上了
-- 回落逻辑。
--
-- 关键观察：这三套判定的输入**全部是静态的**——禁则、括号锁定、盘古边界、atomic 类、
-- 标点级别，没有一项依赖当前行的 i / avail / cum。逐行变化的只有「本行准入哪一档」。
-- 故整段算一次下面三个并行数组，逐行只做一趟扫描（顺带干掉改版前逐行最多三次 O(k−i)
-- 的 has_break 探测——少标点中文 + wrap_sentence=true 下那是 +44% 的开销）。
--
--   adm[t]  ∈ 0..5  准入档：断在 token t 之后**能不能断**（数值越高越容易被放行）
--   qual[t] ∈ 0..4  质量档：断在这里，行尾**落在什么标点上**（即旧 level_of 的编码）
--   wide[t] ∈ bool  该间隙**涉不涉中文**（两侧任一为汉字或全角标点）
--
-- **三者互相独立，压不成一根有序标尺**——三类反例各指一个方向：
--   * 全角括号旁 `《「（`：可断（adm=4，恒为断行机会）却不配当行尾（qual=0，不是句读）；
--   * `Hello!|世`（半角句读粘连汉字）：配当行尾（qual=4）却在严格模式不可断（adm=1）；
--   * 纯拉丁的粘连 atomic 边界：可断（adm=3），但「涉不涉中文」从 adm 推不出来。
-- 把它们编进一根标尺，只会在挡住一类的同时漏掉另两类。
--
-- 断点分两族，**不可统一排序**：标点族（qual>0）按档排序并各带短行容忍；排版族（qual==0）
-- 按位置排序（越远越好），adm 只决定「本行准入哪一档」，不用于互相比较——非严格模式下
-- 「使用 pak 安装三个包」贪心填到「安装」之后是对的，退回到 `pak` 之后是错的，填满才是
-- 那个模式的语义。

local TIER_NONE = 0   -- 不可断：禁则命中、括号组内部、普通拉丁字母之间
local TIER_HAN = 1    -- 汉字之间硬断（严格模式的最后兜底）
local TIER_PANGU = 2  -- 盘古空格：CJK↔拉丁／行内代码之间那个半角空格（严格模式降级）
local TIER_ATOMIC = 3 -- atomic（链接/引用/数学/shortcode）边界，及涉中文的普通空格
local TIER_PUNCT = 4  -- 全角标点或全角括号旁（恒为断行机会）
local TIER_FREE = 5   -- 恒可断：ZWSP（用户手工标记）、纯拉丁词间空格、段尾

-- qual 档位编码（即旧 level_of 的 normal/series/clause/colon/sentence）。
local LV_NORMAL = 0
local LV_SERIES = 1   -- 顿号「、」：并列词语连接符，非子句边界，不享受 allow_c 短行容忍
local LV_CLAUSE = 2
local LV_COLON = 3
local LV_SENTENCE = 4

--- 宽字符类（参与 CJK 式断行）：CJK 表意文字与全角标点皆属之。
---@param a mdwrap.Atom
local function is_wide_class(a)
  local c = a.class
  return c == "cjk" or c == "punct_no_break_before" or c == "punct_no_break_after"
end

--- 全角标点类（标点旁恒可断，不受「仅标点断」约束）。
---@param a mdwrap.Atom
local function is_punct_class(a)
  local c = a.class
  return c == "punct_no_break_before" or c == "punct_no_break_after"
end

--- token 的质量档：断在它之后，行尾落在什么级别的标点上（旧 level_of）。
---@param atom mdwrap.Atom
---@return integer
local function qual_of(atom)
  local txt = atom.text
  local lc = last_char(txt)
  local cp = utf8_cp(lc)
  if not cp then return LV_NORMAL end
  if chardata.sentence_sep[cp] then
    -- 半角句号触发时走缩写保护：Dr./e.g./单字母首字母缩写不算句末
    if lc == "." and chardata.is_abbrev(txt) then return LV_NORMAL end
    return LV_SENTENCE
  end
  -- 冒号「：」介于句末与逗号之间：句末优先模式下仅在拟合区内无句末断点时才作偏好断点，
  -- 但仍高于逗号一级（用户裁定：冒号不等同于句号/分号/叹号）。
  if chardata.colon_sep[cp] then return LV_COLON end
  if cp == 0x3001 then return LV_SERIES end
  if chardata.clause_sep[cp] then return LV_CLAUSE end
  return LV_NORMAL
end

--- 整段算一次三个静态数组。
--- adm/wide 定义在 t = 1..m−1（token t 与 t+1 之间的间隙），qual 定义在 t = 1..m
--- （段尾 t == m 的「可断」与「落标点」由调用方的 t >= m 特判承担，不必伪造档位）。
---
--- **adm 的赋值顺序照抄改版前 `gap_breakable` 的分支次序**，两处反直觉之处尤须保留：
---   * `space` 整块排在禁则检查之**前**（间隙有空格就不再问禁则）；
---   * `zwsp` 排在 `locked_gap` 之**前**（ZWSP 高于括号锁定，用户手工标记优先）。
---@param tokens mdwrap.Atom[]
---@param gap table[]           gap[k].space：token k 之「前」的间隙有无空格
---@param zwsp_after boolean[]
---@param locked_gap boolean[]
---@param m integer
---@return integer[] adm, integer[] qual, boolean[] wide
local function compute_tiers(tokens, gap, zwsp_after, locked_gap, m)
  local adm, qual, wide = {}, {}, {}
  for t = 1, m do
    qual[t] = qual_of(tokens[t])
  end
  for t = 1, m - 1 do
    local a, b = tokens[t], tokens[t + 1]
    local w = is_wide_class(a) or is_wide_class(b)
    wide[t] = w
    local g = gap[t + 1]
    local tier
    if zwsp_after[t] then
      tier = TIER_FREE            -- ZWSP 优先断点（高于禁则与括号锁定）
    elseif locked_gap[t + 1] then
      tier = TIER_NONE            -- 括号组内部：整组作单元，不在内部断
    elseif g and g.space then
      -- 盘古间隙的判据取自文本两侧的原子，**不问这个空格是谁写的**：spacing.apply 只补
      -- 原文缺失的那些，原文已写好的同样是盘古空格，两者必须同等对待——否则折行结果取
      -- 决于源文件排没排过版，format(format(x)) ~= format(x)。判据与插入口径同源
      -- （spacing.is_pangu_boundary 是该边界的唯一定义）。
      if not w then
        tier = TIER_FREE          -- 纯拉丁词间空格：与中文排版无关，恒可断
      elseif spacing.is_pangu_boundary(a, b) then
        tier = TIER_PANGU
      else
        -- 注意：CJK 与链接／数学／引用／shortcode 之间的**手写空格**必须与**粘连**的
        -- atomic 边界同档（都是 TIER_ATOMIC）。待办 ① 原拟把带空格的那种降到盘古档，
        -- 实测直接破幂等：折行一旦把 CJK 与 atomic 分到两行，merge_lines 重折时会在中间
        -- 插一个空格（左末 CJK、右首 `[` 属 OTHER，走 sep=" " 分支），于是同一个边界在
        -- 「粘连」与「带空格」之间来回变化，两档不同即 format(format(x)) ~= format(x)。
        -- 详见 DECISIONS「断点档位统一」一节。
        tier = TIER_ATOMIC
      end
    elseif not can_break_after(a) or not can_break_before(b) then
      tier = TIER_NONE            -- 禁则：禁后断 / 禁前断标点
    elseif is_punct_class(a) or is_punct_class(b) then
      -- 全角标点与全角括号旁恒为断行机会（句末/逗号后断；禁前标点的「前」已被上一步挡掉）。
      -- 这里**只给准入、不给质量**：`《「（` 的 qual 是 LV_NORMAL，严格模式下行尾落在它们
      -- 旁边仍要回落到标点——「可断性」与「行尾合法性」在全角括号上并不一致。
      tier = TIER_PUNCT
    elseif a.class == "atomic" or b.class == "atomic" then
      -- atomic 原子（链接/引用/数学/shortcode 等不可分单元）边界恒可断：相当于一个「词」，
      -- 在其前后换行是合理排版，不属于「汉字之间硬断」（DECISIONS「atomic 边界例外」）。
      tier = TIER_ATOMIC
    elseif w then
      tier = TIER_HAN             -- 普通 CJK 字间：严格模式下的最后兜底
    else
      tier = TIER_NONE
    end
    adm[t] = tier
  end
  return adm, qual, wide
end

-- 供单元测试观察静态分档（生产路径不经这些名字）。
M._compute_tiers = compute_tiers
M._TIER = { NONE = TIER_NONE, HAN = TIER_HAN, PANGU = TIER_PANGU,
  ATOMIC = TIER_ATOMIC, PUNCT = TIER_PUNCT, FREE = TIER_FREE }
M._LV = { NORMAL = LV_NORMAL, SERIES = LV_SERIES, CLAUSE = LV_CLAUSE,
  COLON = LV_COLON, SENTENCE = LV_SENTENCE }

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
  -- `wrap_sentence=true` 是「按宽填满、行长尽量一致」（Vim `gww` 的语义），而
  -- `cjk_break_at_punct_only` 是「只在标点处断」。**这两条在中文里语义互斥**：中文没有词
  -- 边界，只在标点断就意味着行长完全由标点位置决定，填满无从谈起——实测默认组合折出
  -- 20/40/22/28/40/42/18 这种参差行长，正是它的表现。故填满模式下强制放开字间断，
  -- 让 `wrap_sentence` 单个开关就能拿到 gww 效果（用户裁定）。
  -- 断点处的约束不受影响，仍由禁则保证：英文单词是一个 token，不会在内部断；
  -- `。，」》` 等不落行首，即不会「在句号前面断」。
  local punct_only = (opts.cjk_break_at_punct_only or false) and not wrap_sentence
  local bracket_as_unit = opts.bracket_as_unit or false
  local width_fn = opts.width_fn or function(s) return #s end

  -- 短行容忍度（4.3.4），以配置 width 为基准。
  -- 句级标点（sentence）不设短行下限：行尾力求落在句末，「一句一行」优先于填满（见 DECISIONS）。
  -- 冒号（colon）与逗号（clause）保留 allow_c 下限，避免断点靠行首时把行切得过短。
  local headroom = width - 20
  if headroom < 0 then headroom = 0 end
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

  -- ---- 三个静态数组：整段算一次，逐行只查表（定义见本文件「静态断点档位」一节）----
  local adm, qual, wide = compute_tiers(tokens, gap, zwsp_after, locked_gap, m)

  -- 严格中文模式：仅此模式下行尾必须落在标点上（punct_far / needs_punct_end 才有意义）。
  local strict_end = punct_only and (not wrap_sentence)

  -- 本行准入档（每行循环开始处重设）。这是**唯一**的逐行断点状态：改版前的
  -- allow_cjk_cur / allow_pangu_cur 两个布尔开关本质上就是它的一种笨拙编码。
  local min_tier = punct_only and TIER_ATOMIC or TIER_HAN

  -- 下面三个谓词定义在逐行 while 循环**之外**（LuaJIT 下在循环内建闭包会触发 FNEW NYI），
  -- 经 min_tier 这个 upvalue 感知当前行的档位。三者与改版前的三套判定机械等价：
  --   after_breakable(t) ≡ gap_breakable(t+1)   两个许可开关换成档位阈值
  --   punct_break(t)     ≡ level_of(t) ~= "normal"（段尾亦算）
  --   needs_punct_end(t) ≡ 涉中文且不落标点

  --- token t 之「后」的间隙在本行档位下是否可断（t >= m 为段尾，恒可断）。
  local function after_breakable(t)
    if t >= m then return true end
    return adm[t] >= min_tier
  end

  --- 断在 t 之后，行尾是否落在标点上（句末／冒号／逗号／顿号，含半角句读；段尾亦算）。
  local function punct_break(t)
    return t >= m or qual[t] > 0
  end

  --- 严格中文模式下，行尾不得停在此处、须回落到标点断点：该间隙涉及中文（两侧任一为
  --- 汉字或全角标点，盘古间隙按定义必有一侧为宽字符）且不落在标点上。纯拉丁语境的断点
  --- （英文词间空格、英文与链接／代码之间）不涉中文，照常可作行尾。
  ---
  --- **不变式一：合法性只看 qual / wide，绝不看 adm。** ZWSP 落点的 qual 是 LV_NORMAL，
  --- 若这里顺手改用「可断性」口径，CJK + ZWSP 的落点会被判为不合法而遭回落覆盖，
  --- 「ZWSP 是用户手工标记、绝不被覆盖」这条裁定当场就破。
  local function needs_punct_end(t)
    return strict_end and t < m and wide[t] and qual[t] == 0
  end

  -- ---- 出口收尾：六个决定 endj 的出口共用同一套下限 ----
  -- 改版前只有「贪心点 k」与「PUSH」两个出口接了回落，溢出、PULL 两个没接，且回落路径
  -- 本身不设短行下限——DECISIONS 末尾的待办 ①②③ 与审查发现的 ④′ 全是这一个形状。
  -- 逐行变化的量（avail / cum / k / 两个标点候选）提到 while 循环外作 upvalue，
  -- 使下面三个函数只定义一次（LuaJIT 下在循环内建闭包会触发 FNEW NYI）。
  local avail, cum, k, punct_far, punct_ok

  --- 溢出扫描的「合法行尾」口径（用户裁定）：停在段尾、ZWSP、标点、不涉中文的断点，或
  --- atomic 边界；跳过汉字间与盘古空格（含上面降档的 CJK↔atomic 手写空格），也跳过
  --- 「可断但不配当行尾」的全角括号旁。
  --- **停在 atomic 边界这一条守住了 DECISIONS「含 atomic 的行不会溢出，在 atomic 边界断」**
  --- ——一律扫到标点会推翻那条裁定的一角。改版前这里扫的是「下一个可断点」，且进入该分支
  --- 时盘古档已放开，于是会停在盘古空格上，把一个英文词单独甩成一行。
  local function legal_end(t)
    if t >= m then return true end                 -- 段尾
    if zwsp_after[t] then return true end          -- 用户手工断点标记，恒合法
    if adm[t] < TIER_ATOMIC then return false end  -- 汉字间 / 盘古空格：跳过
    if qual[t] > 0 then return true end            -- 行尾落在标点上
    if not wide[t] then return true end            -- 纯拉丁语境，不涉中文
    return adm[t] == TIER_ATOMIC                   -- atomic 边界；全角括号旁（=4）继续往后找
  end

  --- 自 t 起向段尾方向找第一个合法行尾。
  local function overflow_from(t)
    while t < m and not legal_end(t) do t = t + 1 end
    return t
  end

  --- 落点 e 在严格模式下是否够格作行尾：既要落在合法处，又要让行不至于过短。
  local function acceptable_end(e)
    if e >= m then return true end
    local q = qual[e]
    if q == LV_NORMAL then return not wide[e] end -- 非标点落点：只有不涉中文才够格
    if q == LV_SENTENCE then return true end      -- 句级标点不设短行下限（用户裁定，不得动）
    -- 次级标点（冒号／逗号／顿号）：行不得过短，与 colon / clause 槽同一个 allow_c。
    -- 拟合区外的落点（PULL 已溢出）行本就超宽，无从谈短，直接放行。
    local c = cum[e]
    return (c == nil) or c >= avail - allow_c
  end

  --- 前瞻一步：若本行在 t 之后断开，**下一行**会不会照样超宽？
  --- 下一行从 t+1 起贪心到第一个合法行尾：装得下即不超宽。段尾之前没有合法行尾时，
  --- 下一行只能整段溢出，同样记作超宽。
  --- 续行可用宽按 prefix_rest 记账（本行可能是首行，avail 未必等于续行的可用宽）。
  local function overflows_next_line(t)
    local rest = width - (opts.prefix_rest_width or width_fn(prefix_rest))
    if rest < 1 then rest = 1 end
    local w2 = 0
    for tt = t + 1, m do
      if tt > t + 1 and gmeta(tt).space then w2 = w2 + 1 end
      w2 = w2 + tokens[tt].width
      if w2 > rest then return true end   -- 还没走到合法行尾就已经超宽
      if legal_end(tt) then return false end
    end
    return false                           -- 整个剩余部分都装得下
  end

  --- 出口收尾。严格模式下落点不够格时，按两种情形分岔（这个分岔是 07/09/11/34/44
  --- 不受影响的**唯一**理由，不可简化为「不够格就溢出」）：
  ---   * 拟合区内**有**标点候选 → 取最远且过 allow_c 下限者；一个都没过下限 → 溢出到下一个
  ---     合法行尾（宁可长一行，也不吐出 4 列的行，那是「两头都坏」）；
  ---   * 拟合区内**一个标点候选都没有** → 维持现状，落在最好的排版断点上
  ---     （既有裁定：atomic 边界恒可断）。
  --- 超宽单 token 出口（k < i）与 ZWSP 出口不经此函数：前者没有可选的落点，后者是用户
  --- 手工标记，绝不被回落覆盖。
  local function settle(e)
    if not strict_end then return e end
    if acceptable_end(e) then return e end
    -- PULL 的 walk 可能停在禁则位置（adm == TIER_NONE）：那是禁则刻意为之的落点，不得改写。
    if e < m and adm[e] == TIER_NONE then return e end
    if not punct_far then return e end            -- 零标点候选：维持现状
    if punct_ok then return punct_ok end
    -- 有标点候选，但一个都没过 allow_c 下限。两条退路：回落到那个偏短的标点，或整行溢出。
    -- **判据不是「落点有多短」，而是「回落之后是不是仍然要吐一个超宽行」**——用户抱怨的
    -- 「两头都坏」是一个复合现象（4 列的行后面跟一个 82 列的行），不是单看短行那一头。
    -- 拿百分比阈值去猜短行必然两头不讨好：50% 会把「48 列 / 100 列可用宽 + 下一行 73 列」
    -- 这种纯赚的回落误判成溢出，而再调低又救不了下一个反例。故直接前瞻一步：
    --   * 回落后下一行放得下（不超宽）→ 回落是纯赚，短行换来的是一个正常行；
    --   * 回落后下一行照样超宽   → 回落只是在超宽行前面多切一刀短行，两头都坏，宁可溢出。
    -- 前瞻每行最多一次，长度不超过下一行的合法断点距离，相对逐行扫描可忽略。
    local fallback = (qual[e] > LV_NORMAL) and e or punct_far
    local c = cum[fallback]
    if c and c * 4 >= avail then return fallback end
    return overflow_from(k > e and k or e)
  end

  --- 短尾巴并入：断点之后若只剩一小截就到句末，把那一截并进本行，宁可有限超宽。
  ---
  --- 为什么需要它：`M.wrap` 是逐行贪心的，看不见下一行。断在拟合区内最远的逗号上，本行
  --- 自身无可指摘，却可能给下一行只留一个十几列的尾巴——用户实例（width=80）：
  ---   `……六成记在中国香港名下，` (72) / `十年未降[^hkbook]。` (19)
  --- 句号落在 91 列、已在拟合区外，贪心够不着；而「句级标点不设短行下限」又让那 19 列的
  --- 尾巴立刻成行。两条各自正确的规则叠出一个两头都别扭的结果。
  ---
  --- 适用条件（每一条都是为了不误伤既有裁定）：
  ---   * 仅 strict_end——与 settle 同门控，`wrap_sentence=true`（按宽填满）绝不超宽；
  ---   * 本行落点**不是**句级标点——已落句末就没有短尾巴问题，否则「一句一行」会被
  ---     连续短句黏成一行；
  ---   * 目标句级标点 `t < m`——`t == m` 是段落最后一行，末行短本来就是正常的；
  ---   * 尾巴宽度 ≤ avail/4，故超宽幅度也 ≤ avail/4，不会失控。
  local function merge_short_tail(endj)
    if not strict_end or endj >= m then return endj end
    if qual[endj] == LV_SENTENCE then return endj end
    if zwsp_after[endj] then return endj end -- ZWSP 是手工标记，不动它
    local limit = avail / 4
    local w2 = 0
    for t = endj + 1, m do
      if t > endj + 1 and gmeta(t).space then w2 = w2 + 1 end
      w2 = w2 + tokens[t].width
      if w2 > limit then return endj end -- 尾巴不算短，维持原落点
      if qual[t] == LV_SENTENCE and t < m and after_breakable(t) then return t end
    end
    return endj -- 一路到段尾都没遇到句级标点：这是末行，短是正常的
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
    avail = width - pw
    if avail < 1 then avail = 1 end

    -- 2) 贪心拟合区 i..k（累计宽 ≤ avail），记录每 token 处累计宽
    local w = 0
    k = i - 1
    cum = {}
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
      -- 3) 定本行准入档：拟合区 [i,k] 内的最高静态档位一趟扫出，即可定档——
      --    「区间内按某口径有无断点」等价于「区间最高档 >= 该口径阈值」，故改版前两次
      --    has_break 探测压成一次 max。严格模式的三档阶梯：
      --      第一档 TIER_ATOMIC：只认 ZWSP／纯拉丁或涉中文的普通空格／全角标点旁／atomic 边界；
      --      第二档 TIER_PANGU ：拟合区内一个都没有时放开盘古空格（仍禁汉字间硬断）；
      --      第三档 TIER_HAN   ：仍没有时按 wrap_sentence 分流——填满模式放开汉字间硬断，
      --                          句末优先模式改为整段溢出到下一个标点，绝不在非标点处断。
      local best_tier = 0
      for tt = i, k do
        local tier = (tt >= m) and TIER_FREE or adm[tt] -- 段尾恒可断
        if tier > best_tier then best_tier = tier end
      end
      min_tier = punct_only and TIER_ATOMIC or TIER_HAN
      local overflow_to_punct = false
      if punct_only and best_tier < TIER_ATOMIC then
        min_tier = TIER_PANGU
        if best_tier < TIER_PANGU then
          if wrap_sentence then min_tier = TIER_HAN else overflow_to_punct = true end
        end
      end

      -- 4) 单趟扫描取候选：ZWSP（最高，保留）＞ sentence ＞ colon ＞ clause（4.3.4）。
      --    **按 qual 精确分槽**：顿号 LV_SERIES 不进 clause 槽——它若白捡 allow_c 那条短行
      --    容忍路径，行为就变了；它只在贪心填满到它、或作 punct_far 回落点时才断。
      local zbest, sent, colon, clause
      punct_far, punct_ok = nil, nil
      for tt = i, k do
        if after_breakable(tt) then
          if zwsp_after[tt] then zbest = tt end -- 取拟合区内最远的 ZWSP 断点
          -- 最远标点断点（无短行下限，供回落用）；非严格模式下无人消费，不必算。
          if strict_end and punct_break(tt) then
            punct_far = tt
            -- 过了 allow_c 短行下限的最远标点候选：回落的首选落点（③ 的下限来源）。
            if cum[tt] >= avail - allow_c then punct_ok = tt end
          end
          local q = qual[tt]
          if q == LV_SENTENCE then
            sent = tt -- 句末对齐：拟合区内任意句级标点皆可断，取最远（不设短行下限）
          elseif q == LV_COLON then
            -- 冒号「高于逗号、低于句号」：优先级由下面 if 链的顺序保证；与逗号一样保留
            -- allow_c 短行下限，避免冒号靠行首时断出过短的行（用户裁定）。
            if cum[tt] >= avail - allow_c then colon = tt end
          elseif q == LV_CLAUSE then
            if cum[tt] >= avail - allow_c then clause = tt end
          end
        end
      end

      -- 5) 选择。**不变式二：这条 if 链的形状与优先级不得重排。** zbest / sent 两个分支
      --    排在贪心与 PULL/PUSH 之前，是「走到回落出口时拟合区内必定已无 ZWSP、无句末
      --    候选」的保证；一旦重排，「ZWSP 绝不被覆盖」与「句级标点不设短行下限」两条裁定
      --    就会被回落路径的下限间接破坏。
      if overflow_to_punct then
        -- 无标点超长子句 + 句末优先：整段溢出到下一个**合法行尾**（或段尾），绝不在非标点
        -- 处断。这里扫的不再是「下一个可断点」——那会停在盘古空格上（④′／T4）。
        endj = overflow_from(k)
      elseif zbest then
        endj = zbest -- **不经 settle**：ZWSP 是用户手工标记，绝不被回落覆盖
      elseif (not wrap_sentence) and sent then
        endj = settle(sent)
      elseif (not wrap_sentence) and colon then
        endj = settle(colon)
      elseif (not wrap_sentence) and clause then
        endj = settle(clause)
      elseif after_breakable(k) then
        endj = settle(k) -- 普通贪心断点
      else
        -- 6) 拟合边界落在不可断间隙：按原因分流（4.3.2）
        local next_no_before = (k + 1 <= m) and (not can_break_before(tokens[k + 1]))
        if next_no_before then
          -- PULL：禁前断标点拉回本行（溢出一个标点位）
          local e = k
          while e < m and not after_breakable(e) and not can_break_before(tokens[e + 1]) do
            e = e + 1
          end
          endj = settle(e)
        else
          -- PUSH：禁后断标点回退，推到下一行
          local e = k - 1
          while e > i and not after_breakable(e) do e = e - 1 end
          if e >= i and after_breakable(e) then
            endj = settle(e)
          else
            -- 退无可退：i 之后紧跟的就是禁则间隙（实例：行首是「《」，其后是一个比整行
            -- 还宽的 URL）。此时让 i 独占一行会把禁后断标点留在行尾，禁则当场破——
            -- 判据是「退回去的落点可不可断」，不是「退没退回到 i」。改为向前拉到第一个
            -- 可断处，宁可这一行超宽（4.3.6 允许），也不让 `《「（` 落在行尾。
            local t = i
            while t < m and not after_breakable(t) do t = t + 1 end
            endj = t
          end
        end
      end
    end

    -- 7) 短尾巴并入（见 merge_short_tail 的说明）。放在所有出口之后、拼装之前，
    --    使六个出口一视同仁；超宽单 token 出口（k < i）落点即 i，其后若紧跟句末也该并入。
    endj = merge_short_tail(endj)

    -- 8) 拼装本行文本（token 间若原有空格则补一个；行尾空白稍后清理）
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
