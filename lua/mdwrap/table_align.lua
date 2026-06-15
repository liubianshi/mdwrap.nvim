-- table_align.lua — 管道表格按列视觉宽对齐（纯函数）
--
-- 硬约束：禁止 require 任何 vim.* 模块，可在 luajit / lua5.1 下独立加载。
-- 只做几何：量列宽、按对齐补白、渲染。盘古空格 / inline 解析由集成层（init.lua）先做完，
-- 本模块拿到的已是规范化后的纯文本单元格矩阵。
--
-- 表格形状以分隔行为权威：列数 = #aligns；数据行少了补空、多了截断（与 GFM 一致）。
-- 列宽 = max(3, 该列所有单元格视觉宽)；下限 3 保证分隔行（含冒号）能正常渲染。
-- 居中余量为奇时多出的一格放右侧。默认列分隔行为纯 `-`，显式左/右/中才带冒号。

local M = {}

local rep = string.rep

--- 把单元格文本补到列宽。
---@param text string
---@param width integer            目标视觉宽
---@param align mdwrap.TableAlign
---@param width_fn mdwrap.WidthFn
---@return string
local function pad(text, width, align, width_fn)
  local pad_n = width - width_fn(text)
  if pad_n <= 0 then return text end
  if align == "right" then
    return rep(" ", pad_n) .. text
  elseif align == "center" then
    local l = math.floor(pad_n / 2)
    return rep(" ", l) .. text .. rep(" ", pad_n - l)
  else -- left / default
    return text .. rep(" ", pad_n)
  end
end

--- 构造分隔行单元格（`-` 撑满列宽，按对齐加冒号）。
---@param width integer
---@param align mdwrap.TableAlign
---@return string
local function delim_cell(width, align)
  if align == "left" then
    return ":" .. rep("-", width - 1)
  elseif align == "right" then
    return rep("-", width - 1) .. ":"
  elseif align == "center" then
    return ":" .. rep("-", width - 2) .. ":"
  else -- default
    return rep("-", width)
  end
end

--- 渲染对齐后的表格。
---@param rows string[][]          已 trim/规范化的单元格矩阵（rows[1] 为表头，不含分隔行）
---@param aligns mdwrap.TableAlign[]  各列对齐；其长度定义列数
---@param width_fn mdwrap.WidthFn
---@return string[]                输出行（含生成的分隔行，插在表头之后）
function M.render(rows, aligns, width_fn)
  local ncols = #aligns
  -- 列宽：下限 3（分隔行最少 `---` / `:-:` 可渲染）。
  local w = {}
  for c = 1, ncols do w[c] = 3 end
  for _, row in ipairs(rows) do
    for c = 1, ncols do
      local cw = width_fn(row[c] or "")
      if cw > w[c] then w[c] = cw end
    end
  end

  --- 拼一行：`| ` + 各单元格以 ` | ` 连接 + ` |`。
  ---@param cells string[]
  local function join(cells)
    return "| " .. table.concat(cells, " | ") .. " |"
  end

  local out = {}
  for i, row in ipairs(rows) do
    local cells = {}
    for c = 1, ncols do
      cells[c] = pad(row[c] or "", w[c], aligns[c], width_fn)
    end
    out[#out + 1] = join(cells)
    if i == 1 then -- 表头之后插分隔行
      local dcells = {}
      for c = 1, ncols do dcells[c] = delim_cell(w[c], aligns[c]) end
      out[#out + 1] = join(dcells)
    end
  end
  return out
end

return M
