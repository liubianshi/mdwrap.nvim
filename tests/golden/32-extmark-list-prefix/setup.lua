-- 模拟 render-markdown.nvim 把任务框 `- [ ] ` 渲成单个复选框图标：
-- conceal `- [ ] `（6 列）+ 行首插 2 列图标 → 前缀渲染宽 6 − 6 + 2 = 2。
-- 这是「前缀区净增量」路径：mark 落在 col < removed(=6) 的前缀区，聚成 prefix_first_width=2。
-- 续行是 6 空格悬挂缩进（无 extmark，prefix_rest_width 默认 6）。
-- 按内容定位（行首 `- [ ] `）→ 重折后首行仍以其开头，幂等成立。
return function(buf)
  local ns = vim.api.nvim_create_namespace("mdwrap_test_task")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(lines) do
    if line:find("^%- %[.%] ") then
      local r = row - 1
      vim.api.nvim_buf_set_extmark(buf, ns, r, 0, { end_row = r, end_col = 6, conceal = "" })       -- 隐藏 `- [ ] `
      vim.api.nvim_buf_set_extmark(buf, ns, r, 0, { virt_text = { { "##", "Special" } }, virt_text_pos = "inline" })
    end
  end
end
