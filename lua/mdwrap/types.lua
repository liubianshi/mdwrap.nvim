-- types.lua — 领域类型唯一来源（LuaCATS meta 文件）
--
-- 本文件**只承载类型声明**，运行时 `return {}`，**从不被任何模块 require**：
-- lua-language-server 按名字在整个工作区解析 ---@class / ---@alias，与 require 图无关。
-- 因此纯模块（layout / spacing / chardata）只在注释里**按名字引用**这些类型，
-- 绝不会因此引入对本文件的 require，「禁止 require vim」的硬约束纹丝不动。
--
-- 命名沿用参考文档（mrcjkb nvim-best-practices）的 `myplugin.X` 风格，前缀 `mdwrap.`。

---@alias mdwrap.AtomClass "cjk"|"word"|"space"|"zwsp"|"atomic"|"punct_no_break_before"|"punct_no_break_after"
---@alias mdwrap.AtomKind  "code"|"math"|"link"|"cite"|"shortcode"
---@alias mdwrap.CharAttr  "PUN_FORBIT_BREAK_AFTER"|"PUN_FORBIT_BREAK_BEFORE"|"CJK_PUN"|"CJK"|"OTHER"
---@alias mdwrap.WidthFn   fun(s:string):integer
---@alias mdwrap.BlockAction "wrap"|"preserve"

---@class mdwrap.Atom
---@field text string            原始字节（含被并入的 0 宽 conceal 标记 / 行尾 ZWSP）
---@field width integer          视觉宽度（CJK 计 2；conceal 段已扣除）
---@field class mdwrap.AtomClass
---@field atomic_kind? mdwrap.AtomKind  仅 class=="atomic" 时有意义（spacing 用）

---@class mdwrap.Block
---@field action mdwrap.BlockAction
---@field srow integer           0-indexed 起始行（闭区间）
---@field erow integer           0-indexed 结束行（闭区间）
---@field prefix_first? string   wrap 块首行前缀（引用/列表标记）
---@field prefix_rest? string    wrap 块续行前缀（等宽空格对齐）
---@field content_lines? string[] wrap 块剥前缀后的正文行

---@class mdwrap.Config            -- 解析后内部配置（字段非可选）
---@field width integer|nil
---@field wrap_sentence boolean
---@field keep_origin_wrap boolean
---@field lang "zh"
---@field cjk_english_spacing boolean
---@field respect_conceallevel boolean
---@field notify_on_error_node boolean
---@field set_formatexpr boolean    -- false 时 plugin/mdwrap.lua 不注册 formatexpr（把 gq 让回默认，交 conform 等接管）

---@class (partial) mdwrap.Opts: mdwrap.Config   -- setup() 的用户覆盖表，全字段可选

---@class (partial) mdwrap.FormatOpts: mdwrap.Opts -- format_buffer / format_lines 额外接受范围限定（(partial) 须沿继承链显式传递，否则父类字段被当作必填）
---@field row_start? integer
---@field row_end? integer
---@field bufnr? integer           -- format_lines 专用：仅用于取环境量（窗口 conceallevel / textwidth），不从中解析文本
---@field range? table             -- format_lines 专用：conform.Range（(1,0) 索引），入口换算为 row_start/row_end

---@class mdwrap.LayoutOpts
---@field width? integer
---@field prefix_first? string
---@field prefix_rest? string
---@field wrap_sentence? boolean
---@field width_fn? mdwrap.WidthFn

---@class mdwrap.AtomizeOpts
---@field width_fn? mdwrap.WidthFn
---@field conceal? boolean

---@class mdwrap.GoldenResult       -- test_runner.run 返回
---@field name string
---@field pass boolean
---@field idem? boolean
---@field semantic? boolean
---@field outside? boolean
---@field detail? string

return {}
