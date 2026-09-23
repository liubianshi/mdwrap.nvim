-- spacing.lua — 中英文空格（盘古之白）插入（纯函数）
--
-- 硬约束：禁止 require 任何 vim.* 模块，可在 luajit / lua5.1 下独立加载。
-- 在原子化之后、布局之前运行（设计文档 4.4）。
--
-- 规则：
--   * CJK 字符与相邻的拉丁字母/数字之间插入一个半角空格；
--   * CJK 与行内代码（atomic_kind == "code"）边界插入空格（用户裁定，见 DECISIONS.md 第 2 条）；
--   * 其余 atomic（链接/数学/citation/shortcode）边界、全角标点旁不插；
--   * 幂等：已有 space 原子处不重复插。

local M = {}

--- 该原子「朝向某侧」参与盘古空格的角色：'cjk' | 'latin' | 'code' | nil
---@param atom mdwrap.Atom
---@param side string 'last'（右边界）或 'first'（左边界）
local function role(atom, side)
  if atom.class == "cjk" then return "cjk" end
  if atom.class == "word" then
    local t = atom.text
    local ch = (side == "last") and t:sub(-1) or t:sub(1, 1)
    if ch:match("%w") then return "latin" end
    return nil
  end
  if atom.class == "atomic" and atom.atomic_kind == "code" then return "code" end
  return nil
end

--- 两原子之间是否构成盘古边界（CJK 与拉丁／行内代码相邻）。
--- 这里是该边界的**唯一定义**：spacing 用它决定在哪插空格，layout 用它认出「盘古间隙」
--- 并在严格模式下降级该处的断点。两者必须同源——否则原文已写好空格的文本与未写的文本
--- 会被区别对待，折行结果取决于源文件排没排过版。
---@param prev mdwrap.Atom
---@param cur mdwrap.Atom
function M.is_pangu_boundary(prev, cur)
  local l = role(prev, "last")
  local r = role(cur, "first")
  if not l or not r then return false end
  -- 仅 CJK 与（拉丁/代码）之间；两个拉丁、两个 CJK、code↔latin 均不算
  if l == "cjk" and (r == "latin" or r == "code") then return true end
  if r == "cjk" and (l == "latin" or l == "code") then return true end
  return false
end

--- 两原子之间是否需要插入盘古空格（边界成立，且两侧都还没有空格）。
---@param prev mdwrap.Atom
---@param cur mdwrap.Atom
local function need_space(prev, cur)
  if prev.class == "space" or cur.class == "space" then return false end
  return M.is_pangu_boundary(prev, cur)
end

--- 对原子列表施加盘古空格，返回新列表。
---@param atoms mdwrap.Atom[]
---@return mdwrap.Atom[]
function M.apply(atoms)
  ---@type mdwrap.Atom[]
  local out = {}
  for i, a in ipairs(atoms) do
    if i > 1 and need_space(atoms[i - 1], a) then
      out[#out + 1] = { text = " ", width = 1, class = "space" }
    end
    out[#out + 1] = a
  end
  return out
end

return M
