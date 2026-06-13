-- conceal.lua — 读持久 conceal extmark（插件无关的渲染宽度真相源）
--
-- 状态：M5-A 实现。本文件是**唯一**新碰 extmark API 的地方，与 atoms.lua / blocks.lua
-- 同属 vim 依赖层（不受「禁 require vim」硬约束）。layout / spacing / chardata 仍零 vim 依赖。
--
-- ============================================================================
-- 为何读 extmark，而非绑定某个渲染插件
-- ============================================================================
-- 用户实际用 render-markdown.nvim 渲染中文 Markdown，将来可能换 markview.nvim。这类插件
-- **共同机制**是往 buffer 放**持久 extmark**：用 conceal 隐藏标记（`**`、链接 url、`$`、
-- 列表/引用前缀符），用 inline virt_text 插图标（链接图标、列表 bullet 图标）。两者一起
-- 改变屏幕实际显示宽度。mdwrap 折行要对齐屏幕，就得读出这些增量。
--
-- 读**所有 namespace**（-1）并按「是否带 conceal / inline virt_text」自动过滤——任何同机制
-- 渲染插件都覆盖，无需 allowlist 配置（用户裁定，见 DECISIONS）。
--
-- 与 tree-sitter conceal 的关系：tree-sitter 的 conceal 是 decoration provider 的**临时**
-- extmark，nvim_buf_get_extmarks **查不到**；render-markdown/markview 用**持久** extmark，
-- 查得到。两源基本不重叠，少数重叠（如插件也盖 `**`）由 atoms.lua 按字节并集去重。
--
-- ============================================================================
-- 坐标系
-- ============================================================================
-- 本文件产出的 Mark 用**原始 buffer (row, col)** 字节坐标（row 0-indexed，col 0-indexed 字节）。
-- 调用方（init.process_wrap）再用 block 的 prefix/merge 段映射翻译成逻辑串坐标喂 atomize。

local M = {}

--- 一条归一化的渲染增量标记。
--- [cs,ce) 为隐藏字节区间（cs==ce 表示纯加宽锚点，无隐藏）；add 为 inline virt_text 图标
--- 宽 + conceal 替换字符宽之和，锚定在 cs。
---@class mdwrap.Mark
---@field row integer  0-indexed buffer 行
---@field cs integer   0-indexed 起始字节列（含）
---@field ce integer   0-indexed 结束字节列（不含）
---@field add integer  附加视觉宽（≥0），锚定在 cs

--- 读取 [srow,erow]（0-indexed 闭区间）内的持久 conceal / inline-virt_text extmark，
--- 归一化为 Mark 列表（buffer 坐标）。
---
--- 过滤规则：
---   * details.conceal ~= nil（含 ""）            → 隐藏 [col,end_col)；替换字符宽计入 add。
---   * details.virt_text 且 virt_text_pos=="inline" → 图标宽计入 add，锚点 [col,col)。
---   * 跳过 conceal_lines（整行隐藏）/ sign / eol / overlay 等不改行内宽度的标记。
---
--- expected_lines（可选，conform 链式失同步保护）：给定时逐行比对 buffer 实文与之，
---   不符的行丢弃其 extmark——前序 formatter 改过文本时，buffer 树 / extmark 相对传入
---   lines 是旧的，读它会错位。
---@param bufnr integer
---@param srow integer  0-indexed 起始行（含）
---@param erow integer  0-indexed 结束行（含）
---@param expected_lines string[]? 全文档行（按绝对 row 索引：expected_lines[row+1]）
---@return mdwrap.Mark[]
function M.gather(bufnr, srow, erow, expected_lines)
  ---@type mdwrap.Mark[]
  local marks = {}
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return marks end
  local ok, raw = pcall(vim.api.nvim_buf_get_extmarks, bufnr, -1,
    { srow, 0 }, { erow, -1 }, { details = true })
  if not ok or not raw then return marks end

  -- 失同步保护用：一次性取范围内 buffer 行，逐 mark 比对（避免每 mark 一次 API 往返）。
  local buf_lines = expected_lines and vim.api.nvim_buf_get_lines(bufnr, srow, erow + 1, false) or nil

  for _, m in ipairs(raw) do
    local row, col, d = m[2], m[3], m[4]
    if d then
      -- 失同步保护：该 buffer 行与传入 lines 不一致 → 弃该行所有 extmark。
      local valid = true
      if buf_lines and expected_lines then -- and expected_lines 仅为类型收窄；buf_lines 非空即蕴含其非空
        if buf_lines[row - srow + 1] ~= expected_lines[row + 1] then valid = false end
      end

      if valid then
        local cs, ce, add = col, col, 0

        -- conceal：隐藏一段字节区间（end_col），conceal 为非空替换字符时其显示宽计入 add。
        ---@diagnostic disable-next-line: undefined-field  -- conceal_lines 是较新 nvim extmark 字段，本机 LuaLS vim 类型未收录
        if d.conceal ~= nil and not d.conceal_lines then
          local er = d.end_row or row
          local ec = d.end_col or col
          if er == row and ec > col then
            cs, ce = col, ec
          end -- 跨行 conceal（er~=row）对行内宽度无明确语义，按纯锚点处理（不隐藏）
          if type(d.conceal) == "string" and d.conceal ~= "" then
            add = add + vim.fn.strdisplaywidth(d.conceal)
          end
        end

        -- inline virt_text：在 col 处插图标，净加其显示宽。
        if d.virt_text and d.virt_text_pos == "inline" then
          for _, chunk in ipairs(d.virt_text) do
            add = add + vim.fn.strdisplaywidth(chunk[1] or "")
          end
        end

        if ce > cs or add > 0 then
          marks[#marks + 1] = { row = row, cs = cs, ce = ce, add = add }
        end
      end
    end
  end
  return marks
end

return M
