-- 模拟 render-markdown.nvim 对行内链接的渲染：隐藏 `[`、`](url)`，在链接文字前插 2 列宽图标。
-- 按内容定位（扫每行的 [text](url)），故重折后的 buffer 上仍对齐 → 满足幂等/块外不变量。
-- 链接原子自然宽 = `[文档](https://example.com/docs/guide)` = 38；隐藏 34（`[`=1 + `](url)`=33）；
-- 加图标 2 → 视觉宽 6（图标 2 + 文档 4），故链接得以贴着正文一起折行。
return function(buf)
  local ns = vim.api.nvim_create_namespace("mdwrap_test_link")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(lines) do
    local init = 1
    while true do
      local s, e, text = line:find("%[(.-)%]%((.-)%)", init)
      if not s then break end
      local r = row - 1
      -- conceal 开头的 `[`（0-indexed [s-1, s)）
      vim.api.nvim_buf_set_extmark(buf, ns, r, s - 1, { end_row = r, end_col = s, conceal = "" })
      -- conceal `](url)`（0-indexed [s+#text, e)：`]` 起到 `)` 止）
      vim.api.nvim_buf_set_extmark(buf, ns, r, s + #text, { end_row = r, end_col = e, conceal = "" })
      -- 链接文字前插 2 列宽 inline 图标（`##` 仅作占位，strdisplaywidth == 2）
      vim.api.nvim_buf_set_extmark(buf, ns, r, s, { virt_text = { { "##", "Special" } }, virt_text_pos = "inline" })
      init = e + 1
    end
  end
end
