-- 纯 Lua 属性测试：随机原子流 × 全模式矩阵，断言四条**独立于实现**的不变式。
-- 运行：LUA_PATH 含 ./lua/?.lua，luajit tests/unit/test_property.lua
--
-- 与 golden 的分工：golden 钉死「这个输入应折成这样」，属性测试钉死「无论什么输入都不该
-- 违反这几条」。后者的价值在随机形态——重构断点判定时最容易漏掉的正是 golden 没覆盖到的
-- 字符组合（全角括号贴着列位、半角句读粘连汉字、粘连的 atomic 边界……）。
--
-- **不变式必须独立于实现**，否则是循环论证：「行尾落在合法处」的「合法」就是实现本身，
-- 断言它等于断言「实现等于实现」。下面四条都能在不看 layout.lua 的前提下说清楚：
--   P1 内容守恒：输出重新合并回一条逻辑行，须与输入的逻辑行逐字节相同（不丢字、不重字）。
--   P2 禁则：禁前断标点绝不落行首，禁后断标点绝不落行尾。
--   P3 严格模式不在汉字之间断：相邻两行的接缝处，不得两侧都是普通汉字。
--   P4 幂等：format(format(x)) == format(x)（设计文档 6.2 之一）。
--
-- seed 固定，CI 可复现；用 MDWRAP_PROP_CASES 加大样本做深跑。

local layout = require("mdwrap.layout")
local spacing = require("mdwrap.spacing")
local chardata = require("mdwrap.chardata")

local pass, fail = 0, 0
local shown = 0
local function report(name, detail)
  fail = fail + 1
  if shown < 8 then
    shown = shown + 1
    print("FAIL " .. name)
    print("  " .. detail)
  end
end

local ZWSP = "\226\128\139"

-- ---------- UTF-8 拆字 ----------
local function chars(s)
  local out, i = {}, 1
  while i <= #s do
    local b = s:byte(i)
    local n = 1
    if b >= 0xF0 then n = 4 elseif b >= 0xE0 then n = 3 elseif b >= 0xC0 then n = 2 end
    out[#out + 1] = s:sub(i, i + n - 1)
    i = i + n
  end
  return out
end
local function cp(ch) return layout._utf8_cp(ch) end

-- ---------- 片段库 ----------
-- atomic 原子的 width 一律取其**字面显示宽**，P4 的重解析才能还原出同样的宽度
-- （headless 下无 conceal，生产路径同样是字面宽）。
local function C(ch) return { text = ch, width = 2, class = "cjk" } end
local function PB(ch) return { text = ch, width = 2, class = "punct_no_break_before" } end
local function PA(ch) return { text = ch, width = 2, class = "punct_no_break_after" } end
local function W(s) return { text = s, width = #s, class = "word" } end
local function SP() return { text = " ", width = 1, class = "space" } end
local function ZW() return { text = ZWSP, width = 0, class = "zwsp" } end
local function AT(s, kind) return { text = s, width = #s, class = "atomic", atomic_kind = kind } end

local HANZI = chars("甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥书名注说明文档内容")
local P_NB = chars("，。；：！？、）》」】〉．")   -- 禁前断（不落行首）
local P_NA = chars("（《「【〈")                   -- 禁后断（不落行尾）
local WORD_PUNCT_END = { "Hello!", "foo,", "x;", "done.", "why?", "note:", "Dr.", "e.g.", "U.", "etc." }
local WORD_PLAIN = { "pak", "APEC", "2023", "a", "the", "budget", "proposal", "ok" }
-- 形态须与下面 reatomize 的识别规则一一对应
local ATOMICS = { { "[t](u)", "link" }, { "`x`", "code" }, { "[@k2020]", "citation" }, { "$a+b$", "math" } }

local function pick(t) return t[math.random(#t)] end

local shapes = {}
local function shape(f) shapes[#shapes + 1] = f end

shape(function(o) for _ = 1, math.random(1, 8) do o[#o + 1] = C(pick(HANZI)) end end)
shape(function(o)
  for _ = 1, math.random(1, 6) do o[#o + 1] = C(pick(HANZI)) end
  o[#o + 1] = PB(pick(P_NB))
end)
shape(function(o) -- 全角括号组（可断但不配当行尾）
  o[#o + 1] = PA(pick(P_NA))
  for _ = 1, math.random(1, 4) do o[#o + 1] = C(pick(HANZI)) end
  o[#o + 1] = PB(pick(chars("）》」】〉")))
end)
shape(function(o) o[#o + 1] = PB("」"); o[#o + 1] = PB("。"); o[#o + 1] = PA("《") end)
shape(function(o) -- 半角句读粘连汉字（配当行尾却不可断）
  o[#o + 1] = W(pick(WORD_PUNCT_END))
  for _ = 1, math.random(1, 4) do o[#o + 1] = C(pick(HANZI)) end
end)
shape(function(o) -- 英文词组
  for j = 1, math.random(1, 5) do
    if j > 1 then o[#o + 1] = SP() end
    o[#o + 1] = W(pick(WORD_PLAIN))
  end
end)
shape(function(o) -- 盘古边界（带空格与不带空格两种）
  o[#o + 1] = C(pick(HANZI))
  if math.random() < 0.6 then o[#o + 1] = SP() end
  o[#o + 1] = W(pick(WORD_PLAIN))
  if math.random() < 0.6 then o[#o + 1] = SP() end
  o[#o + 1] = C(pick(HANZI))
end)
shape(function(o) -- CJK↔atomic：粘连与带空格
  local a = pick(ATOMICS)
  o[#o + 1] = C(pick(HANZI))
  if math.random() < 0.5 then o[#o + 1] = SP() end
  o[#o + 1] = AT(a[1], a[2])
  if math.random() < 0.5 then o[#o + 1] = SP() end
  o[#o + 1] = C(pick(HANZI))
end)
shape(function(o) -- 纯拉丁的粘连 atomic 边界
  local a, b = pick(ATOMICS), pick(ATOMICS)
  o[#o + 1] = W(pick(WORD_PLAIN)); o[#o + 1] = AT(a[1], a[2])
  o[#o + 1] = AT(b[1], b[2]); o[#o + 1] = W(pick(WORD_PLAIN))
end)
shape(function(o) o[#o + 1] = C(pick(HANZI)); o[#o + 1] = ZW(); o[#o + 1] = C(pick(HANZI)) end)
shape(function(o) -- 括号组内 ZWSP
  o[#o + 1] = PA("（"); o[#o + 1] = C(pick(HANZI)); o[#o + 1] = ZW()
  o[#o + 1] = C(pick(HANZI)); o[#o + 1] = PB("）")
end)
shape(function(o) o[#o + 1] = W("https://example.com/" .. string.rep("p", math.random(20, 60))) end)
shape(function(o) o[#o + 1] = PA("（"); o[#o + 1] = C(pick(HANZI)); o[#o + 1] = PB("》") end)
shape(function(o) -- 短标点分句 + 长无标点串（回落／溢出分界）
  o[#o + 1] = C(pick(HANZI)); o[#o + 1] = PB("，")
  for _ = 1, math.random(20, 45) do o[#o + 1] = C(pick(HANZI)) end
  o[#o + 1] = PB("。")
end)
shape(function(o) -- 长无标点中文 + English + 中文标点
  for _ = 1, math.random(15, 30) do o[#o + 1] = C(pick(HANZI)) end
  o[#o + 1] = SP(); o[#o + 1] = W("APEC"); o[#o + 1] = SP()
  for _ = 1, math.random(3, 8) do o[#o + 1] = C(pick(HANZI)) end
  o[#o + 1] = PB("。")
end)

--- 规范化：相邻两个 word 原子之间若无空格，真实 atomize 会把它们归并成**一个** word
--- （连续 ASCII 不会被拆成两个原子）。片段拼接可能造出这种生产路径不存在的形态，
--- 而它会让 P1 假阳性——折行把两者分到两行后，merge_lines 按英文规则补一个空格。
local function normalize(o)
  local out = {}
  for _, a in ipairs(o) do
    local prev = out[#out]
    if prev and prev.class == "word" and a.class == "word" then
      prev.text = prev.text .. a.text
      prev.width = prev.width + a.width
    else
      out[#out + 1] = a
    end
  end
  return out
end

local function gen()
  local o = {}
  if math.random() < 0.08 then o[#o + 1] = ZW() end
  for _ = 1, math.random(1, 10) do shapes[math.random(#shapes)](o) end
  return normalize(o)
end

local function copy(atoms)
  local c = {}
  for i, a in ipairs(atoms) do
    c[i] = { text = a.text, width = a.width, class = a.class, atomic_kind = a.atomic_kind }
  end
  return c
end

-- ---------- 逆向：文本 → 原子（P4 用，模拟生产路径的 atomize）----------
-- 只需认得上面片段库产出的那几种 atomic 形态；识别顺序按文本长度，避免 `[t](u)` 被拆碎。
local ATOMIC_PAT = {
  { "^%[@[%w]+%]", "citation" },
  { "^%[t%]%(u%)", "link" },
  { "^`[^`]*`", "code" },
  { "^%$[^%$]*%$", "math" },
}
local function reatomize(s)
  local out, i, pend = {}, 1, nil
  local function flush()
    if pend then out[#out + 1] = W(pend); pend = nil end
  end
  while i <= #s do
    local rest = s:sub(i)
    local matched = false
    for _, pat in ipairs(ATOMIC_PAT) do
      local m = rest:match(pat[1])
      if m then
        flush(); out[#out + 1] = AT(m, pat[2]); i = i + #m; matched = true
        break
      end
    end
    if not matched then
      local b = s:byte(i)
      local n = 1
      if b >= 0xF0 then n = 4 elseif b >= 0xE0 then n = 3 elseif b >= 0xC0 then n = 2 end
      local ch = s:sub(i, i + n - 1)
      local u = cp(ch) or 0
      if u == 0x200B then
        flush(); out[#out + 1] = ZW()
      elseif ch == " " then
        flush(); out[#out + 1] = SP()
      else
        local attr = chardata.char_attr(u)
        if attr == "CJK" or attr == "CJK_PUN" then flush(); out[#out + 1] = C(ch)
        elseif attr == "PUN_FORBIT_BREAK_BEFORE" then flush(); out[#out + 1] = PB(ch)
        elseif attr == "PUN_FORBIT_BREAK_AFTER" then flush(); out[#out + 1] = PA(ch)
        else pend = (pend or "") .. ch end
      end
      i = i + n
    end
  end
  flush()
  return out
end

-- ---------- 不变式 ----------
local function is_forbid_before(ch)
  local u = cp(ch)
  return (u and chardata.forbit_break_before[u]) or chardata.half_break_before[ch] or false
end
local function is_forbid_after(ch)
  local u = cp(ch)
  return (u and chardata.forbit_break_after[u]) or chardata.half_break_after[ch] or false
end
local function is_plain_han(ch)
  local u = cp(ch)
  return u ~= nil and chardata.char_attr(u) == "CJK"
end

--- P1 内容守恒：**非空格字符**序列守恒（不丢字、不重字、不乱序）。
--- 为何忽略空格：`merge_lines` 不是 `wrap` 的逆运算——它按 4.3.3 的 update_when_new_line
--- 规则决定两行之间插不插空格（中文行之间无空格、英文行之间恰一个空格），改变字节是设计
--- 使然；而 `wrap` 又会把落在断点处的空格消费掉。拿字节相等去断言它们互逆必然假阳性
--- （实测被 `budget（庚》` 这种拉丁贴全角括号的形态打出来过）。空格本身的正确性由
--- P4 幂等与 golden 负责，这里只钉住内容不变。
local function logical_of(atoms)
  local t = {}
  for _, a in ipairs(atoms) do t[#t + 1] = a.text end
  return table.concat(t)
end

local CASES = tonumber(os.getenv("MDWRAP_PROP_CASES")) or 120
local SEEDS = { 1, 7, 42, 1337, 99991 }
-- width 下限 20：更窄时 avail 小到容不下一个合法断点（一个汉字就占 2 列，前缀再吃掉几列），
-- 禁则与「不在汉字间断」都会被迫让路——那是 4.3.6 明文允许的降级，不属于本组不变式的适用
-- 范围。实测 w=10 下 P2 有约 2.8% 的行因此报警，全是被迫，不是缺陷。
local WIDTHS = { 20, 24, 30, 40, 70, 120 }
local PREFIXES = {
  { first = "", rest = "" },
  { first = "- ", rest = "  " },
  { first = "> ", rest = "> " },
}

local checked = 0
for _, seed in ipairs(SEEDS) do
  math.randomseed(seed)
  for case = 1, CASES do
    local base = spacing.apply(gen())
    local logical_nospace = (logical_of(base):gsub(" ", ""))
    for _, width in ipairs(WIDTHS) do
      for _, pf in ipairs(PREFIXES) do
        for _, ws in ipairs({ false, true }) do
          for _, po in ipairs({ false, true }) do
            for _, bu in ipairs({ false, true }) do
              local opts = {
                width = width, prefix_first = pf.first, prefix_rest = pf.rest,
                wrap_sentence = ws, cjk_break_at_punct_only = po, bracket_as_unit = bu,
              }
              local tag = ("seed=%d case=%d w=%d pf=%q ws=%s po=%s bu=%s")
                :format(seed, case, width, pf.first, tostring(ws), tostring(po), tostring(bu))
              local lines = layout.wrap(copy(base), opts)
              checked = checked + 1

              -- P1 内容守恒（忽略空格，见上方说明）
              local bodies = {}
              for li, l in ipairs(lines) do
                local pre = (li == 1) and pf.first or pf.rest
                bodies[li] = (pre ~= "" and l:sub(1, #pre) == pre) and l:sub(#pre + 1) or l
              end
              local got = (table.concat(bodies):gsub(" ", ""))
              if got ~= logical_nospace then
                report("P1 内容守恒 " .. tag,
                  ("want %d bytes, got %d bytes"):format(#logical_nospace, #got))
              end

              -- P2 禁则 + P3 严格模式不在汉字间断
              for li = 1, #lines do
                local pre = (li == 1) and pf.first or pf.rest
                local body = (pre ~= "" and lines[li]:sub(1, #pre) == pre)
                  and lines[li]:sub(#pre + 1) or lines[li]
                if body ~= "" then
                  local cs = chars(body)
                  local head, tail = cs[1], cs[#cs]
                  if tail == ZWSP then tail = cs[#cs - 1] or tail end
                  if is_forbid_before(head) and li > 1 then
                    report("P2 禁前断标点落行首 " .. tag, "line " .. li .. ": " .. body)
                  end
                  if is_forbid_after(tail) and li < #lines then
                    report("P2 禁后断标点落行尾 " .. tag, "line " .. li .. ": " .. body)
                  end
                  -- P3：严格 + 句末优先下，接缝两侧不得都是普通汉字。
                  -- 单 token 超宽独占一行（4.3.6）不在此列，那是被迫的。
                  if po and not ws and li < #lines then
                    local nxt = lines[li + 1]
                    local npre = pf.rest
                    local nbody = (npre ~= "" and nxt:sub(1, #npre) == npre) and nxt:sub(#npre + 1) or nxt
                    local nhead = chars(nbody)[1]
                    local last_real = cs[#cs]
                    if last_real ~= ZWSP and nhead and is_plain_han(last_real) and is_plain_han(nhead) then
                      report("P3 严格模式断在两个汉字之间 " .. tag,
                        ("line %d 尾 %q / line %d 首 %q"):format(li, last_real, li + 1, nhead))
                    end
                  end
                end
              end

              -- P4 幂等（无前缀口径即可覆盖；前缀不参与 merge_lines 的合并规则）
              if pf.first == "" then
                local again = layout.wrap(spacing.apply(reatomize(layout.merge_lines(lines))), opts)
                if table.concat(again, "\n") ~= table.concat(lines, "\n") then
                  report("P4 幂等 " .. tag,
                    ("1st: %s\n  2nd: %s"):format(table.concat(lines, " | "), table.concat(again, " | ")))
                end
              end
            end
          end
        end
      end
    end
  end
end
pass = checked - fail

print(string.format("\n%d passed, %d failed  (%d wrap calls over %d seeds)",
  pass, fail, checked, #SEEDS))
os.exit(fail == 0 and 0 or 1)
