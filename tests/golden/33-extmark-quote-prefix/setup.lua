-- 模拟 render-markdown.nvim 对引用块的渲染：conceal 行首 `> `（2 列），不插 inline 图标
-- （引用竖条是 sign/overlay 装饰，不占行内宽）→ 前缀渲染宽 2 − 2 = 0。
-- 首行 + 每条续行都带 `> `，故 prefix_first_width 与 prefix_rest_width 都覆盖为 0。
-- 按内容定位（行首 `> `）→ 重折后每行仍带 `> `，delta 复现，幂等成立。
return function(buf)
  local ns = vim.api.nvim_create_namespace("mdwrap_test_quote")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(lines) do
    local s, e = line:find("^>%s")
    if s then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { end_row = row - 1, end_col = e, conceal = "" })
    end
  end
end
