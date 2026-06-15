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
---@alias mdwrap.BlockAction "wrap"|"preserve"|"table"
---@alias mdwrap.TableAlign  "default"|"left"|"right"|"center"

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
---@field content_prefix? string[] 各 content 行被 strip_prefix 剥掉的**前缀字符串**（与 content_lines 等长）。
---                                #prefix = 回推 extmark buffer 列的字节数；其文本用于量前缀区隐藏宽（M5-B）。
---@field table_rows? string[][]   action=="table" 专用：已 trim 的单元格文本矩阵（含表头，不含分隔行）。
---@field table_aligns? mdwrap.TableAlign[]  action=="table" 专用：各列对齐（由分隔行 align_left/align_right 子节点判定）。

---@class mdwrap.Config            -- 解析后内部配置（字段非可选）
---@field width integer|nil
---@field wrap_sentence boolean
---@field keep_origin_wrap boolean
---@field lang "zh"
---@field cjk_english_spacing boolean
---@field cjk_break_at_punct_only boolean  -- true 时中文仅在标点处断行（无标点超长子句字间断兜底）；false 退回传统 CJK 字间可断
---@field bracket_as_unit boolean  -- true 时括号配对作整体（能整组放下就不在括号内部断行；整组宽超一行才回退内部断）
---@field format_tables boolean  -- true 时管道表格按列视觉宽对齐补空格（不折行）；false 时表格整块 preserve 字节不动
---@field respect_conceallevel boolean
---@field respect_extmark_conceal boolean  -- false 时不读持久 conceal extmark（render-markdown/markview 等渲染插件的宽度增量）
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
---@field prefix_first_width? integer  -- 给定则取代 width_fn(prefix_first) 作为首行前缀占宽（前缀含 conceal/图标渲染时用，M5-B）
---@field prefix_rest_width? integer   -- 同上，续行前缀占宽
---@field wrap_sentence? boolean
---@field cjk_break_at_punct_only? boolean  -- 见 mdwrap.Config 同名字段；缺省（nil）按 false 处理（传统字间可断）
---@field bracket_as_unit? boolean  -- 见 mdwrap.Config 同名字段；缺省（nil）按 false 处理（不锁括号组）
---@field width_fn? mdwrap.WidthFn

--- 已翻译到逻辑串字节坐标的持久 extmark conceal 覆盖项（render-markdown/markview 等渲染插件注入）。
--- [sc,ec) 为隐藏字节区间（sc==ec 表示纯加宽锚点，无隐藏）；add 为 inline virt_text 图标
--- 与 conceal 替换字符的附加视觉宽，锚定在 sc。宽度模型：visual = 自然宽 − 隐藏(并集去重) + add。
---@class mdwrap.ExtmarkConceal
---@field sc integer    隐藏区间起（0-indexed 字节，含）
---@field ce integer    隐藏区间止（0-indexed 字节，不含）
---@field add integer   附加视觉宽（≥0），锚定在 sc

---@class mdwrap.AtomizeOpts
---@field width_fn? mdwrap.WidthFn
---@field conceal? boolean
---@field extmark_conceal? mdwrap.ExtmarkConceal[]  -- 逻辑串坐标的 extmark conceal 覆盖，与 tree-sitter conceal 合并去重

--- mdwrap-ignore 标记的扫描结果（ignore.scan 产出，ignore.apply 消费）。坐标一律 0-indexed。
---@class mdwrap.Ignore
---@field file boolean             整文件跳过（`mdwrap-ignore-file` 注释命中，或 frontmatter 顶层 `mdwrap: false`）
---@field ranges integer[][]       区域闭区间 {s,e} 列表（start/end 配对；未配对 start 延伸到末行）
---@field block_lnums integer[]    携带 `mdwrap-ignore`（块级）的标记行号
---@field line_lnums integer[]     携带 `mdwrap-ignore-line`（行级）的标记行号

---@class mdwrap.GoldenResult       -- test_runner.run 返回
---@field name string
---@field pass boolean
---@field idem? boolean
---@field semantic? boolean
---@field outside? boolean
---@field detail? string

return {}
