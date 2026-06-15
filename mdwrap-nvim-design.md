# mdwrap.nvim：设计与实现指令

本文档是完整的实现指令，面向 Claude Code。目标是实现一个 Neovim Lua 插件，替代现有的 Perl 工具 mdwrap，为 Pandoc／Quarto 方言的 Markdown 提供 conceal 感知的中文硬折行。请完整阅读本文档后再开始动手，实现顺序见第 7 节。

---

## 0. 给实现者的元指令

1. **禁止联网**。所有参考资料都在本地。不要搜索、不要 fetch 任何 URL。
2. **参考仓库**：mdwrap 的 Perl 源码仓库在本地。以下用 `REF/` 代指其根目录。开始前先用 `ls` 确认实际位置（优先检查 `./reference/mdwrap/`，其次 `../mdwrap/`，找不到就问用户），确认后将本文档中所有 `REF/` 路径替换为实际路径来阅读。
3. **参考的性质**：REF 是「行为规范的来源」，不是「架构的范本」。从中提取的是字符表、正则、偏好参数、块分类等领域知识；其字符级状态机架构正是本次重写要废弃的东西，任何情况下都不要照搬其控制流。
4. **验证 tree-sitter 行为时用本地实验**：用 `nvim --headless` 加载示例文本、打印 `vim.treesitter` 解析树（`:InspectTree` 的编程等价物，即 `node:sexpr()`）来确认节点类型，不要凭记忆假设语法树形状。本文档第 4 节给出的节点名是预期值，以本地实验为准，发现不符时在代码注释中记录实测结果。
5. **目标效果以第 6 节测试文档为准**。第 4 节的算法描述是推荐实现策略；若实现策略与描述有出入但全部测试通过，以测试为准。测试本身不许为迁就实现而削弱。

---

## 1. 背景、目标与非目标

### 1.1 背景

用户在 Neovim 中写 Pandoc／Quarto 方言的中文 Markdown。Neovim 的 conceal 机制会在显示时隐藏部分语法标记（如 `**`、行内代码反引号、链接的 URL 部分），因此按字节或字符宽度折行的通用工具会造成视觉上参差不齐。现有 Perl 工具 mdwrap 解决了这个问题，但其手写的块级解析器和十一层 handler 字符状态机难以维护、容易出错。

### 1.2 目标（v1 范围）

1. 提供 `formatexpr`，使 `gq` 系列操作按本插件逻辑折行。
2. conceal 感知的视觉宽度计算，与 Neovim 实际显示严格一致。
3. 中文排版规则：禁则处理（标点禁止行首行尾）、句末优先断行、合并行时中文字符间不引入空格。
4. 正确处理 Pandoc／Quarto 结构：YAML、代码块、数学块、表格、标题、链接引用定义不折行；列表悬挂缩进；嵌套引用前缀；callout；`:::` 围栏 div；citation 与 shortcode 作为不可断原子。
5. 可选的中英文之间插入空格（盘古之白）。
6. 幂等：格式化两次与一次结果相同。
7. 最小差异：只改动目标块内的换行与空白，块外字节不变。

### 1.3 非目标（v1 明确不做）

- mdwrap 的 `--tonewsboat` 模式（newsboat 阅读格式转换）。
- 插入模式实时折行（`formatexpr` 在插入模式调用时直接返回 1 回退默认行为）。
- `lang=en` 的英文句末规则集（保留配置接口，v1 只实现 zh）。
- 对格式错误 Markdown 的修复（错误节点所在块整体跳过不动）。

---

## 2. 参考文件索引（REF 下相对路径）

按以下顺序阅读。每条注明「提取什么」与「忽略／警惕什么」。

### 2.1 `REF/README.md`

提取：工具的设计动机与功能清单（conceal 对齐、中英文空格、悬挂缩进、嵌套引用、callout）。这是用户对目标效果的原始陈述。

### 2.2 `REF/lib/App/Markdown/Utils.pm`

**这是最有价值的参考文件**。提取：

- `_char_attr` 函数（约 150 行起）：完整的字符分类码点表，包括「禁止其后断行」标点表（左引号、左括号类，约 21 个码点）、「禁止其前断行」标点表（右引号、句读、右括号类，约 21 个码点）、CJK 标点区段、CJK 表意文字区段（含扩展 A–H）。**将这些码点表原样移植**为 Lua 模块（建议 `lua/mdwrap/chardata.lua`），保留每个码点的注释。这是禁则处理的事实标准来源。
- `indent` 函数：列表项前缀的识别正则（bullet `[-•*+]`、有序 `\d+\.`、任务项 `[x]`、定义列表 `: `）及「续行前缀＝引用前缀＋列表标记等宽空格」的悬挂缩进语义。v2 实现中前缀主要从 tree-sitter 结构计算，但任务项与定义列表的处理语义以此为准。
- `format_quote_line`：引用前缀规范化规则（连续 `>` 统一为 `> ` 形式；引用符后四个及以上空格视为引用内缩进代码块）。

忽略：`is_table_line` 等行级正则判断函数，v2 由 tree-sitter 节点类型替代。

### 2.3 `REF/lib/App/Markdown/Text.pm`

提取（只取参数与语义，不取控制流）：

- 常量块（文件头部 `use constant`）：`DEFAULT_LINE_WIDTH = 80`、`SUPPORT_SHORTER_LINE = 6`、零宽空格字符。
- `%LANG_CONFIG` 的 zh 配置：句子结束正则 `[），。：．；！？,.;:!?]["')」）”’]?$`、句级分隔符集 `。：．；！？`、次级分隔符集 `，`。
- `support_shorter_line` 函数：短行容忍度的三档取值，见本文档 4.3.4 节的清晰化重述。
- `_sentence_end` 函数：判断「当前行是否止于完整句子」的语义，注意其中对行尾 ASCII 字符的特殊处理（行尾是半角字符时，只有该行最后 30 字符之后全为 ASCII 才不算句末，意在避免把英文句中的 `.` 误判为中文语境的句末）。这个启发式可以简化，但 golden 用例 04 的行为要保持。
- `update_when_new_line` 函数：**合并行规则的权威来源**。换行符两侧的合并语义：下一行首字符是宽字符（CJK 或全角标点）且当前行末是空、空格或非 OTHER 类字符时，换行符直接删除不留空格；当前行末是标点类（PUN）时同样直接删除；其余情况换行符变为一个空格。
- `_clean_input_text`：预处理规则（统一 `\r\n`、去行首尾空白、压缩三连以上空行为两个）。

警惕：`_process_characters` 的十一层 handler 优先级链与 word／sentence／line 三缓冲区设计是本次重写废弃的对象，**不要以任何形式复刻该控制流**。`_generate_output` 是死代码（与 `_post_processing` 重复），忽略。

### 2.4 `REF/lib/App/Markdown/Inline.pm`

提取（只取「哪些行内结构、conceal 多少」，不取探针闭包机制）：

- `` ` `` 行内代码：整体处理，conceal 掉两个反引号定界符（宽度各 1）。原实现允许行内代码跨行（`wrap => 1`），v2 改为**不可断原子**，理由见 4.2.3。
- `*` 强调：`*`／`**`／`***` 定界符全部 conceal，定界符长度 1–3。允许在强调内容内部断行（强调是可跨行结构）。
- `$` 行内数学：conceal 为 0（定界符显示），整体为不可断原子。
- `@` citation：识别 `@key` 形式。**注意第 110 行附近有 bug**：`return if $right_char = m/[@\s\n]/` 用了赋值 `=` 而非匹配 `=~`，该分支从未按预期工作，其具体行为不构成行为规范，**不要复刻**。v2 中 citation 的权威定义见 4.2.3。
- `[` 三种链接：内联链接 `[text](url)`、wiki 链接 `[[target|display]]`、引用式链接 `[text][ref]`。conceal 宽度的计算语义统一为：`总显示宽度 −（display 文本宽度 ＋ 2）`，即视觉上只剩 `[display]` 一对方括号加显示文本。v2 中链接整体为不可断原子。

### 2.5 `REF/lib/App/Markdown/Handler.pm`

提取（只取块分类清单与各块的处理决策，不取分发链）：

- 用 `grep -n '^sub ' REF/lib/App/Markdown/Handler.pm` 得到块类型全集：yaml_header、quote、pandoc_div、math、code_block（围栏）、line_code_block（四空格缩进）、simple_table_line、pandoc_table_simple、pandoc_table_other、header_setext、header_atx、comment_line_as_sep（HTML 注释行）、linkref_line_as_sep、line_can_sep_paragraph（列表／链接列表／定义列表起始）。tonewsboat_* 系列属非目标，跳过。
- `quote` 函数（约 616 行起）：嵌套引用的前缀累积方式，以及 **callout 规则**：引用内容匹配 `[!NAME]` 时，该 callout 标题行独占一行、不与后续内容合并折行。
- 每类块的处理决策归纳为两类：「原样保留」（yaml、代码块、数学块、表格、标题、HTML 注释、linkref 定义、`:::` 围栏行）与「折行但有前缀规则」（普通段落、列表项、引用、callout 正文）。这个分类直接对应 4.1 节的块行为表。

警惕：`Wrap.pm` 主循环里 prefix 比较与 block 切换的隐式状态逻辑不要复刻；v2 中块边界由 tree-sitter 给出。

### 2.6 `REF/lib/App/Markdown/Wrap.pm` 与 `REF/script/mdwrap`

提取：CLI 选项清单及默认值，映射为插件配置（见第 5 节）：`line-width=80`、`wrap-sentence=0`、`keep-origin-wrap=0`、`lang=zh`。其余忽略。

### 2.7 `REF/lib/App/Markdown/Block.pm`、`REF/lib/App/Markdown/Text/State.pm`

整体忽略。这两个文件是旧架构的数据结构，新架构无对应物。

---

## 3. 总体架构

### 3.1 设计原则

1. **解析、原子化、布局三层分离**。解析（块结构与行内结构）交给 tree-sitter；原子化层把行内树转换为「不可再分单元＋视觉宽度」的扁平列表；布局层是纯函数，输入原子列表与选项、输出行列表，不接触任何 `vim.*` API。
2. **宽度函数依赖注入**。布局层通过参数接收 `width_fn`，生产环境注入基于 `vim.fn.strdisplaywidth` 与 conceal 元数据的实现，纯单元测试注入查表 stub。这是测试策略的基石。
3. **最小差异**。格式化的单位是块；目标范围外的块、以及「原样保留」类块，输出与输入字节相同。

### 3.2 插件目录结构

```
mdwrap.nvim/
├── lua/mdwrap/
│   ├── init.lua          -- setup()、formatexpr 入口、范围→块映射
│   ├── blocks.lua        -- tree-sitter 块级切分与前缀计算
│   ├── atoms.lua         -- 行内树 → 原子列表；conceal 宽度
│   ├── layout.lua        -- 断行核心（纯 Lua，禁止 require 任何 vim 模块）
│   ├── spacing.lua       -- 中英文空格插入（纯 Lua）
│   ├── chardata.lua      -- 从 REF/lib/App/Markdown/Utils.pm 移植的码点表（纯 Lua）
│   └── config.lua        -- 默认配置与校验
├── plugin/mdwrap.lua     -- FileType autocmd：markdown/quarto/pandoc 设置 formatexpr
├── tests/
│   ├── unit/             -- layout、spacing、chardata 的纯 Lua 测试
│   ├── golden/           -- 见 6.3
│   ├── run_unit.sh       -- 纯测试：busted 或 plain lua 断言
│   └── run_golden.sh     -- nvim --headless 驱动 golden 比对
└── README.md
```

`layout.lua`、`spacing.lua`、`chardata.lua` 三个文件必须能在无 Neovim 的纯 Lua 解释器（lua5.1／luajit）下加载与测试。CI 不可用时，两个 run 脚本必须能在本地一键运行。

---

## 4. 模块规格

### 4.1 blocks.lua：块级切分

**输入**：buffer 句柄＋行范围（来自 formatexpr 的 `v:lnum`、`v:count`）。
**输出**：块描述列表，每项含 `{ kind, start_row, end_row, prefix_first, prefix_rest, action }`，其中 `action ∈ { "wrap", "preserve" }`。

实现要点：

1. 取 `vim.treesitter.get_parser(bufnr, 'markdown')`，调用 `parser:parse(true)` 确保注入的 `markdown_inline` 树可用。
2. 把请求的行范围**扩展到完整块边界**：对范围内每一行找其所属的顶层可格式化块，处理单位永远是完整块。`gqip`、`gqq`、可视选区 `gq` 都归结到这一步。
3. 块行为表（节点名以本地实验为准）：

| tree-sitter 节点 | action | 说明 |
|---|---|---|
| `paragraph` | wrap | 主要工作对象 |
| `list_item` 内的 `paragraph` | wrap | `prefix_first` 为空（标记由原文保留），`prefix_rest` 为列表标记等宽空格；多级列表逐层累加 |
| `block_quote` 内的 `paragraph` | wrap | 前缀逐层累加 `> `；引用前缀规范化遵循 `REF/lib/App/Markdown/Utils.pm` 的 `format_quote_line` |
| `fenced_code_block`、缩进代码块 | preserve | |
| `minus_metadata`／`plus_metadata`（YAML／TOML 头） | preserve | |
| `pipe_table` | table（`format_tables=true`，默认）/ preserve | 不折行，按列视觉宽对齐补空格；对齐由分隔行 `align_left`/`align_right` 子节点判定。`format_tables=false` 时整块 preserve |
| `atx_heading`、`setext_heading` | preserve | |
| `link_reference_definition` | preserve | |
| `html_block`（含 HTML 注释） | preserve | |
| 数学块 `$$...$$` | preserve | 若 TS 无独立节点则按段落内容以 `$$` 开头结尾识别 |

4. Pandoc 方言补充规则（tree-sitter 不认识、按文本特征在块层处理）：
   - 行首匹配 `^:::+` 的行（围栏 div 开闭）：preserve，且其前后内容分属不同块。
   - 引用块内首行匹配 `\[![^\]\s]+\]` 的（callout 标题行）：该行独立成块 preserve，正文从下一行起算。
   - 整段落为 `{{< ... >}}` 的 shortcode 块：preserve。
5. 块内含 TS `ERROR` 节点时整块 preserve，并通过 `vim.notify` 一次性提示（可配置关闭）。

### 4.2 atoms.lua：原子化与视觉宽度

**输入**：一个 wrap 块的文本与对应 `markdown_inline` 子树。
**输出**：原子数组，每项 `{ text, width, class, break_before }`。`class` 取值：`cjk`（单个 CJK 字符）、`punct_no_break_before`、`punct_no_break_after`、`word`（连续非 CJK 非空白串）、`atomic`（不可断行内结构）、`space`。

#### 4.2.1 conceal 宽度的权威来源

视觉宽度的定义：`vim.fn.strdisplaywidth(text)` 减去其中被 conceal 隐藏部分的显示宽度。被隐藏部分由 tree-sitter 高亮查询的 conceal 元数据决定：

```lua
local query = vim.treesitter.query.get('markdown_inline', 'highlights')
-- 迭代 query:iter_captures / iter_matches，凡 metadata 带 conceal 键的
-- 捕获区间，视为隐藏区间（conceal 替换字符宽度按其值计，空串为 0）
```

这保证插件与编辑器对「藏了什么」的判断来自同一份数据。注意三点：其一，块级 `markdown` 查询里也有 conceal 捕获（如列表标记），原子化只处理行内树，块级 conceal 不影响正文宽度；其二，用户 `conceallevel=0` 时可配置回退为「不扣除 conceal」（配置项 `respect_conceallevel`，默认 true，读取窗口实际值）；其三，`strdisplaywidth` 自动遵循 `ambiwidth`，不要自己另算东亚宽度。

#### 4.2.2 字符分类

对非原子的普通文本逐字符分类，分类函数移植自 `REF/lib/App/Markdown/Utils.pm` 的 `_char_attr`，码点表放 `chardata.lua`。CJK 字符每字一个原子；连续拉丁字母数字归并为一个 `word` 原子；空白归并为 `space` 原子。

#### 4.2.3 不可断原子清单

以下结构整体为一个 `atomic` 原子，内部绝不断行：

1. 行内代码 `` `...` ``（TS 节点 `code_span`）。注意这与 REF 不同：原实现允许行内代码跨行，但行内代码断行后在某些渲染器中语义会被破坏，且与「放心使用」的目标冲突，v2 收紧为原子。代码超宽时按 4.3.6 溢出规则处理。
2. 三种链接（TS 节点 `inline_link`、`full_reference_link`、`shortcut_link` 等）。conceal 宽度按 4.2.1 自动得出，预期效果等价于 REF 的「只显示 `[display]`」。
3. citation：`[@key]` 预期被 inline 语法解析为 `shortcut_link`，裸 `@key2020` 形式 TS 不识别，需补充正则 `@[%w_][%w_:%-%.#%$%%&+%?<>~/]*`（对应 Pandoc citation key 字符集，以 REF 中 `@` 探针的结束条件为参考但注意其 bug，最终以 golden 用例 09 为准）。
4. shortcode `{{<` 到 `>}}`。
5. 行内数学 `$...$`（TS 扩展节点 `latex_block`，若无则补充正则，要求 `$` 紧贴非空白）。
6. 强调**不是**原子：`*强调内容*` 内部可以断行，定界符 conceal 计 0 宽。实现方式：进入强调节点内部递归原子化，定界符产出宽度为 0 的原子并标记 `break_before = false`（开定界符）／前一原子后禁断（闭定界符）。

#### 4.2.4 零宽空格

零宽空格（U+200B）是用户手工标记的强制断点提示：产出一个宽度 0 的特殊原子，布局层视为最高优先级断行机会，输出时保留该字符。

### 4.3 layout.lua：断行核心

**纯函数**。签名建议：

```lua
---@param atoms mdwrap.Atom[]
---@param opts { width:integer, prefix_first:string, prefix_rest:string,
---              wrap_sentence:boolean, keep_origin_wrap:boolean,
---              width_fn:fun(s:string):integer }
---@return string[] lines
function M.wrap(atoms, opts) end
```

#### 4.3.1 断行机会（break opportunity）

两个相邻原子之间存在断行机会，当且仅当以下全部成立：

1. 前一原子 class 不是 `punct_no_break_after`，且其文本末字符不属于 `chardata` 的「禁止其后断行」表，也不是半角的 `'"(` 之一；
2. 后一原子 class 不是 `punct_no_break_before`，且其文本首字符不属于「禁止其前断行」表，也不是半角的 `,.!;:?])}` 之一；
3. 二者之间的边界类型属于：space 处、CJK 字符旁（CJK 与任何相邻原子之间，受 1、2 约束）、零宽空格处。两个 `word` 原子之间若无空格则无断行机会（不拆英文单词）；`atomic` 原子内部无断行机会。

#### 4.3.2 行的填充与禁则兜底

贪心填行：依次放入原子，超过 `width` 前在最后一个断行机会处断开。两条兜底规则：

- **行首禁则兜底**：若断行导致下一行以禁前断字符开头（理论上 4.3.1 已排除，但溢出处理可能制造此情形），把该标点回收到上一行行尾，允许上一行超宽一个标点位。这对应 REF 中 `_handle_wrap_forbidden_before` 的「插入上一行末尾」行为。
- **空行清理**：输出前去除行尾空白；三连以上空行压缩为两个（对应 `_clean_input_text` 与 `_post_processing`）。

#### 4.3.3 行合并（重折前的归一化）

`keep_origin_wrap = false`（默认）时，先把块内原有软换行合并成逻辑长行再折行。合并规则移植自 `REF/lib/App/Markdown/Text.pm` 的 `update_when_new_line`：设换行符前的最后可见字符为 L、后的首个非空白字符为 R，

- R 是宽字符（CJK 或全角标点）且 L 为空、空格或非 OTHER 类 ⇒ 直接拼接，不加空格；
- L 是标点类（PUN 各类）⇒ 直接拼接；
- 其余 ⇒ 以一个空格连接。

直观效果：中文行之间合并无痕，英文行之间合并得一个空格。

#### 4.3.4 句末优先断行（短行容忍）

这是 mdwrap 最具特色的行为，REF 中实现为 `support_shorter_line` 与 `cal_remaining_space` 的交互，此处给出清晰化重述（实现可不同，效果以 golden 04 为准）：

每个断行机会带一个等级，由断点前的最后字符决定：

| 等级 | 触发字符 | 容忍短行量 allowance |
|---|---|---|
| sentence | `。：．；！？`（句级分隔符集） | min(60, width − 20) |
| clause | `，` | min(12, width − 20) |
| normal | 其他 | min(6, width − 20) |

填行时，若存在等级为 sentence 的断行机会、且在此断开后行长 ≥ width − allowance(sentence)，则优先在句末断开，即使继续填充本可更接近 width；clause 同理次之。效果：宁可行短一些，也让行尾落在句号、分号等强标点上，整段的「锯齿」对齐到句子边界。

#### 4.3.5 wrap_sentence 模式

`wrap_sentence = true` 时关闭 4.3.4 的偏好，单纯按宽度贪心填满（仍受禁则约束）。`wrap_sentence = false`（默认）时启用句末优先。注意：REF 中该选项语义比较缠绕，v2 按上述简化语义实现，golden 用例 24 固化两种模式的差异。

#### 4.3.6 溢出规则

单个原子（长 URL、长行内代码、超长英文词）自身超过可用宽度时：独占一行并允许超宽，不在原子内部断开，不报错。前后照常断行。

### 4.4 spacing.lua：中英文空格（可选 pass）

在原子化之后、布局之前运行（配置 `cjk_english_spacing`，默认 true）。规则：

- CJK 字符与相邻的拉丁字母／数字之间插入一个半角空格；
- 全角标点与任何字符之间**不**插入；
- 只作用于普通文本原子边界；`atomic` 原子（代码、链接、数学、citation、shortcode）的内部与其边界都不插入——注意边界也不插，因为行内代码贴着中文是常见的刻意写法，插空格会改变作者排版意图，此处与部分盘古工具不同，以 golden 21 为准；
- 幂等：已有空格不再插。

### 4.5 init.lua：编辑器集成

1. `setup(opts)` 合并配置。`plugin/mdwrap.lua` 对 `markdown`、`quarto`、`pandoc`、`rmd` filetype 设置 `formatexpr=v:lua.require'mdwrap'.formatexpr()`。
2. `formatexpr` 契约：插入模式（`mode():find('i')` 或 `v:char ~= ''`）返回 1 回退；正常模式读取 `v:lnum` 与 `v:count`，经 blocks.lua 扩块、逐块处理、`nvim_buf_set_lines` 回写，返回 0。
3. 宽度取值顺序：显式配置 `width` ＞ buffer 的 `textwidth`（非 0 时）＞ 默认 80。
4. 提供命令 `:MdwrapFormat`（整 buffer）与 `:MdwrapFormat'<,'>`（范围）。
5. 提供 headless 入口 `require('mdwrap').format_buffer(bufnr, opts)`，供测试与批处理调用。

---

## 5. 配置项

```lua
require('mdwrap').setup({
  width = nil,                  -- nil 则取 textwidth，再退 80（REF: --line-width）
  wrap_sentence = false,        -- REF: --wrap-sentence；false 时启用句末优先断行
  keep_origin_wrap = false,     -- REF: --keep-origin-wrap；true 时不合并原有换行
  lang = 'zh',                  -- 预留；v1 仅 zh
  cjk_english_spacing = true,   -- 盘古之白 pass
  respect_conceallevel = true,  -- conceallevel=0 的窗口不扣 conceal 宽度
  notify_on_error_node = true,  -- 块含 ERROR 节点跳过时提示
})
```

---

## 6. 测试文档与目标效果

测试先行：每个里程碑先写测试再写实现。所有 golden 用例在动手实现 layout 之前先以文件形式落盘。

### 6.1 测试基础设施

**单元层（无 Neovim）**：`tests/unit/` 下用纯 Lua 断言（busted 可用则用 busted，不可用则写极简断言函数）测 `layout.lua`、`spacing.lua`、`chardata.lua`。宽度函数注入 stub：

```lua
-- 测试 stub：CJK 与全角计 2，其余计 1（足够覆盖布局逻辑）
local function stub_width(s) ... end
```

**集成层（golden 比对）**：`tests/run_golden.sh` 对每个用例执行：

```bash
nvim --headless --clean -u tests/minimal_init.lua \
  -c "lua require('mdwrap.test_runner').run('$case_dir')" -c 'qa!'
```

`test_runner` 读 `input.md`，按 `opts.lua` 配置调 `format_buffer`，与 `expected.md` 逐字节 diff，不一致则输出 diff 并以非零码退出。`minimal_init.lua` 需确保 markdown 与 markdown_inline 两个 TS parser 可用（nvim-treesitter 已装则用之；否则检测 `vim.treesitter.language.add` 可见的内置 parser，缺失时跳过集成层并明确报告，不得静默通过）。

### 6.2 不变量测试（对全部 golden 输入自动执行）

1. **幂等性**：`format(format(input)) == format(input)`。任何用例违反即失败。
2. **块外字节不变**：对每个用例另行构造「目标块前后各加一段不规范但 preserve 类内容」的包裹版输入，验证包裹部分输出与输入逐字节相同。
3. **语义保持**（系统有 pandoc 时执行，没有则跳过并报告）：以 `cjk_english_spacing=false` 运行格式化，对输入输出分别执行 `pandoc -f markdown -t json`，将 AST 中所有 `SoftBreak` 归一化为 `Space`、合并相邻 `Str`／`Space` 后比较，必须相等。spacing 开启时跳过此项（它故意改文本）。

### 6.3 golden 用例清单

每个用例一个目录 `tests/golden/NN-name/`，含 `input.md`、`expected.md`、`opts.lua`（缺省则全默认、width=20 或 80 见各例）。**expected 文件由你按下述规格手工精确构造，构造完成后请用户过目确认，再开始实现**。以下给出每例的输入要点与验收要点（→ 后为必须成立的性质）：

01-basic-cjk（width=20）：一段 40 个汉字的纯中文。→ 每行显示宽度 ≤ 20 且 ≥ 14（normal 容忍 6）；无半角空格被引入；行数正确。

02-kinsoku-before（width=20）：构造使贪心断点恰好落在 `。`、`，`、`」` 之前的文本。→ 这些字符绝不出现在行首；必要时上一行超宽一个标点位。

03-kinsoku-after（width=20）：构造使断点恰好落在 `「`、`《`、`（` 之后的文本。→ 这些字符绝不出现在行尾。

04-sentence-preferred（width=30）：两句中文，第一句结束于约 22 显示宽度处。→ 第一行止于 `。`（行宽 22，虽然还能再装），第二句从第二行开头开始。同一输入在 `wrap_sentence=true` 下则第一行填到接近 30（此变体放 24-wrap-sentence）。

05-conceal-bold（width=20）：含 `**粗体**` 的中文段。→ 折行位置按视觉宽度计算（`**` 计 0 宽）；输出中 `**` 与其内容不被拆到定界符单独成行；与同文本去掉 `**` 的折行点一致。

06-inline-code（width=20）：含 `` `code_span` `` 且其恰跨贪心断点。→ code span 整体移到下一行，绝不内部断开。

07-inline-link（width=30）：`[显示文本](https://example.com/very/long/path)`。→ 宽度按「[显示文本]」计；链接整体不断开。

08-long-url（width=20）：裸长 URL 一行。→ 独占一行允许超宽，前后正常折行，URL 字节不变。

09-citation（width=20）：含 `[@smith2020]` 与裸 `@smith2020` 各一处，置于断点附近。→ 两种形式均不内部断开；`[@smith2020]` 不被拆成 `[@` 与 `smith2020]`。

10-shortcode（width=20）：行中含 `{{< var foo >}}`。→ 整体原子，不内部断开。

11-inline-math（width=20）：含 `$\alpha + \beta$`。→ 整体原子；`$` 定界符显示宽度计入。

12-list-hanging（width=20）：无序项、有序项 `1.`、任务项 `- [ ]` 各一，内容为长中文。→ 续行缩进与首行内容左缘对齐（标记等宽空格）；列表结构经 pandoc 检查不变。

13-nested-quote（width=20）：`> > ` 两层引用内长中文段。→ 每行以 `> > ` 开头；前缀宽度计入行宽。

14-callout（width=30）：`> [!note] 标题` 加两行正文。→ 标题行原样独立；正文按引用前缀折行。

15-div-fence（width=20）：`::: {.callout-tip}` 包裹一段长中文，`:::` 收尾。→ 两条围栏行逐字节不变；内部段落正常折行。

16-yaml（width=20）：YAML 头（含超长 title 行）＋一段正文。→ YAML 区逐字节不变；正文折行。

17-code-block（width=20）：围栏代码块与四空格缩进代码块各一，内含超长行与中文。→ 逐字节不变。

18-table（width=20, format_tables=false)：一个 pipe table，单元格含长中文。→ 关开关时逐字节不变。

38-table-align（默认配置）：覆盖左/居中/右/默认四种对齐 + 盘古空格 + 短单元格 + 缺/多列。
→ 按列视觉宽对齐补空格，不折行；对齐语义补白（右靠右、居中居中），居中奇余放右。

19-headings（width=20）：atx 与 setext 标题各一，标题文本超宽。→ 逐字节不变。

20-linkref（width=20）：`[ref]: https://...` 定义行超宽。→ 逐字节不变。

21-cjk-spacing（width=80）：`中文English混排123数字`，以及紧贴中文的 `` `code` ``。→ 输出 `中文 English 混排 123 数字`；code 边界不插空格；全角标点旁不插；对已规范文本幂等。

22-rewrap-merge（width=30）：已被硬折过的中文段（行尾汉字／行首汉字）与英文段（行尾字母／行首字母）。→ 中文合并处无空格残留；英文合并处恰一个空格；重折后无「中文字符间夹空格」现象。

23-zwsp（width=30）：长中文中嵌一个 U+200B。→ 该处必为断行点之一；字符在输出中保留。

24-wrap-sentence（width=30）：与 04 同输入，`opts.lua` 设 `wrap_sentence=true`。→ 行尾不再对齐句号，按宽度填满。

25-keep-origin-wrap（width=80）：随意换行的段落，`keep_origin_wrap=true`。→ 换行位置完全保留，仅做行尾空白清理（若有 spacing 则只插空格）。

26-error-node（width=20）：构造一段含未闭合围栏等畸形结构。→ 所在块逐字节不变，其余正常块照常处理。

### 6.4 验收标准

全部满足方可交付：单元测试全绿；golden 26 例全绿；三项不变量对全部用例通过；`luacheck`（可用时）无警告；`layout.lua`、`spacing.lua`、`chardata.lua` 在 `luajit` 下可独立 require；README 含安装、配置、与 mdwrap CLI 选项的对照表。

---

## 7. 实施顺序

- **M0**：确认 REF 路径；本地实验确认 tree-sitter 节点名（含 `[@key]` 实际解析为什么节点、数学与表格节点是否存在），把实测结果写进 `blocks.lua`／`atoms.lua` 头部注释；落盘全部 26 个 golden 用例的 input 与 expected，请用户确认 expected。
- **M1**：`chardata.lua` ＋ `layout.lua` ＋ 单元测试（stub 宽度）。覆盖 01–04、22–25 的逻辑等价单元用例。
- **M2**：`atoms.lua` ＋ `blocks.lua`，headless 实验验证 conceal 元数据读取。
- **M3**：`init.lua` 集成与 `test_runner`，跑通 golden 全集与不变量。
- **M4**：`spacing.lua`、配置打磨、README。

每个里程碑结束时报告：通过／失败用例清单、与本文档规格的任何偏离及理由。

## 8. 反模式警示（再次强调）

不要复刻 REF 的十一层 handler 字符状态机与 word／sentence／line 三缓冲区；不要复刻 `Inline.pm` 第 110 行附近 `=` 误作 `=~` 的 citation 探针行为；不要实现 tonewsboat；不要在布局层 require 任何 `vim.*`；不要为通过测试修改 golden expected（确需修改时停下来向用户说明）。
