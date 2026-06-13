-- 模拟渲染插件在行内插入 2 列宽图标（如 render-markdown 的 highlight / 标注图标），
-- 验证「+add」宽度模型：图标净加 2 列，把本可塞进首行的「确」挤到次行。
-- 无图标时首行是「提示这段文字需要正确」(10 字=20)；有图标(+2)首行只到「正」(9 字+图标=20)。
-- 按内容定位（段首行以「提示」开头）→ 重折后首行仍以「提示」开头，图标稳定锚在段首，幂等成立。
return function(buf)
  local ns = vim.api.nvim_create_namespace("mdwrap_test_icon")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(lines) do
    if line:match("^提示") then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0,
        { virt_text = { { "##", "Special" } }, virt_text_pos = "inline" })
    end
  end
end
