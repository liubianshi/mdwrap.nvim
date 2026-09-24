# 更新日志

本文件记录 mdwrap.nvim 的显著变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/) 的 0.x 阶段约定：0.x 期间 minor 号承载
破坏性变更，patch 号修 bug；进入 1.0.0 后才保证向后兼容。

发布流程：把 `[Unreleased]` 下累积的条目切出为一个 `[x.y.z] - 日期` 段落，并打对应的 git tag
（如 `git tag -a v0.1.0 -m "..."`）。

## [Unreleased]

### Changed

- **断点判定重构为三个静态数组（`adm` / `qual` / `wide`），零行为变更。** `layout.wrap` 内此前有
  三套重叠的判定各管一段——`gap_breakable`（能不能断）、`level_of`（断在哪一级标点）、
  `punct_break` / `needs_punct_end`（行尾落这里合不合法）——谁都看不见全貌，每加一条规则要在三处
  各补一刀。实则这三套判定的输入全部是静态的：禁则、括号锁定、盘古边界、atomic 类、标点级别，
  没有一项依赖当前行的 `i` / `avail` / `cum`。现整段算一次三个并行数组，逐行只做一趟扫描；
  逐行变化的只剩一个 `min_tier` 整数，取代了 `allow_cjk_cur` / `allow_pangu_cur` 两个布尔开关。
  三个属性**互相独立、压不成一根有序标尺**：全角括号旁可断却不配当行尾，半角句读粘连汉字配当
  行尾却不可断，纯拉丁的 atomic 边界可断但推不出涉不涉中文。
- **少标点中文的折行提速。** 逐行最多三次 `has_break(i,k)` 的 O(k−i) 探测压成一次区间最大值，
  本机 3000 次 `wrap`（atoms=1764、少标点）实测：`cjk_break_at_punct_only=true` +
  `wrap_sentence=true` 由 2.39s 降到 1.65s（−31%）；标点正常的文本三种模式互相持平（差 ≤3%）。
  代价是 `qual` 改为全 token 预计算，少标点 + 严格默认模式下略慢约 5%。
- **严格模式下行尾的下限统一施加到所有六个出口**（`cjk_break_at_punct_only=true` +
  `wrap_sentence=false`）。此前只有「贪心断点」与「PUSH 回退」两个出口接了回落，溢出与 PULL
  两个没接；现共用一个收尾函数。落点不够格时按两岔处理：拟合区内**有**标点候选 → 取最远且过
  `allow_c` 下限者，一个都没过下限且落点短得离谱（不足四分之一可用宽）→ 整行溢出；拟合区内
  **一个标点候选都没有** → 维持现状，落在 atomic 边界（既有裁定）。非严格模式与
  `wrap_sentence=true` 逐字节不受影响。

### Added

- **短尾巴并入**（严格模式）：断点之后若在四分之一行宽之内就遇到句级标点，把那一截并进本行，
  宁可有限超宽，也不给下一行留一个十几列的孤行。实例（width=80）——此前折出
  `……六成记在中国香港名下，`(72 列) 与 `十年未降[^hkbook]。`(19 列) 两行，现并为一行。
  成因是两条各自正确的规则叠加：句号落在 91 列、已在拟合区外，逐行贪心够不着；而「句级标点
  不设短行下限」又让那 19 列的尾巴立刻成行。本行行尾已是句号时不并入（否则连续短句会被黏成
  一行），段落最后一行也不并入（末行短本来就正常）。
- **属性测试** `tests/unit/test_property.lua`：随机原子流 × 全模式矩阵，断言四条独立于实现的
  不变式——非空格字符序列守恒、禁则、严格模式不在汉字之间断、幂等。seed 固定，CI 可复现，
  `MDWRAP_PROP_CASES` 可加大深跑；本机 5 个 seed × 86,400 次 `wrap` 全绿。下面两条缺陷即由它抓到。

### Fixed

- **禁后断标点不再被迫独占一行。** `《` 之后紧跟一个比整行还宽的 token（如长 URL）时，PUSH
  一路退到行首仍找不到可断点，旧判据「退没退回到行首」便让 `《` 独占一行，禁则当场破。改为
  判「退回去的落点可不可断」，退无可退时向前拉到第一个可断处，宁可该行超宽（4.3.6 允许）。
- **`．`（U+FF0E 全角句点）的分类冲突。** 它此前同时在 `forbit_break_before` 与
  `forbit_break_after` 两张表里——既不能落行首又不能落行尾，折行必然破其中一条；且
  `char_attr` 的判定顺序把它归成了「开括号类」。它是句末标点，语义等同 `。`，现从
  `forbit_break_after` 移除。既有 golden 零差异。
- **②「禁前断标点拉回」（PULL）的落点不再停在非标点处。** 该分支此前完全没接回落，落点可能是
  全角括号旁或 atomic 边界。禁则刻意为之的落点（`adm == 0`）不受影响。
- **③ 回落不再折出极短的行。** `punct_far` 此前不设任何短行下限，实测会产出「6 列的行后面跟一个
  76 列的行」这种两头都坏的输出；现回落首选过 `allow_c` 的最远标点，一个都没过且落点不足半个
  可用宽时宁可整行溢出。略短的落点（如 24 列 / 40 列可用宽）仍保留，不换成更坏的超宽行。
- **④′ 溢出不再停在盘古空格上。** `overflow_to_punct` 此前前向扫描的是「下一个**可断点**」而非
  「下一个**合法行尾**」，且进入该分支时盘古档已放开，于是会把一个英文词单独甩成一行、行尾
  停在汉字上——正是严格模式声称要杜绝的两件事。现扫描停在段尾、ZWSP、标点、不涉中文的断点或
  atomic 边界，跳过汉字间与盘古空格，也跳过「可断但不配当行尾」的全角括号旁。
- 新增 golden `45-shortline-overflow`、`46-overflow-legal-end` 固化上述两类回归，
  `47-fallback-short-line`、`48-short-tail-merge` 固化两条来自真实文稿的反馈。

### 未做

- **待办 ①（中文与链接／数学／引用／shortcode 之间的空格降档）经实测判定不做。** 降档会破坏
  幂等不变式：折行一旦把 CJK 与 atomic 分到两行，`merge_lines` 重折合并时会在中间插一个空格，
  于是同一个边界在「粘连」与「带空格」之间来回变化，两档不同即 `format(format(x)) ~= format(x)`。
  裁定：该手写空格必须与粘连边界同档（恒可断）。详见 `tests/golden/DECISIONS.md` 第 12 节。

## [0.3.1] - 2026-09-24

### Fixed

- **严格模式下不再断在盘古空格处**（`cjk_break_at_punct_only=true`，默认）：CJK 与拉丁／行内代码
  之间的那个半角空格（盘古之白）此前与英文词间空格同等对待，成了汉字间禁断后回退时的兜底断点，
  把「2023 年间」「而 APEC」这类语义单元劈开。现降级为次级断点——默认不可断，仅当拟合区内
  一个标点断点都没有时才放开，且仍排在汉字间硬断之前；英文词间空格（两侧同为拉丁）不受影响。
  该边界的判据由 `spacing.is_pangu_boundary` 单一定义，插入与降级共用，故与源文件是否已排版无关。
- **严格模式下行尾必落标点**：行尾若会停在涉及中文的非标点断点（盘古空格兜底、行内代码／链接等
  atomic 边界），改为无视 `clause` 短行下限，回落到拟合区内最远的标点断点（含顿号）。
  纯拉丁语境的断点不涉中文，不触发回落。两项均不新增配置项，随 `cjk_break_at_punct_only` 生效。

## [0.3.0] - 2026-06-15

### Added

- 手动关闭折行：`mdwrap-ignore` 系标记（文件 / 区域 / 块 / 行四级）。载体为独占一行的 HTML 注释
  （大小写不敏感、内部空白宽松），文件级额外支持 frontmatter 顶层 `mdwrap: false`：
  - `<!-- mdwrap-ignore-file -->` 或 `mdwrap: false` → 整文件跳过；
  - `<!-- mdwrap-ignore-start -->` … `<!-- mdwrap-ignore-end -->` → 区间内所有块跳过
    （未配对 start 延伸到 EOF，未配对 end 无害）；
  - `<!-- mdwrap-ignore -->` → 其后第一个 wrap/table 块跳过；
  - `<!-- mdwrap-ignore-line -->` → 其下一源行跳过（在段落内则拆段，仅护该行）。

  被忽略内容**逐字节不变**（等同 preserve），保持幂等。新增纯模块 `ignore.lua`（scan + apply，
  禁 require vim，可裸 luajit 测）；`blocks.split` / `split_lines` 末尾接 `ignore.apply`，
  所有入口（`format_buffer` / `format_lines` / `format_file` / formatexpr / `gqq` / `:MdwrapFormat`）
  自动获得忽略行为。新增 golden 用例 39–43 与纯函数单测 `test_ignore.lua`。

## [0.2.0] - 2026-06-15

### Added

- 管道表格按列视觉宽对齐（`format_tables`，默认开）：表格**不折行**，按列「视觉宽度」（CJK 计 2）
  补空格使各列对齐；对齐语义由分隔行 `:--`/`--:`/`:--:` 决定（左/右/居中），居中奇数余量放右侧；
  单元格内容复用 `cjk_english_spacing` 做盘古空格。`format_tables=false` 时表格整块 preserve 字节不变。
  新增纯模块 `table_align.lua`（禁 require vim，可裸 luajit 测）；新增 golden 用例 38-table-align。

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
