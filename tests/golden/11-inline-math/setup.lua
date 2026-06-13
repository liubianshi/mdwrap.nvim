-- 模拟 render-markdown.nvim 对行内数学 $...$ 的渲染：conceal 两个 `$` 定界符。
-- 取代旧的 atoms.lua BUILTIN_CONCEAL_TYPES 特例（已删除，$ 统一走 extmark 路径，见 DECISIONS #4）。
-- expected.md 字节不变：`$\alpha + \beta$` 视觉宽 14（内部 14，两个 $ 各 conceal）。
-- 按内容定位（扫每行的 $...$）→ 重折后仍对齐，幂等成立。
return function(buf)
  local ns = vim.api.nvim_create_namespace("mdwrap_test_math")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(lines) do
    local init = 1
    while true do
      local s, e = line:find("%$[^$]*%$", init)
      if not s then break end
      local r = row - 1
      vim.api.nvim_buf_set_extmark(buf, ns, r, s - 1, { end_row = r, end_col = s, conceal = "" })     -- 开 `$`
      vim.api.nvim_buf_set_extmark(buf, ns, r, e - 1, { end_row = r, end_col = e, conceal = "" })     -- 闭 `$`
      init = e + 1
    end
  end
end
