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

-- ---------- 汇总 ----------
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
