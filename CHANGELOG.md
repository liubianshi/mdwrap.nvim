# 更新日志

本文件记录 mdwrap.nvim 的显著变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/) 的 0.x 阶段约定：0.x 期间 minor 号承载
破坏性变更，patch 号修 bug；进入 1.0.0 后才保证向后兼容。

发布流程：把 `[Unreleased]` 下累积的条目切出为一个 `[x.y.z] - 日期` 段落，并打对应的 git tag
（如 `git tag -a v0.1.0 -m "..."`）。

## [Unreleased]

### Added

- conceal 感知的硬折行：按 Neovim 实际显示宽度折行，扣除 tree-sitter conceal（`**`、反引号）
  与渲染插件（render-markdown.nvim、markview.nvim 等）的持久 conceal extmark／inline virt_text。
- 中文排版规则：禁则处理（标点不落行首、行尾），句末优先断行，行合并时中文字符间不引入空格，
  可选的中英文盘古空格。
- 中文仅在标点处断行（`cjk_break_at_punct_only`，默认开）；无标点超长子句按 `wrap_sentence`
  决定整段溢出或字间断兜底。
- 括号配对作整体（`bracket_as_unit`，默认开）：能整组放下就不在括号内部断。
- 入口：`formatexpr`（`gq` 系列，`gqq` 回退 Neovim 默认）、`:MdwrapFormat` 命令、
  `format_buffer`／`format_lines`／`format_file` API，以及 conform.nvim Lua-formatter 集成。
- 命令行格式化：`format_file(path, opts)` 配合 `nvim --headless` 直接格式化磁盘上的文件。

### Fixed

- 懒加载补偿：lazy.nvim 以 `ft=` 懒加载时对已存在的 markdown buffer 补设 formatexpr，
  不再需要手动 `:set ft=markdown`。
- 强调闭合定界符（`**…**`）并入末尾 word，不再错位、不再插入多余空格。
