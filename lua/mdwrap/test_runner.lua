-- test_runner.lua — golden 比对驱动（nvim --headless）
--
-- 用法：
--   单例：require('mdwrap.test_runner').run('tests/golden/01-basic-cjk')
--   全集：require('mdwrap.test_runner').run_all()  -- 跑完按通过/失败 cquit

local M = {}

local function read(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  return vim.fn.readfile(path)
end

local function lines_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function first_diff(a, b)
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then
      return i, a[i], b[i]
    end
  end
end

--- 在新缓冲区格式化给定输入行，返回输出行。
local function format_lines(input, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, input)
  vim.bo[buf].filetype = "markdown"
  require("mdwrap").format_buffer(buf, opts)
  local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

--- pandoc 语义保持（best-effort）：去空白与 ZWSP 后比较 plain 输出。
local function pandoc_semantic(input, output)
  if vim.fn.executable("pandoc") ~= 1 then return nil end -- 跳过
  local function norm(lines)
    local txt = table.concat(lines, "\n")
    local res = vim.fn.system({ "pandoc", "-f", "markdown", "-t", "plain", "--wrap=none" }, txt)
    res = res:gsub("[%s\226\128\139]", "") -- 去所有空白与 ZWSP(U+200B)
    return res
  end
  return norm(input) == norm(output)
end

--- 运行单个用例目录。返回 { name, pass, idem, semantic, detail }。
---@param case_dir string
---@return mdwrap.GoldenResult
function M.run(case_dir)
  local name = case_dir:gsub(".*/", "")
  local input = read(case_dir .. "/input.md")
  local expected = read(case_dir .. "/expected.md")
  if not input or not expected then
    return { name = name, pass = false, detail = "missing input/expected" }
  end
  local opts = {}
  if vim.fn.filereadable(case_dir .. "/opts.lua") == 1 then
    opts = dofile(case_dir .. "/opts.lua")
  end

  local got = format_lines(input, opts)
  local pass = lines_eq(got, expected)
  local detail
  if not pass then
    local i, g, e = first_diff(got, expected)
    detail = string.format("line %d:\n    got : %s\n    want: %s", i or -1, vim.inspect(g), vim.inspect(e))
  end

  -- 不变量 1：幂等
  local got2 = format_lines(got, opts)
  local idem = lines_eq(got2, got)

  -- 不变量 3：pandoc 语义保持（关 spacing 重跑，避免故意改文本）
  local sem_opts = vim.tbl_extend("force", opts, { cjk_english_spacing = false })
  local sem_out = format_lines(input, sem_opts)
  local semantic = pandoc_semantic(input, sem_out)

  -- 不变量 2：块外字节不变（用 preserve 类垃圾块前后包裹，验证包裹部分逐字节不变）。
  --   含奇数个 ``` 围栏的畸形用例（如 26-error-node）会与尾部 ``` 相互作用，豁免。
  local outside = nil
  local fence_count = 0
  for _, l in ipairs(input) do if l:match("^```") then fence_count = fence_count + 1 end end
  if fence_count % 2 == 0 then
    local HEAD = { "# 包裹用标题保持原样不应被折行处理处理处理处理处理处理处理", "" }
    local TAIL = { "", "```text", "包裹用代码块保持原样不应被折行处理处理处理处理处理处理处理处理", "```" }
    local wrapped = {}
    vim.list_extend(wrapped, HEAD)
    vim.list_extend(wrapped, input)
    vim.list_extend(wrapped, TAIL)
    local wout = format_lines(wrapped, opts)
    outside = true
    for j = 1, #HEAD do if wout[j] ~= HEAD[j] then outside = false end end
    for j = 1, #TAIL do if wout[#wout - #TAIL + j] ~= TAIL[j] then outside = false end end
  end

  return { name = name, pass = pass, idem = idem, semantic = semantic, outside = outside, detail = detail }
end

--- 跑全部 tests/golden/* 用例。
function M.run_all()
  local dirs = vim.fn.glob("tests/golden/*/", false, true)
  table.sort(dirs)
  local nfail, npass = 0, 0
  local idem_fail, sem_fail, out_fail = {}, {}, {}
  local pandoc_ran = false
  for _, d in ipairs(dirs) do
    d = d:gsub("/$", "")
    local r = M.run(d)
    local mark = r.pass and "PASS" or "FAIL"
    local extra = {}
    if r.idem == false then extra[#extra + 1] = "idem!"; idem_fail[#idem_fail + 1] = r.name end
    if r.semantic ~= nil then pandoc_ran = true end
    if r.semantic == false then extra[#extra + 1] = "sem!"; sem_fail[#sem_fail + 1] = r.name end
    if r.outside == false then extra[#extra + 1] = "outside!"; out_fail[#out_fail + 1] = r.name end
    print(string.format("%-4s %-22s %s", mark, r.name, table.concat(extra, " ")))
    if not r.pass then
      npass = npass
      nfail = nfail + 1
      if r.detail then print("     " .. r.detail:gsub("\n", "\n     ")) end
    else
      npass = npass + 1
    end
  end
  print(string.format("\n%d passed, %d failed (of %d)", npass, nfail, #dirs))
  print(string.format("invariant①idempotence failures: %d  %s", #idem_fail, table.concat(idem_fail, ",")))
  print(string.format("invariant②outside-bytes failures: %d  %s", #out_fail, table.concat(out_fail, ",")))
  if pandoc_ran then
    print(string.format("invariant③pandoc-semantic failures: %d  %s", #sem_fail, table.concat(sem_fail, ",")))
  else
    print("invariant③pandoc-semantic: skipped (pandoc not found)")
  end
  if nfail == 0 and #idem_fail == 0 and #sem_fail == 0 and #out_fail == 0 then
    vim.cmd("qall!")
  else
    vim.cmd("cquit 1")
  end
end

return M
