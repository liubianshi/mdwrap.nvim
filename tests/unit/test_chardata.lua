-- 纯 Lua 单元测试：chardata.lua（分隔符集成员 + is_abbrev 缩写保护）
-- 运行：LUA_PATH 含 ./lua/?.lua，luajit tests/unit/test_chardata.lua

local chardata = require("mdwrap.chardata")

-- ---------- 极简断言框架 ----------
local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL " .. name)
    print(string.format("  got : %s", tostring(got)))
    print(string.format("  want: %s", tostring(want)))
  end
end

-- ============================================================
-- 句级分隔符集：半角 . ; ! ? 与全角并列（冒号已下放到 colon_sep，见下）
-- ============================================================
for _, t in ipairs({
  { 0x2e, "." }, { 0x3b, ";" }, { 0x21, "!" }, { 0x3f, "?" },
  { 0x3002, "。" }, { 0xff1b, "；" }, { 0xff01, "！" }, { 0xff1f, "？" }, { 0xff0e, "．" },
}) do
  check("sentence_sep[" .. t[2] .. "]", chardata.sentence_sep[t[1]], true)
end

-- ============================================================
-- 冒号级分隔符集：半角 : 与全角 ：（介于句末与逗号之间的中间级，不属句末）
-- ============================================================
for _, t in ipairs({ { 0x3a, ":" }, { 0xff1a, "：" } }) do
  check("colon_sep[" .. t[2] .. "]", chardata.colon_sep[t[1]], true)
  check(t[2] .. " not sentence", chardata.sentence_sep[t[1]], nil)
end

-- ============================================================
-- 子句分隔符集：半角 , 、全角 ，、顿号 、
-- ============================================================
for _, t in ipairs({ { 0x2c, "," }, { 0xff0c, "，" }, { 0x3001, "、" } }) do
  check("clause_sep[" .. t[2] .. "]", chardata.clause_sep[t[1]], true)
end
-- 逗号不应进句级集（tier-2 最后手段，不是句末）
check("comma not sentence", chardata.sentence_sep[0x2c], nil)
check("ideographic-comma not sentence", chardata.sentence_sep[0x3001], nil)

-- ============================================================
-- is_abbrev：缩写命中 / 真句末不命中 / 单字母首字母缩写
-- ============================================================
for _, w in ipairs({ "Dr.", "Mr.", "Mrs.", "Prof.", "e.g.", "i.e.", "etc.", "vs.",
  "No.", "Fig.", "Inc.", "Ltd.", "U.S.", "U.S.A.", "Ph.D.", "a.m.", "p.m.", "Jan.", "A.", "U." }) do
  check("is_abbrev " .. w, chardata.is_abbrev(w), true)
end
for _, w in ipairs({ "now.", "mat.", "word.", "park.", "today.", "12.", "" }) do
  check("not abbrev " .. (w == "" and "<empty>" or w), chardata.is_abbrev(w), false)
end
-- 大小写无关、尾部闭合标点剥除
check("is_abbrev case-insensitive DR.", chardata.is_abbrev("DR."), true)
check("is_abbrev strip closing (e.g.,)", chardata.is_abbrev("e.g.,"), true)
check("is_abbrev strip quote (etc.\")", chardata.is_abbrev('etc."'), true)

-- ---------- 汇总 ----------
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
