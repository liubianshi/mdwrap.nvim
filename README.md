# mdwrap.nvim

为 Pandoc／Quarto 方言的中文 Markdown 提供 **conceal 感知的硬折行**的 Neovim 插件。

它按 Neovim **实际显示的宽度**折行（扣除被 conceal 隐藏的部分，如 `**`、行内代码反引号、
链接 URL 等），使文本在视觉上对齐；并实现中文排版规则：禁则处理（标点不落行首／行尾）、
句末优先断行、合并行时中文字符间不引入空格、以及可选的中英文之间盘古空格。

入口为 `formatexpr`（`gq` 系列）与 `:MdwrapFormat` 命令。本插件是 Perl 工具
[mdwrap](https://github.com/) 的 Neovim 重写，只迁移领域知识，不沿用其架构。

## 特性

- **conceal 感知折行**：宽度来自 `markdown_inline` 高亮查询的 conceal 元数据，与编辑器实际显示一致。
- **中文禁则**：`。，」』）》】` 等绝不落行首（溢出回收到上一行）；`「『（《【` 等绝不落行尾（推到下一行）。
- **句末优先断行**：宁可行短一些，也让行尾落在句号、分号等强标点上（可用 `wrap_sentence` 关闭）。
- **行合并无痕**：重折前合并原有软换行，中文行之间无空格、英文行之间恰一个空格。
- **结构识别**：YAML／代码块／数学块／表格／标题／链接引用定义不折行；列表悬挂缩进；
  嵌套引用前缀；callout 标题独立；`:::` 围栏 div；citation 与 shortcode 作为不可断原子。
- **盘古之白**：CJK 与拉丁字母／数字之间、CJK 与行内代码之间插入半角空格（可关闭）。
- **幂等**：格式化两次与一次结果相同。
- **最小差异**：只改动目标块内的换行与空白，块外字节不变。

## 要求

- Neovim ≥ 0.10（需内置 tree-sitter）。
- 已安装 `markdown` 与 `markdown_inline` parser。
- 建议安装 [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)，
  以提供 `markdown_inline` 的 `highlights` 查询（conceal 宽度的来源）。
- 行内数学 `$…$` 的 `$` 定界符宽度依赖渲染插件（如
  [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)）的 conceal；
  本插件内建把 `$` 视为隐藏（不计宽），与上述渲染一致。

## 安装

[lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "your/mdwrap.nvim",
  ft = { "markdown", "quarto", "pandoc", "rmd" },
  opts = {},   -- 见下方配置
}
```

[packer.nvim](https://github.com/wbthomason/packer.nvim)：

```lua
use({ "your/mdwrap.nvim", config = function() require("mdwrap").setup({}) end })
```

## 用法

- **`gq` 系列**：插件对 `markdown`／`quarto`／`pandoc`／`rmd` filetype 设置 `formatexpr`，
  于是 `gqip`（格式化段落）、`gqq`、可视选区 `gq` 等都按本插件逻辑折行。
- **`:MdwrapFormat`**：格式化整个 buffer；`:'<,'>MdwrapFormat` 格式化选区。
- **脚本／批处理**：`require("mdwrap").format_buffer(bufnr, opts)`。

折行宽度取值顺序：显式配置 `width` ＞ buffer 的 `textwidth`（非 0）＞ 默认 80。

## 配置

```lua
require("mdwrap").setup({
  width = nil,                  -- nil 则取 textwidth，再退 80
  wrap_sentence = false,        -- false 时启用句末优先断行；true 时单纯按宽度填满
  keep_origin_wrap = false,     -- true 时不合并原有换行（仅清行尾空白 + 盘古空格）
  lang = "zh",                  -- 预留；v1 仅 zh
  cjk_english_spacing = true,   -- 盘古之白：CJK↔拉丁/数字、CJK↔行内代码 之间插空格
  respect_conceallevel = true,  -- conceallevel=0 的窗口不扣 conceal 宽度
  notify_on_error_node = true,  -- 块含 ERROR 节点（畸形）跳过时提示
})
```

## 与 Perl 版 mdwrap CLI 选项对照

| mdwrap CLI | 本插件配置 | 默认 |
|---|---|---|
| `--line-width N` | `width = N` | 80（或 `textwidth`） |
| `--wrap-sentence` | `wrap_sentence = true` | `false` |
| `--keep-origin-wrap` | `keep_origin_wrap = true` | `false` |
| `--lang zh` | `lang = "zh"` | `"zh"` |
| `--tonewsboat` | —（不支持，超出范围） | — |

## 架构

三层分离（解析 / 布局 / 依赖注入）：

- `blocks.lua` — tree-sitter 块级切分与前缀计算。
- `atoms.lua` — 行内树 → 原子列表（不可再分单元 + 视觉宽度）；conceal 宽度来自高亮查询。
- `layout.lua` — 断行核心（**纯函数**，禁止 `require` 任何 `vim.*`）。
- `spacing.lua` — 盘古空格（**纯函数**）。
- `chardata.lua` — 字符分类码点表（**纯函数**，移植自 Perl 版）。
- `init.lua` — 编辑器集成与 `formatexpr` 入口。

`layout.lua`／`spacing.lua`／`chardata.lua` 可在无 Neovim 的纯 Lua（luajit／lua5.1）下加载与测试；
布局层通过 `width_fn` 参数接收宽度函数（生产注入 `strdisplaywidth` + conceal，测试注入查表 stub）。

## 测试

```bash
tests/run_unit.sh     # 纯 Lua 单元测试（layout/spacing/chardata），无需 Neovim
tests/run_golden.sh   # nvim --headless 驱动，逐字节 diff input→expected + 三项不变量
```

三项不变量对全部 golden 输入自动执行：①幂等 `format(format(x)) == format(x)`；
②块外字节不变；③pandoc AST 语义保持（系统有 pandoc 时）。

设计文档见 `mdwrap-nvim-design.md`；与设计文档有出入的若干裁定见 `tests/golden/DECISIONS.md`。
