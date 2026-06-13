-- 纯 Lua 单元测试：layout.merge_lines_mapped 段映射 + wrap 的前缀宽度覆盖（无 Neovim）。
-- 运行：LUA_PATH 含 ./lua/?.lua，luajit tests/unit/test_mapping.lua
-- 覆盖 M5-A 的两个纯函数面：① 续行 extmark 坐标回推所依赖的 segs（lstart/lend/strip_lead）；
--                          ② 前缀被渲染插件改宽时，wrap 用 prefix_*_width 覆盖 avail 记账。

local layout = require("mdwrap.layout")

-- ---------- 极简断言框架 ----------
local pass, fail = 0, 0
local function fmt(v)
  if type(v) == "table" then
    local t = {}
    for _, x in ipairs(v) do t[#t + 1] = string.format("%q", tostring(x)) end
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

-- ============================================================
-- merge_lines_mapped：逻辑串与 segs
-- ============================================================

-- 英文两行：c/d 皆 OTHER ⇒ 空格连接；segs[2] 从空格之后起。
do
  local s, segs = layout.merge_lines_mapped({ "abc", "def" })
  check("en str", s, "abc def")
  check("en seg1", { segs[1].lstart, segs[1].lend, segs[1].strip_lead }, { 0, 3, 0 })
  check("en seg2", { segs[2].lstart, segs[2].lend, segs[2].strip_lead }, { 4, 7, 0 })
end

-- 中文两行：宽字符相接 ⇒ 无空格；segs[2].lstart = 「中文」字节数 6。
do
  local s, segs = layout.merge_lines_mapped({ "中文", "内容" })
  check("cjk str", s, "中文内容")
  check("cjk seg2", { segs[2].lstart, segs[2].lend, segs[2].strip_lead }, { 6, 12, 0 })
end

-- 续行前导空白：strip_lead 记被剥的字节数；段内 源偏移 = 逻辑偏移 − lstart + strip_lead。
do
  local s, segs = layout.merge_lines_mapped({ "abc", "   def" })
  check("strip str", s, "abc def")
  check("strip seg2", { segs[2].lstart, segs[2].lend, segs[2].strip_lead }, { 4, 7, 3 })
  -- 反算：line2 中 'd' 的源偏移 = 3（0-indexed），应映射到逻辑偏移 4（即 str 的 'd'）。
  local src = 3
  local logical = segs[2].lstart + (src - segs[2].strip_lead)
  check("strip map d", s:sub(logical + 1, logical + 1), "d")
end

-- 空续行：empty 标记，lstart==lend，不贡献内容。
do
  local s, segs = layout.merge_lines_mapped({ "abc", "   " })
  check("empty str", s, "abc")
  check("empty seg2 empty", segs[2].empty == true, true)
  check("empty seg2 span", { segs[2].lstart, segs[2].lend }, { 3, 3 })
end

-- merge_lines 薄包装 == merge_lines_mapped 第一返回值
check("wrapper eq", layout.merge_lines({ "中文", "内容" }), "中文内容")

-- ============================================================
-- wrap：前缀宽度覆盖（前缀字面宽 vs 渲染占宽 不一致时，按覆盖记账 avail）
-- ============================================================

local A = {
  { text = "甲", width = 2, class = "cjk" },
  { text = "乙", width = 2, class = "cjk" },
  { text = "丙", width = 2, class = "cjk" },
  { text = "丁", width = 2, class = "cjk" },
  { text = "戊", width = 2, class = "cjk" },
}
local id_w = function(s) return #s end

-- 基线：无覆盖，width=6 ⇒ 每行 3 个（首行 6，次行 丁戊=4）。
check("wrap baseline", layout.wrap(A, { width = 6, prefix_first = "", prefix_rest = "", width_fn = id_w }),
  { "甲乙丙", "丁戊" })

-- prefix_first_width 覆盖：首行 avail = 10−4 = 6 ⇒ 甲乙丙；次行无覆盖 avail=10 ⇒ 丁戊。
check("wrap first override", layout.wrap(A,
  { width = 10, prefix_first = "", prefix_rest = "", prefix_first_width = 4, width_fn = id_w }),
  { "甲乙丙", "丁戊" })

-- prefix_rest_width 覆盖：width=6，续行 avail=6−4=2 ⇒ 每续行仅 1 个 ⇒ {甲乙丙, 丁, 戊}。
check("wrap rest override", layout.wrap(A,
  { width = 6, prefix_first = "", prefix_rest = "", prefix_rest_width = 4, width_fn = id_w }),
  { "甲乙丙", "丁", "戊" })

-- ---------- 汇总 ----------
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
