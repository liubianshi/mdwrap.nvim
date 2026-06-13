# Golden 用例的用户裁定（偏离设计文档处）

本文件记录 M0 阶段经用户确认、与 `mdwrap-nvim-design.md` 有出入的裁定。
实现时以这些裁定（及对应 golden 用例）为准,**不要照搬被推翻的 spec 措辞**。

## 1. 零宽空格（ZWSP, U+200B）= 最高优先级断行机会，且保留

- 设计文档 4.2.4 说 ZWSP 是最高优先级断点、输出保留该字符。
- **用户裁定（多轮收敛）**：ZWSP 是**最高优先级断行机会**（不强制空行，但在拟合区内
  优先于句末/贪心断点），**并保留**在输出中。
- **为何保留**：ZWSP 若被消费,则一次 format 后断点提示消失,二次 format 按宽度重折
  → 违反幂等不变量（设计文档 6.2 之一）。保留 ZWSP（断点处留在上一行行尾、零宽）后,
  二次 format 经 `merge_lines` 重新并回行内、再次在该处优先断行 → 幂等成立。
- **实现**：`layout.wrap` 把 ZWSP 文本并入前一 token 末尾并标记其后为 zwsp 优先断点；
  `merge_lines` 特判行尾 ZWSP 合并时不插空格。
- 验收以 `23-zwsp/` 为准（expected 的 L1 行尾保留 ZWSP）。
- 实测坑：`strdisplaywidth('​') == 6`（nvim 的 `<200b>` 转义占位）,故 ZWSP 在 atoms 层
  特判为 0 宽原子,不经生产 `width_fn` 度量。

## 2. 行内代码边界补盘古空格（仅 code 一类 atomic）

- 设计文档 4.4 说「所有 atomic 原子（代码、链接、数学、citation、shortcode）的边界都不补空格,以 golden 21 为准」。
- **用户裁定**：行内代码 `` `code` `` 的 CJK 边界**要补**半角空格。
- 这是全局规则,连带影响 `06-inline-code/`（其 `code_span` 紧贴中文亦补空格）与 `21-cjk-spacing/`。
- 其余 atomic（链接、citation、数学、shortcode）维持「边界不补空格」,
  形成「**仅行内代码享受盘古空格**」的规则；如需扩展到其他 atomic,需另行裁定并改对应 golden。

## 3. 独占行的裸 URL 两侧不补盘古空格

- **用户裁定**：超宽独占一行的裸 URL（`word` 原子）两侧不补空格。
- 对 `08-long-url/` 的 expected 字节无影响（URL 必然独占行,边界空格本就落在断行处被消费）,
  但确立规则语义：裸 URL 不参与盘古空格处理。

## 4. 行内数学 `$` 定界符被 conceal,不计入显示宽度

- 设计文档 4.2.3 说「`$` 行内数学:conceal 为 0（定界符显示）」,即 `$` 计入宽度。
- **用户裁定**：`$` 定界符**被 conceal,不计入宽度**,只有 `$...$` 内部内容计宽。
- 验收以 `11-inline-math/` 为准（`$\alpha + \beta$` 视觉宽 14 而非 16）。
- **M2 实测坐实**：nvim 内置 `markdown_inline` 的 `highlights` 查询**不** conceal `$`
  （probe 显示数学区间无任何 conceal 捕获）。用户实际环境用 **render-markdown.nvim**
  对 `$` 做 conceal,故裁定成立。
- **实现**：`atoms.lua` 把 `latex_span_delimiter`（`$`）作为**内建 conceal**（手动扣宽 0），
  使 headless golden（无 render-markdown）确定可复现,并匹配用户真实显示。
  这是范围限定于数学定界符的显式例外,不破坏「conceal 主要来自 highlights 查询」的总原则。
- **延伸**：更完整的方案是 atoms 同时读取活动 conceal extmark（render-markdown 等注入的），
  v1 暂只内建处理 `$`;其余 conceal 仍以 highlights 查询为准。

# 编辑器集成阶段的裁定（设计文档未覆盖处）

以下一条不影响 golden 行为，是对设计文档 4.5／第 5 节编辑器集成面的补充裁定，
源于「mdwrap 能否作为 conform.nvim 的 filter」这一问题的收敛。

## 7. formatexpr 与 conform.nvim 共存，并提供 `set_formatexpr` 开关

- **背景**：用户同时使用 [conform.nvim](https://github.com/stevearc/conform.nvim) 做格式化编排。
  实测其 formatter 配置支持**进程内 Lua 形态**——`format = function(self, ctx, lines, callback)`,
  与 `command` 互斥（见 `conform/runner.lua:340`、内置 `trim_whitespace`）;`ctx` 携带活 bufnr
  `ctx.buf`、`ctx.range`、`ctx.shiftwidth`。故 mdwrap 可作为**一等 Lua formatter**接入,
  而非退化为 stdin→stdout 的 CLI filter——后者拿不到 bufnr,会丢失 tree-sitter 树与窗口 conceal,
  从根本上违背「视觉宽度唯一真相来自活 buffer conceal 元数据」的设计前提。
- **用户裁定**：`formatexpr` 与 conform **共存**——`gq` 系列仍走 `formatexpr` 手动折行,
  conform 负责 format-on-save／`:Format` 编排;同时**提供 `set_formatexpr`（默认 `true`）开关**,
  置 `false` 时 `plugin/mdwrap.lua` 不再对 `markdown/quarto/pandoc/rmd` 注册 `formatexpr`,
  把 `gq` 让回 Neovim 默认行为,由 conform 单独接管折行。
- **作用点**：开关只控制 `plugin/mdwrap.lua` 的 FileType autocmd 是否设置
  `formatexpr=v:lua.require'mdwrap'.formatexpr()`（设计文档:275）;`:MdwrapFormat`、
  `format_buffer`、`format_lines` 一概不受影响。
- **新增公开 API**：`require('mdwrap').format_lines(lines, opts) -> string[]`,
  lines 进 / lines 出,`opts` 含 `bufnr`（取环境量,如窗口 `conceallevel`）与 `range`。
  `format_buffer` 复用同一核心(读 buffer 行 → `format_lines` → 回写),纯函数层不受影响。
- **链式调用坑**：conform 串多个 formatter 时在内存里逐棒传递 `lines`,**中途不回写 buffer**,
  故当 mdwrap 排在别的 markdown formatter 之后时,`ctx.buf` 的 tree-sitter 树相对 `lines` 是**旧的**。
  裁定：`format_lines` 内部优先用
  `vim.treesitter.get_string_parser(table.concat(lines,'\n'),'markdown')` 从 `lines` 现解析,
  `ctx.buf` 仅用于读窗口 `conceallevel` 等环境量,使链式与否都正确。
- 接入示例见 README「与 conform.nvim 集成」一节。

# 类型系统阶段的工具裁定（偏离类型系统建设计划处）

以下两条不影响 golden 行为，而是「为 mdwrap.nvim 建立 LuaLS 规范类型系统」一计划中、
被本机 `lua-language-server 3.18.2-dev` 实测推翻的假设。`tests/run_typecheck.sh` 以这两条为准。

## 5. typecheck 判定信号：退出码 + 输出问题计数，而非 `check.json`

- 计划原拟「以 `--logpath` 下是否生成 `check.json` 判定通过/失败」。
- **实测推翻**：该版本 `--check` **从不生成 `check.json`**——有 8 个问题时 logpath 下只有 `.log`,
  首版脚本据此误判「passed」。
- **改用裁定**：失败信号 = `lua-language-server` **退出码非 0** *或* 输出末行 `N problems found`
  的 **N>0**,二者取或（退出码本机实测可靠;计数解析作为退出码不可靠版本的兜底）。
- 已用「故意把 `Atom.width` 写成字符串」验证此信号可靠地捕获(EXIT=1、捕获
  `Cannot assign string to integer`)。

## 6. 类型校验须给「累加器局部变量」显式标 `---@type`，返回注解不足以咬住

- 计划设想「写错 `Atom.width` 即报错」。
- **实测推翻**：仅靠 `---@return mdwrap.Atom[]`,LuaLS **不**回灌校验 `local out = {}` 里每个表
  字面量的字段——返回类型只约束调用方,不反推构造端。
- **改用裁定**：在构造原子/块的累加器局部变量上显式标注——`spacing.apply` 的 `out`、
  `atoms.atomize` 的 `atoms`（均 `---@type mdwrap.Atom[]`）、`blocks.split` 的 `out`
  （`---@type mdwrap.Block[]`）——字面量字段才进入校验。这是类型系统能否抓到 bug 的开关,
  也契合计划「emit 构造的表即 Atom」「out 元素为 Block」的本意。
- **连带（纯注解、零逻辑改动）**：`mdwrap.FormatOpts` 须自身也标 `(partial)`（`(partial)` 不沿
  继承链传递,否则父类字段被当作必填）;`init.format_buffer` 的 `bufnr` 用 `---@cast bufnr integer`
  收窄 `and/or` 惯用法;两处 tree-sitter `parse()[1]` 的 `need-check-nil` 与 `minimal_init` 的
  `vim.cmd` 误报以行级 `---@diagnostic disable-next-line` 静默。

# 折行行为扩展（偏离设计文档「v1 只实现 zh」处）

以下一条扩展了断句规则的语言覆盖。设计文档 2.3／3.5（第 37 行）把英文句末规则集列为
`lang=en`、**推迟到 v2**;经用户裁定提前在 v1 落地,且不走 `lang` 门控。验收以
`27-en-sentence-preferred`／`28-en-abbreviation`／`29-en-colon`（均 width=40）为准。

## 8. 英文语义断行：半角终止符并入分隔符集 + 缩写保护，语言无关

- **背景**：设计 v1 的 `sentence_sep`/`clause_sep` 只收全角标点,英文段在 `wrap_sentence=false`
  下走不到句末偏好分支 → 退化为「断在最后一个能塞下的空格」,违反用户全局 Markdown 规则第 3 条
  「never wrap at the nearest space」。REF 的 zh 句末正则本含半角 `,.;:!?`,但被
  `_sentence_end` 的「行尾 30 字符全 ASCII 即不算句末」启发式压制——那是为「中文为主、偶夹英文」
  设计的,对英文为主的段落方向相反。
- **用户裁定（两问收敛）**：
  1. **始终生效、语言无关**——半角 `. : ; ! ?` 并入 `sentence_sep`、半角 `,` 与顿号 `、`
     并入 `clause_sep`,与全角并列;**丢弃** REF 的 30-字符-ASCII 启发式。中英混排同段落里
     英文 `.`/`:` 也成为合法断点。顿号 `、` 此前连中文都漏收,一并补上。
  2. **现在就加缩写保护**——`chardata.is_abbrev(token)`:token 以半角 `.` 结尾且去尾点小写后
     命中缩写表（`mr/dr/e.g/etc/u.s/...`,约 80 项）、或为**单个 ASCII 字母**（首字母缩写 `A.`/`U.`）
     时,`layout.level_of` 把该断点降级为 `normal`,避免 `Dr. Smith`/`e.g. foo` 被误断。
     代价:真句末若恰好撞上 `etc.` 会少断一处——语义断行通行取舍,优于句中每个缩写都误断。
- **作用点**：纯数据/纯逻辑——`chardata.lua`（两张分隔符表 + `abbreviations`/`is_abbrev`）与
  `layout.lua` 的 `level_of`（唯一逻辑改动:`.` 触发时查 `is_abbrev`）。短行容忍度
  `min(60,w-20)`/`min(12,w-20)` 不变,英文自动复用既有「句末/子句优先 + 短行容忍」机制。
- **零回归**：旧 26 个 golden 字节不变（含英文的用例未位移）,故未触碰任何既有 `expected`。

