# mdwrap.nvim

为 Pandoc、Quarto 方言的中文 Markdown 提供 **conceal 感知的硬折行**，
也可扩展 render-markdown.nvim，实现**不改文档的显示折行**。

它按 Neovim **实际显示的宽度**折行（扣除被 conceal 隐藏的部分，如 `**`、行内代码反引号、
链接 URL 等），使文本在视觉上对齐；并实现中文排版规则：禁则处理（标点不落行首、行尾），
句末优先断行，合并行时中文字符间不引入空格，以及可选的中英文之间盘古空格。

入口为 `formatexpr`（`gq` 系列）与 `:MdwrapFormat` 命令。本插件是 Perl 工具
[mdwrap](https://github.com/) 的 Neovim 重写，只迁移领域知识，不沿用其架构。

> [!WARNING]
> 本项目主要由 [Claude Code](https://www.anthropic.com/claude-code) 编写，目前处于早期阶段，
> 接口与折行行为会经常大幅调整；变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 特性

- **conceal 感知折行**：宽度来自 `markdown_inline` 高亮查询的 conceal 元数据，与编辑器实际显示一致。
- **插件无关的外部渲染感知**：除 tree-sitter conceal 外，还读 buffer 上的**持久 conceal extmark**
  （隐藏标记）与 **inline `virt_text`**（插图标），故 [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)、
  [markview.nvim](https://github.com/OXY2DEV/markview.nvim) 等把长链接塌成图标，把 `$`、`**` 隐藏时，
  折行仍与屏幕对齐。读所有 namespace 自动过滤，不绑定具体插件；可用 `respect_extmark_conceal` 关闭。
- **中文禁则**：`。，」』）》】` 等绝不落行首（溢出回收到上一行）；`「『（《【` 等绝不落行尾（推到下一行）。
- **中文只在标点断**（仅句末优先模式；`wrap_sentence = true` 下自动失效）：默认中文仅在标点处
  换行，不在普通汉字之间断，也不在盘古空格处断。
  盘古空格是 CJK 与拉丁／行内代码之间的那个半角空格（本插件也会自动补上），不是原文的词边界，
  断在那里会把「2023 年间」「而 APEC」这类语义单元劈开；原文自带的英文词间空格不受影响，照常可断。
  行尾若会停在涉及中文的非标点断点（盘古空格、链接／行内代码等原子边界），则回落到标点上：
  首选本行最远、且不致把行切得过短的标点断点；标点候选全都太靠前时，
  前瞻下一行的原始落点：不超宽就回落，仍超宽才让本行溢出。
  前瞻不模拟短尾巴并入，下一行最终仍可能有限超宽，不保证段落全局最优。
  本行内**一个标点候选都没有**时不回落，落在原子边界上（链接／数学／引用是不可分单元，
  在其前后换行是合理排版）。纯拉丁语境的断点不涉中文，一概不回落。
- **短尾巴并入**：断点之后若只剩一小截（不足四分之一行宽）就到句末，把那一截并进本行，
  宁可有限超宽，也不给下一行留一个十几列的孤行。本行行尾已经是句号时不并入
  （否则连续短句会被黏成一行），段落最后一行也不并入（末行短本来就是正常的）。
  无标点的超长子句：句末优先模式（默认 `wrap_sentence = false`）整段溢出到**下一个合法行尾**
  （标点、原子边界或零宽空格），中途跳过盘古空格与汉字间，绝不把一个英文词单独甩成一行；
  按宽填满模式（`wrap_sentence = true`）才退化为字间断兜底，而盘古空格排在字间断之前先放开。
  可用 `cjk_break_at_punct_only = false` 退回传统逐字可断。
- **括号作整体**：配对括号（中英文 `（）`、`()`、`【】`、`《》` 等）能整组放进一行时，
  宁可整组移到下一行也不在括号内部断；只有整组比一整行还宽才回退内部断。
  可用 `bracket_as_unit = false` 关闭。
- **句末优先断行**：宁可行短一些，也让行尾落在句号、分号等强标点上（可用 `wrap_sentence` 关闭）。
  置 `wrap_sentence = true` 则改为**按宽填满、行长尽量一致**（Vim `gww` 的语义），
  断点处仍守禁则：英文单词不在内部断，`。，」》` 等不落行首（即不会「在句号前面断」）。
  此模式下 `cjk_break_at_punct_only` **强制失效**——中文没有词边界，只在标点断就意味着行长
  完全由标点位置决定，与「填满」互斥；单个 `wrap_sentence` 开关即可拿到 gww 效果。
  中英文一视同仁——半角 `. : ; ! ?` 与全角 `。：；！？` 同为句级断点，`,`、`，`、`、` 为子句级
  最后手段；英文另带缩写保护（`Dr.`、`e.g.`、`U.S.` 等不误判为句末）。
- **行合并无痕**：重折前合并原有软换行，中文行之间无空格，英文行之间恰一个空格。
- **结构识别**：YAML、代码块、数学块、标题、链接引用定义不折行；列表悬挂缩进；
  嵌套引用前缀；callout 标题独立；`:::` 围栏 div；citation 与 shortcode 作为不可断原子。
- **表格对齐**：管道表格不折行，按列视觉宽（CJK 计 2）补空格对齐，对齐语义由分隔行冒号决定
  （`format_tables`，默认开；可关闭回退整块保留）。
- **盘古之白**：CJK 与拉丁字母、数字之间，CJK 与行内代码之间插入半角空格（可关闭）。
- **手动关闭折行**：用 `mdwrap-ignore` 系标记（HTML 注释或 frontmatter 键）显式豁免整文件、
  区域、下一块或下一行，被标记处逐字节不变（见下「手动关闭折行」）。
- **幂等**：格式化两次与一次结果相同。
- **最小差异**：只改动目标块内的换行与空白，块外字节不变。

## 要求

- Neovim ≥ 0.10（需内置 tree-sitter）。
- 已安装 `markdown` 与 `markdown_inline` parser。
- 建议安装 [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)，
  以提供 `markdown_inline` 的 `highlights` 查询（conceal 宽度的来源）。
- 行内数学 `$…$` 的 `$` 定界符、链接 URL、列表、引用前缀图标等**渲染插件特有的 conceal**，
  通过读 buffer 上的持久 extmark 自动感知（插件无关，见上「外部渲染感知」）。未装渲染插件时
  这些字符按字面宽计入——`conceallevel=0` 或无渲染 extmark 即此情形，行为确定，零依赖。

## 安装

[lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "liubianshi/mdwrap.nvim",
  ft = { "markdown", "quarto", "pandoc", "rmd" },
  opts = {},   -- 见下方配置
}
```

[packer.nvim](https://github.com/wbthomason/packer.nvim)：

```lua
use({ "liubianshi/mdwrap.nvim", config = function() require("mdwrap").setup({}) end })
```

## 用法

- **`gq` 系列**：插件对 `markdown`、`quarto`、`pandoc`、`rmd` filetype 设置 `formatexpr`，
  `gqip`（格式化段落）、可视选区 `gq` 按本插件逻辑整段折行；
  `gqq`（多行段落中的单行）回退 Neovim 默认行为（只折当前行，不波及整段）。
- **`:MdwrapFormat`**：格式化整个 buffer；`:'<,'>MdwrapFormat` 格式化选区。
- **脚本、批处理**：`require("mdwrap").format_buffer(bufnr, opts)`。
- **lines 进、出**：`require("mdwrap").format_lines(lines, opts)`——接收并返回 `string[]`，
  `opts` 含 `bufnr`（取窗口 `conceallevel` 等环境量）与 `range`；供 conform.nvim 等格式化编排器调用。

折行宽度取值顺序：显式配置 `width` ＞ buffer 的 `textwidth`（非 0）＞ 默认 80。

## 显示折行：扩展 render-markdown.nvim

显示折行只改变屏幕上的断点，不插入真实换行，不合并已有行，也不调整空格或表格。
缓冲区内容、`modified`、撤销历史和寄存器不受影响；复制、搜索、编辑仍针对原文，
`gj`、`gk` 可沿屏幕行移动。
这项集成默认不开启，使用 render-markdown.nvim 的公开 `on.render`、`on.clear` 回调，
无需修改或 fork 上游；已用 render-markdown.nvim v8.14.0 验证。

需要 **Neovim ≥ 0.11**，且提供实验性 API `nvim__ns_set`，用于隔离各窗口的显示标记。
缺少 API 时会警告并跳过集成，原有硬折行仍支持 Neovim ≥ 0.10。
同一缓冲区在不同宽度的窗口中会独立折行，宽度取窗口的实际正文区，扣除行号、符号栏和折叠栏，
可用显示专用的 `max_width` 限制上限。
它不读取硬折行的 `width`、`textwidth` 或默认 80。

在 lazy.nvim 的 render-markdown.nvim 配置中包装原有 `opts`：

```lua
{
  "MeanderingProgrammer/render-markdown.nvim",
  dependencies = {
    { "liubianshi/mdwrap.nvim", opts = { set_formatexpr = false } },
  },
  opts = function(_, opts)
    return require("mdwrap.integrations.render_markdown").extend(opts, {
      wrap_sentence = true,
      max_width = 120,
      insert_mode = "native",
    })
  end,
}
```

`extend(opts)` 返回配置副本，保留其他设置，并先调用原有回调，再更新显示折行。
如果已有自定义 `config` 函数，须把返回值传给 `setup`：

```lua
require("render-markdown").setup(require("mdwrap.integrations.render_markdown").extend(opts, {
  wrap_sentence = true,
  max_width = 120,
  insert_mode = "native",
}))
```

第二个参数是显示专用配置：`wrap_sentence = true` 按窗口宽度尽量填满，不优先在句末提前折行。
它不改变 `mdwrap.setup()` 的硬折行配置；不指定时继承原有 `wrap_sentence` 值。
英文单词、中文禁则和括号整体约束仍有效，末行及已有物理换行附近可能较短，不保证每行等长。
`max_width` 是正整数，单位为显示列，包含列表或引用的前缀缩进；120 列约容纳 60 个汉字。
断点按 `min(窗口正文宽度, max_width)` 规划：宽窗口不继续拉长，窄窗口仍随窗口收缩。
不指定 `max_width` 时不设上限；它不改变窗口大小、全局选项或源文件。

`insert_mode` 控制插入模式中编辑行的折行方式，默认值为 `"native"`。
此时只有活动窗口正在编辑的物理源行撤去 mdwrap 断点，退回按窗口宽度进行原生软折行；
该源行的所有屏幕续行都受影响，但其他源行和其他窗口仍保持 mdwrap 折行。
编辑行临时不受 `max_width` 限制，移动到另一源行或退出插入模式后自动恢复。

设为 `insert_mode = "wrap"`，编辑行也会持续使用 mdwrap 折行，随输入重新计算断点。
文本和窗口正文宽度不变时，进入插入模式沿用原有源文本断点；
语法标记显露或渲染图标消失时，只调整虚拟填充和续行缩进，不因显隐重新选择断点。
为保持断点，显露的语法可能使屏幕行暂时超过 `max_width`，但不会超过窗口正文宽度。
输入、删除、调整窗口或折行配置时，按当前实际显示宽度重新规划；原断点放不下时也会重新规划。
因此实际编辑仍可能改变断点和屏幕光标位置，但虚拟填充空格不会写入源文件。
下述安全回退在这两种策略下仍有效。

字符、行和块可视模式（`v`、`V`、`Ctrl-V`）中，选区内外的段落都保持显示折行，
不受 `insert_mode` 影响。
选区扩展、缩小时，按 `concealcursor` 的 `v` 设置及上游 `anti_conceal` 调整语法显隐。
文本、正文宽度及折行配置不变时，优先沿用原断点，只调整填充和续行缩进。
与 `"wrap"` 插入策略相同，显露的语法可能使行暂时超过 `max_width`；
原断点超出窗口正文宽度时重新规划。

插入和可视模式中都需要 render-markdown 本身仍启用渲染：
可设置 `render_modes = true`，或在原有 `render_modes` 列表中加入所需模式。
插入模式为 `"i"`，字符、行和块可视模式分别为 `"v"`、`"V"`、`"\22"`。
适配器不会修改这项配置，也不会覆盖 `concealcursor` 或 `anti_conceal`；
若上游在这些模式停止渲染，mdwrap 也会清理显示标记并恢复窗口选项。

只加载 mdwrap 或执行 `:MdwrapDisplay` 不会自动接入 render-markdown。
这里的 `set_formatexpr = false` 让 `gq` 不接管硬折行；若仍需原有 `gq` 功能，可以省略该选项。
也不要把 `MdwrapFormat` 或 conform 的 mdwrap 格式化器当作显示折行入口，它们会修改文本。

`:MdwrapDisplay` 切换当前缓冲区的显示折行，作用于显示它的所有窗口；
也可显式执行 `:MdwrapDisplay enable`、`:MdwrapDisplay disable`、`:MdwrapDisplay toggle`。
适配器配置后、首次渲染前执行命令，会保留当前缓冲区的开关状态，待渲染回调触发后生效。
替换、Select 及其他不支持的模式下会撤销显示标记并恢复窗口选项，回到普通模式后自动重建。
关闭 render-markdown 渲染、切换缓冲区、关闭窗口时也会清理。
显示期间临时接管 `wrap`、`linebreak`、`breakindent`、`showbreak`、`list`，关闭后恢复；
不改全局选项，也不改用户的 Neovim 配置文件。

断点复用 mdwrap 的句末偏好、中文禁则和括号整体规则，列表、引用的续行按前缀宽缩进。
硬折行允许的超宽策略不适用于屏幕：窗口放不下时，会放宽「中文只在标点断」的限制。
`mdwrap-ignore` 标记及块级保留规则仍有效，被保留的源行不注入 mdwrap 断点，但仍可由原生 `wrap` 显示。

Neovim 原生软折会把被 conceal 隐藏的源字符计入折行列数。
集成会先按渲染宽度规划，再校验原生列数，必要时重新选择断点，避免隐藏标记把续行挤偏。
超过窗口宽的隐藏 URL、超长不可分原子、Tab、零宽空格、跨行 conceal、重复到续行的 inline 虚拟文本，
以及无法精确度量的 conceal 状态，会使该源行回退到原生软折行，不强行保证句末或禁则。
这些回退行及保留块也不保证遵守 `max_width`。
目前精确规划支持 `conceallevel=0` 或 `3`，`1`、`2` 回退原生折行。
启用行号且设置 `cpoptions+=n` 时，原生续行会借用行号栏，集成也会回退原生折行。
解析或窗口 API 出错时会清理该缓冲区的显示状态并警告；修复原因后可用 `:MdwrapDisplay enable` 重试。

## 手动关闭折行（mdwrap-ignore 标记）

类似 `prettier-ignore`，用显式标记声明「这里别动」。被忽略的内容**逐字节不变**（等同保留块），
且保持幂等。标记一律是**独占一行的 HTML 注释**（天然不被改写），匹配**大小写不敏感、内部空白宽松**；
文件级额外支持 frontmatter 键。四个粒度：

| 标记 | 作用 |
| --- | --- |
| `<!-- mdwrap-ignore-file -->`（文件内任意处）<br>或 frontmatter 顶层 `mdwrap: false` | 整文件跳过 |
| `<!-- mdwrap-ignore-start -->` … `<!-- mdwrap-ignore-end -->` | 区间内所有块跳过 |
| `<!-- mdwrap-ignore -->` | 其后第一个折行 / 表格块跳过 |
| `<!-- mdwrap-ignore-line -->` | 其下一源行跳过（在段落内则拆段，仅护该行） |

要点：

- 区域未配对的 `-start` 延伸到文件末尾；未配对的 `-end` 无害忽略；多区域取并集。
- `-line` 标记其**下一源行**；若该行落在段落内部，把该段拆成「前 / 被护行 / 后」三段，
  仅被护行保留，前后照常合并折行。
- 标记**始终生效**（写标记即显式意图），与具体配置无关。

例如：

```markdown
<!-- mdwrap-ignore -->
这段对齐手工排好，别动它。
保持原样。

这段照常折行合并。
```

## 命令行格式化

不打开编辑器也能直接格式化磁盘上的 Markdown 文件，适合脚本与批处理。`format_file` 走与 conform
集成相同的 lines 进出路径，无需先打开 buffer：

```bash
# 就地格式化单个文件
nvim --headless -c "lua require('mdwrap').format_file('doc.md')" -c "qa!"

# 批量（文件参数列表）
nvim --headless doc1.md doc2.md \
  -c "lua for _, f in ipairs(vim.fn.argv()) do require('mdwrap').format_file(f) end" -c "qa!"

# 覆盖配置（如指定宽度）
nvim --headless -c "lua require('mdwrap').format_file('doc.md', { width = 100 })" -c "qa!"
```

说明：

- 命令行下没有渲染插件，extmark conceal（长链接塌缩、`$` 等）按字面宽计入，这是既定行为。
- tree-sitter conceal（`**`、行内代码反引号）在 runtimepath 含 `markdown_inline` 的 `highlights`
  查询时仍生效——装了 nvim-treesitter 即有；用 `--clean` 则完全脱离用户配置，退化为纯字面宽。
- `format_file(path, opts)` 的 `opts` 同 `setup`（`width`、`wrap_sentence` 等可覆盖），
  并保留文件原有的末尾换行与否。

## 配置

```lua
require("mdwrap").setup({
  width = nil,                  -- nil 则取 textwidth，再退 80
  wrap_sentence = false,        -- false 时启用句末优先断行；true 时单纯按宽度填满
  keep_origin_wrap = false,     -- true 时不合并原有换行（仅清行尾空白 + 盘古空格）
  lang = "zh",                  -- 预留；v1 仅 zh
  cjk_english_spacing = true,   -- 盘古之白：CJK↔拉丁/数字、CJK↔行内代码 之间插空格
  cjk_break_at_punct_only = true, -- 中文仅在标点处断行；false 退回传统 CJK 逐字可断
  bracket_as_unit = true,       -- 括号配对作整体：能整组放下就不在括号内部断；超一行才内部断
  format_tables = true,         -- 管道表格按列视觉宽对齐补空格（不折行）；false 时表格整块 preserve 字节不变
  respect_conceallevel = true,  -- conceallevel=0 的窗口不扣 conceal 宽度
  respect_extmark_conceal = true, -- 读渲染插件（render-markdown/markview 等）的持久 conceal extmark；插件无关
  notify_on_error_node = true,  -- 块含 ERROR 节点（畸形）跳过时提示
  set_formatexpr = true,        -- false 时不对上述 filetype 注册 formatexpr，把 gq 让回默认（交由 conform 等接管）
})
```

## 与 conform.nvim 集成

[conform.nvim](https://github.com/stevearc/conform.nvim) 的 formatter 支持**进程内 Lua 形态**
（`format = function(self, ctx, lines, callback)`，与外部 `command` 互斥），且 `ctx` 携带活 bufnr。
因此 mdwrap 可作为**一等 Lua formatter**接入——不经 stdin、stdout 外部进程，直接在编辑器内拿到
tree-sitter 树与窗口 conceal，conceal 感知折行的能力完整保留：

```lua
require("conform").setup({
  formatters = {
    mdwrap = {
      format = function(self, ctx, lines, callback)
        local ok, out = pcall(require("mdwrap").format_lines, lines, {
          bufnr = ctx.buf,    -- 取窗口 conceallevel 等环境量
          range = ctx.range,  -- conform 选区 → mdwrap 块范围
        })
        if ok then callback(nil, out) else callback(tostring(out)) end
      end,
    },
  },
  formatters_by_ft = {
    markdown = { "mdwrap" }, quarto = { "mdwrap" },
    pandoc   = { "mdwrap" }, rmd    = { "mdwrap" },
  },
})
```

`formatexpr` 与 conform 可**共存**：`gq` 系列仍走 mdwrap 的 `formatexpr` 手动折行，conform 负责
format-on-save、`:Format` 编排。若想让 conform 单独接管，把 `gq` 让回 Neovim 默认行为，
设 `set_formatexpr = false`（见上方配置）。

> 注意：conform 串接多个 formatter 时在内存里逐棒传递 `lines`，**中途不回写 buffer**。当 mdwrap
> 排在别的 markdown formatter 之后时，`ctx.buf` 的 tree-sitter 树相对 `lines` 是旧的；mdwrap 内部因此
> 优先从 `lines` 现解析，`ctx.buf` 仅用于读环境量，故无论是否链式都正确。

## 与 Perl 版 mdwrap CLI 选项对照

| mdwrap CLI | 本插件配置 | 默认 |
|---|---|---|
| `--line-width N` | `width = N` | 80（或 `textwidth`） |
| `--wrap-sentence` | `wrap_sentence = true` | `false` |
| `--keep-origin-wrap` | `keep_origin_wrap = true` | `false` |
| `--lang zh` | `lang = "zh"` | `"zh"` |
| `--tonewsboat` | —（不支持，超出范围） | — |

## 架构

三层分离（解析、布局、依赖注入）：

- `blocks.lua` — tree-sitter 块级切分与前缀计算。
- `atoms.lua` — 行内树 → 原子列表（不可再分单元 + 视觉宽度）；conceal 宽度来自高亮查询。
- `layout.lua` — 断行核心（**纯函数**，禁止 `require` 任何 `vim.*`）。
- `spacing.lua` — 盘古空格（**纯函数**）。
- `chardata.lua` — 字符分类码点表（**纯函数**，移植自 Perl 版）。
- `init.lua` — 编辑器集成与 `formatexpr` 入口。
- `display.lua` — 可见源行规划、窗口隔离的 inline 标记与窗口选项生命周期。
- `integrations/render_markdown.lua` — 组合 render-markdown 回调的可选适配器。

`layout.lua`、`spacing.lua`、`chardata.lua` 可在无 Neovim 的纯 Lua（luajit、lua5.1）下加载与测试；
布局层通过 `width_fn` 参数接收宽度函数（生产注入 `strdisplaywidth` + conceal，测试注入查表 stub）。

### 类型系统

全部领域类型（`mdwrap.Atom`、`mdwrap.Block`、`mdwrap.Config`、`mdwrap.WidthFn` 与各 `*Opts`）以
LuaCATS 注解集中声明于 `lua/mdwrap/types.lua`——一个**运行时从不被 `require`** 的 meta 文件：
lua-language-server 按名字在整个工作区解析 `---@class`，与 `require` 无关，因此纯模块只在注释里按名字
引用这些类型，不破坏「禁止 `require` 任何 `vim.*`」的硬约束。仓库根的 `.luarc.json` 把
`runtime.version` 钉为 `Lua 5.1`（对三纯模块的 5.2+ 用法机器化报警），并用 `diagnostics.globals`
静默 `vim`。编辑器侧建议安装
[lazydev.nvim](https://github.com/folke/lazydev.nvim) 以获得完整的 `vim`、tree-sitter 类型。

## 测试

```bash
tests/run_unit.sh      # 纯 Lua 单元测试（layout/spacing/chardata），无需 Neovim
tests/run_golden.sh    # nvim --headless 驱动，逐字节 diff input→expected + 三项不变量
tests/run_typecheck.sh # lua-language-server --check 领域类型校验（注入真实 $VIMRUNTIME）+ 纯模块 no-vim 冒烟
python3 -m pip install -r tests/requirements-display.txt
tests/run_display.sh   # pynvim 附着真实 UI，验证屏幕断点、窗口隔离、模式切换及原文不变
```

显示测试需要 Neovim ≥ 0.11 及 Markdown parser、查询。
`RENDER_MARKDOWN_PATH=/path/to/render-markdown.nvim tests/run_display.sh` 可指定真实渲染插件的检出目录；
未指定时探测默认 lazy.nvim 安装位置，未找到时只跳过真实插件用例。
CI 设置 `REQUIRE_RENDER_MARKDOWN=1`，缺少该依赖会直接失败，并分别测试 Neovim 0.11.0 与 stable。
Neovim 0.10.4 单独执行不支持显示 API 时的兼容性测试。

三项不变量对全部 golden 输入自动执行：①幂等 `format(format(x)) == format(x)`；
②块外字节不变；③pandoc AST 语义保持（系统有 pandoc 时）。

设计文档见 `mdwrap-nvim-design.md`；与设计文档有出入的若干裁定见 `tests/golden/DECISIONS.md`。
