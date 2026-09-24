-- 纯 Lua 单元测试：layout.lua（注入 stub 宽度，无 Neovim）
-- 运行：LUA_PATH 含 ./lua/?.lua，luajit tests/unit/test_layout.lua
-- 覆盖设计文档 6.3 用例 01–04、22–25 的逻辑等价单元用例。

local layout = require("mdwrap.layout")
local chardata = require("mdwrap.chardata")

-- ---------- 极简断言框架 ----------
local pass, fail = 0, 0
local function fmt(v)
  if type(v) == "table" then
    local t = {}
    for _, x in ipairs(v) do t[#t + 1] = string.format("%q", x) end
    return "{" .. table.concat(t, ", ") .. "}"
  end
  return string.format("%q", tostring(v))
end
local function arr_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end
local function check(name, got, want)
  local ok = (type(want) == "table") and arr_eq(got, want) or (got == want)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL " .. name)
    print("  got : " .. fmt(got))
    print("  want: " .. fmt(want))
  end
end

-- ---------- stub 原子构造器（CJK/全角=2，ASCII=1，ZWSP=0）----------
local function chars(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = 1
    if b >= 0xF0 then len = 4 elseif b >= 0xE0 then len = 3 elseif b >= 0xC0 then len = 2 end
    out[#out + 1] = s:sub(i, i + len - 1)
    i = i + len
  end
  return out
end

local function cp(ch)
  return layout._utf8_cp(ch)
end

-- 把纯文本转为 stub 原子（连续 ASCII 字母数字归并为 word）
local function atoms_of(s)
  local res = {}
  local pendword
  local function flush()
    if pendword then res[#res + 1] = { text = pendword, width = #pendword, class = "word" }; pendword = nil end
  end
  for _, ch in ipairs(chars(s)) do
    local u = cp(ch) or 0
    if u == 0x200B then
      flush(); res[#res + 1] = { text = ch, width = 0, class = "zwsp" }
    elseif ch == " " then
      flush(); res[#res + 1] = { text = " ", width = 1, class = "space" }
    else
      local attr = chardata.char_attr(u)
      if attr == "CJK" or attr == "CJK_PUN" then
        flush(); res[#res + 1] = { text = ch, width = 2, class = "cjk" }
      elseif attr == "PUN_FORBIT_BREAK_BEFORE" then
        flush(); res[#res + 1] = { text = ch, width = 2, class = "punct_no_break_before" }
      elseif attr == "PUN_FORBIT_BREAK_AFTER" then
        flush(); res[#res + 1] = { text = ch, width = 2, class = "punct_no_break_after" }
      else -- OTHER：ASCII 等，归并为 word
        pendword = (pendword or "") .. ch
      end
    end
  end
  flush()
  return res
end

local function wrap(s, opts) return layout.wrap(atoms_of(s), opts) end

-- ============================================================
-- merge_lines（用例 22 的合并规则）
-- ============================================================
check("merge cjk no-space", layout.merge_lines({ "这是第一行中文内容", "这是第二行中文内容" }),
  "这是第一行中文内容这是第二行中文内容")
check("merge english one-space", layout.merge_lines({ "This is the first", "line and second" }),
  "This is the first line and second")
check("merge punct no-space", layout.merge_lines({ "句末有逗号，", "下一行继续" }),
  "句末有逗号，下一行继续")

-- ============================================================
-- 01 basic-cjk（width=20，纯贪心）
-- ============================================================
check("01 basic-cjk", wrap("这是一段用来测试中文硬折行的纯中文文本它没有任何标点也没有英文字符共计四十个汉字", { width = 20 }),
  { "这是一段用来测试中文", "硬折行的纯中文文本它", "没有任何标点也没有英", "文字符共计四十个汉字" })

-- ============================================================
-- 02 kinsoku-before（width=20，。，」回收到行尾，行宽22）
-- ============================================================
check("02 kinsoku-before", wrap("第一句话写满整十个字。第二句也写满整十个字，第三句加上「关键内容」", { width = 20 }),
  { "第一句话写满整十个字。", "第二句也写满整十个字，", "第三句加上「关键内容」" })

-- ============================================================
-- 03 kinsoku-after（width=20，「《（绝不行尾，行宽18）
-- ============================================================
check("03 kinsoku-after", wrap("第一段文字到这里啊「引文内容写八个字《书名占位补足八》（括号里的内容）。", { width = 20 }),
  { "第一段文字到这里啊", "「引文内容写八个字", "《书名占位补足八》", "（括号里的内容）。" })

-- ============================================================
-- 04 sentence-preferred（width=30，句末早断）
-- ============================================================
check("04 sentence-preferred", wrap("今天天气晴朗适合出门。我们一起去附近的公园散步聊天。", { width = 30 }),
  { "今天天气晴朗适合出门。", "我们一起去附近的公园散步聊天。" })

-- ============================================================
-- 24 wrap-sentence（width=30，wrap_sentence=true，无视句号填满）
-- ============================================================
check("24 wrap-sentence", wrap("今天天气晴朗适合出门。我们一起去附近的公园散步聊天。", { width = 30, wrap_sentence = true }),
  { "今天天气晴朗适合出门。我们一起", "去附近的公园散步聊天。" })

-- ============================================================
-- 27–29 英文语义断行（width=40，半角终止符触发句末/子句偏好；缩写保护）
-- ============================================================
check("27 en-sentence-preferred", wrap("The cat sat on the mat. The dog ran in the park quickly.", { width = 40 }),
  { "The cat sat on the mat.", "The dog ran in the park quickly." })
check("28 en-abbreviation", wrap("See Dr. Smith and Mr. Jones at the office today please now.", { width = 40 }),
  { "See Dr. Smith and Mr. Jones at the", "office today please now." })
-- 冒号为中间级且带 allow_c 短行下限：「following:」(col 26 < 40-12) 太靠前不在此断，
-- 改按词贪心填满（用户裁定，见 CHANGELOG / golden 29-en-colon）。
check("29 en-colon", wrap("Please note the following: all lines must wrap at punctuation marks correctly.", { width = 40 }),
  { "Please note the following: all lines", "must wrap at punctuation marks", "correctly." })

-- ============================================================
-- 22 rewrap-merge（width=30，合并后重折；中文无空格 / 英文一空格）
-- ============================================================
check("22 rewrap cjk", wrap(layout.merge_lines({ "这是第一行中文内容", "这是第二行中文内容" }), { width = 30 }),
  { "这是第一行中文内容这是第二行中", "文内容" })
check("22 rewrap english", wrap(layout.merge_lines({ "This is the first", "line and second" }), { width = 30 }),
  { "This is the first line and", "second" })

-- ============================================================
-- 23 zwsp（width=30，ZWSP 强制断点，消费不保留）
-- ============================================================
check("23 zwsp", wrap("前面这段中文内容写到这里\226\128\139然后继续后半段内容直到结束为止", { width = 30 }),
  { "前面这段中文内容写到这里\226\128\139", "然后继续后半段内容直到结束为止" })

-- ============================================================
-- 13 nested-quote（width=20，前缀计入行宽）
-- ============================================================
check("13 nested-quote prefix", layout.wrap(atoms_of("嵌套引用里的中文内容需要正确折行"),
  { width = 20, prefix_first = "> > ", prefix_rest = "> > " }),
  { "> > 嵌套引用里的中文", "> > 内容需要正确折行" })

-- ============================================================
-- 溢出规则（4.3.6）：单原子超宽独占一行
-- ============================================================
check("overflow single atom", layout.wrap({
  { text = "前", width = 2, class = "cjk" },
  { text = "https://example.com/a/very/long/path", width = 36, class = "word" },
  { text = "后", width = 2, class = "cjk" },
}, { width = 20 }),
  { "前", "https://example.com/a/very/long/path", "后" })

-- ============================================================
-- cleanup：行尾空白 + 三连以上空行压缩为两个
-- ============================================================
check("cleanup", layout.cleanup({ "abc   ", "", "", "", "def" }),
  { "abc", "", "", "def" })


-- ============================================================
-- 静态断点档位 adm / qual / wide（layout._compute_tiers）
-- ------------------------------------------------------------
-- 这三个数组是 M.wrap 逐行判定的唯一数据来源，测它们等于测断点规则本身。
-- 重点是三类**互相独立**的反例：可断但不配当行尾、配当行尾但不可断、
-- 可断性推不出涉不涉中文——它们证明这三个属性压不成一根有序标尺。
-- ============================================================

local TIER, LV = layout._TIER, layout._LV

--- 把原子流按 M.wrap 第 1 步的口径拆成 tokens / gap / zwsp_after，再算三数组。
--- （与 wrap 内部同构；ZWSP 并入前一 token 末尾并标记其后为优先断点。）
local function tiers_of(s, locked_gap)
  local tokens, gap, zwsp_after = {}, {}, {}
  local pend_space, pend_zwsp = false, nil
  for _, a in ipairs(atoms_of(s)) do
    if a.class == "space" then
      pend_space = true
    elseif a.class == "zwsp" then
      if #tokens > 0 then
        tokens[#tokens].text = tokens[#tokens].text .. a.text
        zwsp_after[#tokens] = true
      else
        pend_zwsp = (pend_zwsp or "") .. a.text
      end
    else
      local tok = a
      if pend_zwsp then
        tok = { text = pend_zwsp .. a.text, width = a.width, class = a.class, atomic_kind = a.atomic_kind }
        pend_zwsp = nil
      end
      tokens[#tokens + 1] = tok
      gap[#tokens] = { space = pend_space }
      pend_space = false
    end
  end
  local adm, qual, wide = layout._compute_tiers(tokens, gap, zwsp_after, locked_gap or {}, #tokens)
  return adm, qual, wide, tokens
end

--- 取「token t 之后」那个间隙的三元组，便于逐条断言。
local function gap_at(s, t, locked_gap)
  local adm, qual, wide = tiers_of(s, locked_gap)
  return { adm = adm[t], qual = qual[t], wide = wide[t] }
end
local function tri(a, q, w) return { adm = a, qual = q, wide = w } end
local function tri_eq(g, want)
  return g.adm == want.adm and g.qual == want.qual and (g.wide and true or false) == want.wide
end
local function check_tri(name, got, want)
  if tri_eq(got, want) then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL " .. name)
    print(string.format("  got : adm=%s qual=%s wide=%s", tostring(got.adm), tostring(got.qual), tostring(got.wide)))
    print(string.format("  want: adm=%s qual=%s wide=%s", tostring(want.adm), tostring(want.qual), tostring(want.wide)))
  end
end

-- ---- 反例一（T1）：全角括号旁「可断，但不配当行尾」----
-- 「丁《」：《 是禁后断标点，其**前**恒可断（adm=TIER_PUNCT），但 qual 是 normal
-- ——严格模式下行尾落这里仍须回落。若把「可断且 qual=normal 且涉中文」一律归为汉字档，
-- 「甲乙丙丁《书名》戊己」会退化成不可断。
check_tri("tier T1 丁|《 可断但非行尾", gap_at("甲乙丙丁《书名》戊己", 4), tri(TIER.PUNCT, LV.NORMAL, true))
check_tri("tier T1 》|戊 可断但非行尾", gap_at("甲乙丙丁《书名》戊己", 8), tri(TIER.PUNCT, LV.NORMAL, true))
-- 禁则一侧：《 之「后」不可断，》 之「前」不可断
check_tri("tier T1 《|书 禁后断", gap_at("甲乙丙丁《书名》戊己", 5), tri(TIER.NONE, LV.NORMAL, true))
check_tri("tier T1 名|》 禁前断", gap_at("甲乙丙丁《书名》戊己", 7), tri(TIER.NONE, LV.NORMAL, true))

-- ---- 反例二（Hole A）：半角句读粘连汉字，「配当行尾，但严格模式不可断」----
-- word「Hello!」的 qual 是 sentence（半角 ! 入 sentence_sep），但它与汉字之间没有空格，
-- 走的是汉字间硬断那一档（adm=TIER_HAN），严格模式第一、二档都不准入。
check_tri("tier HoleA Hello!|世 配行尾但不可断", gap_at("Hello!世界你好", 1), tri(TIER.HAN, LV.SENTENCE, true))

-- ---- 反例三（Hole B）：纯拉丁的粘连 atomic 边界，「可断性推不出涉不涉中文」----
-- 与 T1 同为 qual=normal，却因 wide=false 而不触发严格模式回落。
--- atomic 原子 atoms_of 造不出来，直接按 M.wrap 第 1 步的产物手工构造 token 序列。
local function tiers_raw(tokens, spaces)
  local gap = {}
  for t = 1, #tokens do gap[t] = { space = spaces and spaces[t] or false } end
  local adm, qual, wide = layout._compute_tiers(tokens, gap, {}, {}, #tokens)
  return function(t) return { adm = adm[t], qual = qual[t], wide = wide[t] } end
end
local W = function(s) return { text = s, width = #s, class = "word" } end
local A = function(s, k) return { text = s, width = #s, class = "atomic", atomic_kind = k or "code" } end
local C = function(s) return { text = s, width = 2, class = "cjk" } end

local hb = tiers_raw({ W("foo"), A("`x`"), A("`y`"), W("bar") })
check_tri("tier HoleB foo|`x` 可断但不涉中文", hb(1), tri(TIER.ATOMIC, LV.NORMAL, false))
check_tri("tier HoleB `x`|`y` 可断但不涉中文", hb(2), tri(TIER.ATOMIC, LV.NORMAL, false))

-- CJK↔atomic：粘连边界恒可断（TIER_ATOMIC，DECISIONS「atomic 边界例外」），且 wide=true
local ca = tiers_raw({ C("甲"), A("[t](u)", "link"), C("乙") })
check_tri("tier CJK|atomic 粘连", ca(1), tri(TIER.ATOMIC, LV.NORMAL, true))
check_tri("tier atomic|CJK 粘连", ca(2), tri(TIER.ATOMIC, LV.NORMAL, true))

-- ---- adm 赋值表逐行复核 ----
-- 第 3 行（间隙有空格）：双非 wide → FREE；盘古边界 → PANGU；其余 → ATOMIC
check_tri("tier space 纯拉丁词间", gap_at("foo bar", 1), tri(TIER.FREE, LV.NORMAL, false))
check_tri("tier space 盘古 2023|年", gap_at("共 2023 年", 2), tri(TIER.PANGU, LV.NORMAL, true))
check_tri("tier space 盘古 共|2023", gap_at("共 2023 年", 1), tri(TIER.PANGU, LV.NORMAL, true))
check_tri("tier space 汉字间空格", gap_at("甲 乙", 1), tri(TIER.ATOMIC, LV.NORMAL, true))
-- 第 7 行（汉字间）与第 8 行（其余）
check_tri("tier 汉字间", gap_at("甲乙", 1), tri(TIER.HAN, LV.NORMAL, true))
-- 顿号：之前禁断（禁前断标点），之后可断且 qual=series（不进 clause 槽）
check_tri("tier 、之前禁断", gap_at("甲、乙", 1), tri(TIER.NONE, LV.NORMAL, true))
check_tri("tier 、之后 series", gap_at("甲、乙", 2), tri(TIER.PUNCT, LV.SERIES, true))
-- 逗号 / 冒号 / 句号的 qual 分级
check_tri("tier ，之后 clause", gap_at("甲，乙", 2), tri(TIER.PUNCT, LV.CLAUSE, true))
check_tri("tier ：之后 colon", gap_at("甲：乙", 2), tri(TIER.PUNCT, LV.COLON, true))
check_tri("tier 。之后 sentence", gap_at("甲。乙", 2), tri(TIER.PUNCT, LV.SENTENCE, true))
-- 缩写保护：Dr. 的 qual 降为 normal（不是句末）
check_tri("tier Dr. 缩写降级", gap_at("Dr. Smith", 1), tri(TIER.FREE, LV.NORMAL, false))
check_tri("tier done. 真句末", gap_at("done. Smith", 1), tri(TIER.FREE, LV.SENTENCE, false))
-- ZWSP 与括号锁定：ZWSP 优先于 locked_gap（用户手工标记高于括号整体化）
check_tri("tier ZWSP 恒可断", gap_at("甲\226\128\139乙", 1), tri(TIER.FREE, LV.NORMAL, true))
check_tri("tier ZWSP 高于括号锁定", gap_at("甲\226\128\139乙", 1, { [2] = true }), tri(TIER.FREE, LV.NORMAL, true))
check_tri("tier 括号锁定内部不可断", gap_at("甲乙", 1, { [2] = true }), tri(TIER.NONE, LV.NORMAL, true))

-- ---------- 汇总 ----------
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
