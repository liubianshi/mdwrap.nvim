-- 纯 Lua 单元测试：table_align.lua（注入 stub 宽度，无 Neovim）
-- 运行：LUA_PATH 含 ./lua/?.lua，luajit tests/unit/test_table_align.lua
-- 验证：列宽取该列最大视觉宽（下限 3）、四种对齐补白、分隔行冒号、居中奇余放右。

local ta = require("mdwrap.table_align")

-- ---------- 极简断言框架 ----------
local pass, fail = 0, 0
local function fmt(v)
  if type(v) == "table" then
    local t = {}
    for _, x in ipairs(v) do t[#t + 1] = string.format("%q", x) end
    return "{\n  " .. table.concat(t, ",\n  ") .. "\n}"
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

-- stub 宽度：UTF-8 多字节（CJK/全角）计 2，ASCII 计 1。
local function width_fn(s)
  local w, i, n = 0, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b >= 0xF0 then i = i + 4; w = w + 2
    elseif b >= 0xE0 then i = i + 3; w = w + 2
    elseif b >= 0xC0 then i = i + 2; w = w + 2
    else i = i + 1; w = w + 1 end
  end
  return w
end

-- ============================================================
-- 四种对齐 + 列宽 + 居中奇余放右
-- 列宽：col1 左=12（长一点的内容），col2 居中=8（中文 ABC），col3 右=6（右对齐），col4 默认=4（默认/你好）
-- ============================================================
local rows = {
  { "左", "居中列", "右对齐", "默认" },
  { "a", "中文 ABC", "1", "x" },
  { "长一点的内容", "短", "12345", "你好" },
}
local aligns = { "left", "center", "right", "default" }
check("four-aligns", ta.render(rows, aligns, width_fn), {
  "| 左           |  居中列  | 右对齐 | 默认 |",
  "| :----------- | :------: | -----: | ---- |",
  "| a            | 中文 ABC |      1 | x    |",
  "| 长一点的内容 |    短    |  12345 | 你好 |",
})

-- 居中奇数余量多的一格放右：列宽 4（abcd），"x" 余 3 ⇒ 左 1 右 2 ⇒ " x  "
check("center-odd-right", ta.render({ { "x" }, { "abcd" } }, { "center" }, width_fn), {
  "|  x   |",
  "| :--: |",
  "| abcd |",
})

-- 列宽下限 3：单字符列分隔行仍可渲染（默认 ---、居中 :-:）
check("min-width-3", ta.render({ { "a", "b" } }, { "default", "center" }, width_fn), {
  "| a   |  b  |",
  "| --- | :-: |",
})

-- 数据行少于列数 ⇒ 缺列补空；多于列数 ⇒ 截断
check("ragged-rows", ta.render({ { "h1", "h2" }, { "only" }, { "x", "y", "extra" } },
  { "default", "default" }, width_fn), {
  "| h1   | h2  |",
  "| ---- | --- |",
  "| only |     |",
  "| x    | y   |",
})

-- ---------- 汇总 ----------
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
