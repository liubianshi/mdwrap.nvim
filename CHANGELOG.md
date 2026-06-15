# 更新日志

本文件记录 mdwrap.nvim 的显著变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/) 的 0.x 阶段约定：0.x 期间 minor 号承载
破坏性变更，patch 号修 bug；进入 1.0.0 后才保证向后兼容。

发布流程：把 `[Unreleased]` 下累积的条目切出为一个 `[x.y.z] - 日期` 段落，并打对应的 git tag
（如 `git tag -a v0.1.0 -m "..."`）。

## [Unreleased]

## [0.1.0] - 2026-06-15

### Added

- conceal 感知的硬折行：按 Neovim 实际显示宽度折行，扣除 tree-sitter conceal（`**`、反引号）
  与渲染插件（render-markdown.nvim、markview.nvim 等）的持久 conceal extmark／inline virt_text。
- 中文排版规则：禁则处理（标点不落行首、行尾），句末优先断行，行合并时中文字符间不引入空格，
  可选的中英文盘古空格。
- 中文仅在标点处断行（`cjk_break_at_punct_only`，默认开）；无标点超长子句按 `wrap_sentence`
  决定整段溢出或字间断兜底。
- 括号配对作整体（`bracket_as_unit`，默认开）：能整组放下就不在括号内部断。
- 入口：`formatexpr`（`gq` 系列，`gqq` 只折当前行）、`:MdwrapFormat` 命令、
  `format_buffer`／`format_lines`／`format_file` API，以及 conform.nvim Lua-formatter 集成。
- 命令行格式化：`format_file(path, opts)` 配合 `nvim --headless` 直接格式化磁盘上的文件。

### Changed

- 冒号 `：`/`:` 断行分级：从「句末级」下放为介于句末与逗号之间的**中间级**（断点优先级
  sentence ＞ colon ＞ clause）。句末优先模式下，行尾优先落在真正的句末（`。；！？`），仅当
  无句末断点时才在冒号处断；冒号仍高于逗号一级。冒号与逗号一样保留 `allow_c` 短行下限，
  靠行首的冒号不再断出过短的行。受此影响，英文 `Note: ...` 一类不再在冒号处急断成短行，改按
  词折满（更新验收用例 29-en-colon）。新增回归用例 36-colon-below-sentence。

### Fixed

- 懒加载补偿：lazy.nvim 以 `ft=` 懒加载时对已存在的 markdown buffer 补设 formatexpr，
  不再需要手动 `:set ft=markdown`。
- 强调闭合定界符（`**…**`）并入末尾 word，不再错位、不再插入多余空格。
- 嵌套列表折行丢行：tree-sitter 把下一个列表项的缩进 `block_continuation` 收作上一项
  paragraph 的尾随子节点，使块行范围多吞一行、相邻块区间重叠，自底向上回写时互相覆盖、
  吃掉行（含其后的空行）。改为按 paragraph 的 `inline` 子节点定正文边界，剔除该跨项
  `block_continuation`；callout 正文路径一并加固。新增回归用例 35-nested-list-trailing-blank。
- 独立缩进段落折行丢缩进：无列表/引用标记、仅靠前导空白对齐的段落（如脱离列表上下文的续行），
  tree-sitter 把前导空白当作 inline 内容，折行时被吞掉。改为把首行前导空白提升为悬挂缩进
  （prefix_first＝prefix_rest），折行续行也保留同样缩进。新增回归用例 37-indent-paragraph。
- `gqq` 落在多行 wrap 块内时对 CJK 不折行：原先此处回退 Neovim 默认折行引擎，而该引擎不在 CJK
  之间断行，对中文等于不折。改为用 mdwrap **只折当前行**（不合并整段，按真实行号读取该行的
  conceal extmark），既保留「只折当前行」的裁定意图，中文也真正生效（见 DECISIONS 修订）。
