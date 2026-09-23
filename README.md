# mdwrap.nvim

为 Pandoc、Quarto 方言的中文 Markdown 提供 **conceal 感知的硬折行**的 Neovim 插件。

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
- **中文只在标点断**：默认中文仅在标点处换行，不在普通汉字之间断，也不在盘古空格处断。
  盘古空格是 CJK 与拉丁／行内代码之间的那个半角空格（本插件也会自动补上），不是原文的词边界，
  断在那里会把「2023 年间」「而 APEC」这类语义单元劈开；原文自带的英文词间空格不受影响，照常可断。
  行尾若会停在涉及中文的非标点断点（盘古空格、链接／行内代码等原子边界），
  则回落到本行最远的标点断点，此时不受逗号的短行下限约束；纯拉丁语境的断点不涉中文，不回落。
  无标点的超长子句：句末优先模式（默认 `wrap_sentence = false`）整段溢出，绝不在非标点处断；
  按宽填满模式（`wrap_sentence = true`）才退化为字间断兜底，而盘古空格排在字间断之前先放开。
  可用 `cjk_break_at_punct_only = false` 退回传统逐字可断。
- **括号作整体**：配对括号（中英文 `（）`、`()`、`【】`、`《》` 等）能整组放进一行时，
  宁可整组移到下一行也不在括号内部断；只有整组比一整行还宽才回退内部断。
  可用 `bracket_as_unit = false` 关闭。
- **句末优先断行**：宁可行短一些，也让行尾落在句号、分号等强标点上（可用 `wrap_sentence` 关闭）。
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
```

三项不变量对全部 golden 输入自动执行：①幂等 `format(format(x)) == format(x)`；
②块外字节不变；③pandoc AST 语义保持（系统有 pandoc 时）。

设计文档见 `mdwrap-nvim-design.md`；与设计文档有出入的若干裁定见 `tests/golden/DECISIONS.md`。
