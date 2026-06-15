-- 纯 Lua 单元测试：ignore.lua（无 Neovim）
-- 运行：LUA_PATH 含 ./lua/?.lua，luajit tests/unit/test_ignore.lua
-- 验证：
--   scan —— file（注释 / frontmatter）、ranges（配对 / 未配对延伸到 EOF）、block/line 行号、
--           大小写不敏感、内部空白宽松、frontmatter 仅首行 `---` 才成立。
--   apply —— file 全翻 preserve、区域相交翻 preserve、next-block 取首个 wrap/table、
--            行级整块（单行/非 wrap）preserve 与多行 wrap 拆块（续段 prefix_first 取 prefix_rest）。

local ig = require("mdwrap.ignore")

-- ---------- 极简断言框架 ----------
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print("FAIL " .. name)
    if detail then print("  " .. detail) end
  end
end
local function eq(name, got, want)
  check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end
-- 数组按行号集合比较（顺序敏感）。
local function arr_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- ============================================================
-- scan：file 级
-- ============================================================
do
  local s = ig.scan({ "正文", "<!-- mdwrap-ignore-file -->", "更多正文" })
  eq("file/comment", s.file, true)
end
do -- 大小写不敏感 + 内部空白宽松
  local s = ig.scan({ "<!--   MdWrap-Ignore-File   -->" })
  eq("file/case-space", s.file, true)
end
do -- frontmatter 顶层 mdwrap: false
  local s = ig.scan({ "---", "title: x", "mdwrap: false", "---", "正文" })
  eq("file/frontmatter", s.file, true)
end
do -- frontmatter false 大小写不敏感
  local s = ig.scan({ "---", "mdwrap:   FALSE", "---" })
  eq("file/frontmatter-case", s.file, true)
end
do -- 非首行的 --- 不构成 frontmatter ⇒ mdwrap:false 不在区间内 ⇒ 不命中
  local s = ig.scan({ "正文", "---", "mdwrap: false", "---" })
  eq("file/frontmatter-not-first", s.file, false)
end
do -- 缩进的 mdwrap: false 非顶层键 ⇒ 不命中
  local s = ig.scan({ "---", "  mdwrap: false", "---" })
  eq("file/frontmatter-indented", s.file, false)
end

-- ============================================================
-- scan：ranges
-- ============================================================
do
  local s = ig.scan({
    "a",                              -- 0
    "<!-- mdwrap-ignore-start -->",   -- 1
    "b",                              -- 2
    "<!-- mdwrap-ignore-end -->",     -- 3
    "c",                              -- 4
  })
  check("range/paired", #s.ranges == 1 and s.ranges[1][1] == 1 and s.ranges[1][2] == 3,
    "ranges=" .. (s.ranges[1] and (s.ranges[1][1] .. "," .. s.ranges[1][2]) or "nil"))
end
do -- 未配对 start 延伸到 EOF（#lines-1）
  local s = ig.scan({ "a", "<!-- mdwrap-ignore-start -->", "b", "c" })
  check("range/unpaired-start", #s.ranges == 1 and s.ranges[1][1] == 1 and s.ranges[1][2] == 3)
end
do -- 未配对 end 无害（无 range）
  local s = ig.scan({ "a", "<!-- mdwrap-ignore-end -->", "b" })
  eq("range/unpaired-end", #s.ranges, 0)
end

-- ============================================================
-- scan：block / line 行号
-- ============================================================
do
  local s = ig.scan({ "<!-- mdwrap-ignore -->", "p" })
  check("block/lnums", arr_eq(s.block_lnums, { 0 }) and #s.line_lnums == 0)
end
do
  local s = ig.scan({ "p", "<!-- mdwrap-ignore-line -->", "q" })
  check("line/lnums", arr_eq(s.line_lnums, { 1 }) and #s.block_lnums == 0)
end

-- ============================================================
-- apply：file 全翻 preserve
-- ============================================================
do
  local blocks = {
    { action = "wrap", srow = 0, erow = 1 },
    { action = "table", srow = 3, erow = 5 },
  }
  local out = ig.apply(blocks, { file = true, ranges = {}, block_lnums = {}, line_lnums = {} }, 6)
  check("apply/file", out[1].action == "preserve" and out[2].action == "preserve")
end

-- ============================================================
-- apply：区域相交翻 preserve（区外不动）
-- ============================================================
do
  local blocks = {
    { action = "wrap", srow = 0, erow = 0 },  -- 区外
    { action = "wrap", srow = 3, erow = 4 },  -- 区内（相交 [2,6]）
    { action = "wrap", srow = 8, erow = 9 },  -- 区外
  }
  local out = ig.apply(blocks, { file = false, ranges = { { 2, 6 } }, block_lnums = {}, line_lnums = {} }, 10)
  check("apply/region", out[1].action == "wrap" and out[2].action == "preserve" and out[3].action == "wrap")
end

-- ============================================================
-- apply：next-block 取「srow > m 的第一个 wrap/table 块」
-- ============================================================
do
  local blocks = {
    { action = "wrap", srow = 0, erow = 0 },  -- 标记之前，不动
    { action = "wrap", srow = 2, erow = 3 },  -- 标记(行1)之后第一个 ⇒ preserve
    { action = "wrap", srow = 5, erow = 6 },  -- 不动
  }
  local out = ig.apply(blocks, { file = false, ranges = {}, block_lnums = { 1 }, line_lnums = {} }, 7)
  check("apply/next-block", out[1].action == "wrap" and out[2].action == "preserve" and out[3].action == "wrap")
end

-- ============================================================
-- apply：行级——单行 wrap 块整块 preserve
-- ============================================================
do
  local blocks = { { action = "wrap", srow = 2, erow = 2, content_lines = { "x" }, content_prefix = { "" },
    prefix_first = "", prefix_rest = "" } }
  -- 标记在行1 ⇒ 受保护源行 L=2
  local out = ig.apply(blocks, { file = false, ranges = {}, block_lnums = {}, line_lnums = { 1 } }, 3)
  check("apply/line-singleline", #out == 1 and out[1].action == "preserve"
    and out[1].srow == 2 and out[1].erow == 2)
end

-- ============================================================
-- apply：行级——table 块整块 preserve（不内部拆）
-- ============================================================
do
  local blocks = { { action = "table", srow = 2, erow = 4 } }
  local out = ig.apply(blocks, { file = false, ranges = {}, block_lnums = {}, line_lnums = { 1 } }, 5)
  check("apply/line-table", #out == 1 and out[1].action == "preserve")
end

-- ============================================================
-- apply：行级——多行 wrap 块拆块（被护行首 ⇒ preserve + 其后续段子 wrap 块）
--   续段 prefix_first 取原块 prefix_rest（悬挂缩进语义）。
-- ============================================================
do
  local blocks = { {
    action = "wrap", srow = 2, erow = 4,
    prefix_first = "- ", prefix_rest = "  ",
    content_lines = { "L0", "L1", "L2" },
    content_prefix = { "- ", "  ", "  " },
  } }
  -- 受保护源行 L=2（块首行，标记在行1）
  local out = ig.apply(blocks, { file = false, ranges = {}, block_lnums = {}, line_lnums = { 1 } }, 5)
  check("apply/line-split-count", #out == 2,
    "got " .. #out .. " blocks")
  check("apply/line-split-preserve", out[1] and out[1].action == "preserve"
    and out[1].srow == 2 and out[1].erow == 2)
  check("apply/line-split-subwrap", out[2] and out[2].action == "wrap"
    and out[2].srow == 3 and out[2].erow == 4
    and out[2].prefix_first == "  "          -- 续段首行前缀取 prefix_rest
    and out[2].prefix_rest == "  "
    and arr_eq(out[2].content_lines, { "L1", "L2" }))
end

-- ============================================================
-- apply：行级——被护行在中间，拆成 前 wrap / 护行 preserve / 后 wrap 三段
-- ============================================================
do
  local blocks = { {
    action = "wrap", srow = 0, erow = 2,
    prefix_first = "", prefix_rest = "",
    content_lines = { "A", "B", "C" },
    content_prefix = { "", "", "" },
  } }
  -- 受保护源行 L=1（中间行）
  local out = ig.apply(blocks, { file = false, ranges = {}, block_lnums = {}, line_lnums = { 0 } }, 3)
  check("apply/line-mid-count", #out == 3, "got " .. #out)
  check("apply/line-mid-pre", out[1] and out[1].action == "wrap"
    and out[1].srow == 0 and out[1].erow == 0 and out[1].prefix_first == ""
    and arr_eq(out[1].content_lines, { "A" }))
  check("apply/line-mid-protected", out[2] and out[2].action == "preserve"
    and out[2].srow == 1 and out[2].erow == 1)
  check("apply/line-mid-post", out[3] and out[3].action == "wrap"
    and out[3].srow == 2 and out[3].erow == 2
    and arr_eq(out[3].content_lines, { "C" }))
end

-- ---------- 汇总 ----------
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
