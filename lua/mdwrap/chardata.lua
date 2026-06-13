-- chardata.lua — 字符排版属性码点表
--
-- 纯 Lua 模块：禁止 require 任何 vim.* ；必须能在 luajit / lua5.1 下独立加载。
-- 码点表原样移植自 REF/lib/App/Markdown/Utils.pm 的 _char_attr（保留逐码点注释）。
--
-- char_attr(u) 返回以下分类之一：
--   "PUN_FORBIT_BREAK_AFTER"  -- 禁止在此符号「后」断行（左引号/左括号类）
--   "PUN_FORBIT_BREAK_BEFORE" -- 禁止在此符号「前」断行（右引号/句读/右括号类）
--   "CJK_PUN"                 -- 中日韩标点符号
--   "CJK"                     -- 中日韩统一表意文字
--   "OTHER"                   -- 其他字符

local M = {}

-- 禁止其后断行（其后不可换行）：左引号、左括号类，约 21 个码点
M.forbit_break_after = {
  [0x2014] = true, -- —  Em dash
  [0x2018] = true, -- ‘  Left single quotation mark
  [0x201c] = true, -- “  Left double quotation mark
  [0x3008] = true, -- 〈 Left angle bracket
  [0x300a] = true, -- 《 Left double angle bracket
  [0x300c] = true, -- 「 Left corner bracket
  [0x300e] = true, -- 『 Left white corner bracket
  [0x3010] = true, -- 【 Left black lenticular bracket
  [0x3014] = true, -- 〔 Left tortoise shell bracket
  [0x3016] = true, -- 〖 Left white lenticular bracket
  [0x301d] = true, -- 〝 Reversed double prime quotation mark
  [0xfe59] = true, -- ﹙ Small left parenthesis
  [0xfe5b] = true, -- ﹛ Small left curly bracket
  [0xfe5d] = true, -- ﹝ Small left tortoise shell bracket
  [0xff04] = true, -- ＄ Fullwidth dollar sign
  [0xff08] = true, -- （ Fullwidth left parenthesis
  [0xff0e] = true, -- ． Fullwidth full stop
  [0xff3b] = true, -- ［ Fullwidth left square bracket
  [0xff5b] = true, -- ｛ Fullwidth left curly bracket
  [0xffe1] = true, -- ￡ Fullwidth pound sign
  [0xffe5] = true, -- ￥ Fullwidth yen sign
}

-- 禁止其前断行（其前不可换行）：右引号、句读、右括号类，约 21 个码点
M.forbit_break_before = {
  [0x2014] = true, -- —  Em dash
  [0x2019] = true, -- ’  Right single quotation mark
  [0x201d] = true, -- ”  Right double quotation mark
  [0x2026] = true, -- …  Horizontal ellipsis
  [0x2030] = true, -- ‰  Per mille sign
  [0x2032] = true, -- ′  Prime
  [0x2033] = true, -- ″  Double prime
  [0x203a] = true, -- ›  Single right-pointing angle quotation mark
  [0x2103] = true, -- ℃  Degree celsius
  [0x2236] = true, -- ∶  Ratio
  [0x3001] = true, -- 、 Ideographic comma
  [0xff0c] = true, -- ， Fullwidth comma
  [0x3002] = true, -- 。 Ideographic full stop
  [0xff09] = true, -- ） Fullwidth right parenthesis
  [0x3003] = true, -- 〃 Ditto mark
  [0x3009] = true, -- 〉 Right angle bracket
  [0x300b] = true, -- 》 Right double angle bracket
  [0x300d] = true, -- 」 Right corner bracket
  [0x300f] = true, -- 』 Right white corner bracket
  [0x3011] = true, -- 】 Right black lenticular bracket
  [0x3015] = true, -- 〕 Right tortoise shell bracket
}

-- 句级分隔符集（设计文档 4.3.4：触发 sentence 级断行偏好）
M.sentence_sep = {
  [0x3002] = true, -- 。
  [0xff1a] = true, -- ：
  [0xff0e] = true, -- ．
  [0xff1b] = true, -- ；
  [0xff01] = true, -- ！
  [0xff1f] = true, -- ？
}

-- 次级（子句）分隔符集（触发 clause 级断行偏好）
M.clause_sep = {
  [0xff0c] = true, -- ，
}

-- 半角「禁止其后断行」字符：' " (
M.half_break_after = { ["'"] = true, ['"'] = true, ["("] = true }
-- 半角「禁止其前断行」字符：, . ! ; : ? ] ) }
M.half_break_before = {
  [","] = true, ["."] = true, ["!"] = true, [";"] = true, [":"] = true,
  ["?"] = true, ["]"] = true, [")"] = true, ["}"] = true,
}

-- ----------------------------------------------------------------------------
-- UTF-8 工具（纯 Lua，无 vim、无 lua5.3 utf8 库依赖）
-- ----------------------------------------------------------------------------

--- 由 UTF-8 首字节得出该字符的字节数。
---@param b1 integer 首字节
---@return integer
function M.utf8_char_len(b1)
  if b1 >= 0xF0 then return 4 elseif b1 >= 0xE0 then return 3 elseif b1 >= 0xC0 then return 2 end
  return 1
end

--- 解码单个 UTF-8 字符串（已是单字符）为码点。
---@param ch string
---@return integer|nil
function M.utf8_cp(ch)
  local b1 = ch:byte(1)
  if not b1 then return nil end
  if b1 < 0x80 then return b1 end
  if b1 < 0xE0 then return (b1 - 0xC0) * 0x40 + (ch:byte(2) or 0x80) - 0x80 end
  if b1 < 0xF0 then
    return (b1 - 0xE0) * 0x1000 + ((ch:byte(2) or 0x80) - 0x80) * 0x40 + (ch:byte(3) or 0x80) - 0x80
  end
  return (b1 - 0xF0) * 0x40000 + ((ch:byte(2) or 0x80) - 0x80) * 0x1000
    + ((ch:byte(3) or 0x80) - 0x80) * 0x40 + (ch:byte(4) or 0x80) - 0x80
end

-- 判断码点是否落在 CJK 标点区段
local function is_cjk_pun(u)
  return (u >= 0x3000 and u <= 0x303F) -- CJK 符号和标点
    or (u >= 0xFF00 and u <= 0xFFEF)   -- 半角/全角形式
    or (u >= 0xFE50 and u <= 0xFE6F)   -- 小写变体
end

-- 判断码点是否落在 CJK 表意文字区段（含扩展 A–H 与兼容区、注音）
local function is_cjk(u)
  return (u >= 0x4E00 and u <= 0x9FFF)    -- CJK Unified Ideographs
    or (u >= 0x3400 and u <= 0x4DBF)      -- Extension A
    or (u >= 0x20000 and u <= 0x2A6DF)    -- Extension B
    or (u >= 0x2A700 and u <= 0x2B73F)    -- Extension C
    or (u >= 0x2B740 and u <= 0x2B81F)    -- Extension D
    or (u >= 0x2B820 and u <= 0x2CEAF)    -- Extension E
    or (u >= 0x2CEB0 and u <= 0x2EBEF)    -- Extension F
    or (u >= 0x30000 and u <= 0x3134F)    -- Extension G
    or (u >= 0x31350 and u <= 0x323AF)    -- Extension H
    or (u >= 0xF900 and u <= 0xFAFF)      -- CJK Compatibility Ideographs
    or (u >= 0x3100 and u <= 0x312f)      -- Bopomofo
    or (u >= 0x31a0 and u <= 0x31bf)      -- Bopomofo Extended
    or (u >= 0x2F800 and u <= 0x2FA1F)    -- CJK Compatibility Ideographs Supplement
end

M.is_cjk_pun = is_cjk_pun
M.is_cjk = is_cjk

--- 返回字符（Unicode 码点）的排版属性分类。
---@param u integer Unicode 码点
---@return string  分类标签
function M.char_attr(u)
  if M.forbit_break_after[u] then return "PUN_FORBIT_BREAK_AFTER" end
  if M.forbit_break_before[u] then return "PUN_FORBIT_BREAK_BEFORE" end
  if is_cjk_pun(u) then return "CJK_PUN" end
  if is_cjk(u) then return "CJK" end
  return "OTHER"
end

return M
