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
- **延伸（M5-A 落地，已推翻「v1 只内建」）**：`atoms.lua` 的 `BUILTIN_CONCEAL_TYPES`
  （`latex_span_delimiter`）**已删除**,`$` 不再当特例,统一并入通用 extmark 路径(见第 9 条)。
  连带:golden 11 新增 `setup.lua` 注入 `$` conceal 模拟 render-markdown,`expected.md` 字节不变。
  其余 conceal 仍以 highlights 查询为准;两源(查询 + extmark)按字节并集去重。

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

# 插件无关的「外部渲染 conceal」宽度感知（M5）

设计文档只覆盖 tree-sitter conceal 与内建 `$`。本条记录把宽度真相源扩展到**渲染插件注入的
持久 extmark**（render-markdown.nvim / markview.nvim 等）这一裁定。M5-A 落地行内,M5-B 落地前缀。

## 9. 通用 extmark conceal 路线：全 namespace 自动过滤、行内 + 前缀、conform 逐行内容保护

- **背景**：用户用 render-markdown.nvim 渲染中文 Markdown,它以**持久 extmark**改变实际显示
  宽度——`conceal` 隐藏 `**`/链接 url/`$`/列表·引用前缀符,inline `virt_text` 插图标
  （链接图标、bullet 图标）。`[文档](https://很长的url)` 显示成「图标 + 文档」,40 字 url 塌成
  2 宽图标。mdwrap 只认 tree-sitter conceal,折出来的行与屏幕对不齐。
- **用户裁定**：
  1. **插件无关**——不绑 render-markdown（将来可能换 markview）。用 **extmark 为通用真相源**:
     任何同机制渲染插件都往 buffer 放持久 extmark,读**所有 namespace**（`nvim_buf_get_extmarks`
     的 ns=`-1`）,按「带 conceal / 带 inline virt_text」**自动过滤**,不引入 allowlist 配置。
  2. **覆盖行内 + 前缀**两类宽度（M5-A 行内 / M5-B 前缀）。
  3. **`$` 等不再当特例**——`$`、`**` 都能用 extmark 表达,删 `BUILTIN_CONCEAL_TYPES`,统一走
     extmark 路径（见第 4 条修订）。注:tree-sitter 的 `**`/反引号 conceal 是 decoration
     provider 的**临时**标记,`nvim_buf_get_extmarks` 物理上读不到,**仍走 highlights 查询源**;
     故终局是「查询源 + extmark 源」两路并存,重叠按字节并集去重,消不成一路。
- **宽度模型泛化**：由「自然宽 − 隐藏」改为「自然宽 − 隐藏(并集去重) + 加」。extmark 的
  conceal 净减、inline virt_text 净加,组合后增量**可正可负**。`atoms.visual_width` 与 cjk/word
  原子宽都按此算;inline 图标锚点落在某原子字节区间内即并入该原子宽（链接图标自然并入
  `inline_link` atomic 段；普通文本图标 attach 到包含它的 cjk/word 原子,可接受）。
- **坐标映射（核心难点）**：extmark 在**原始 buffer (row,col)**,conceal 区间须翻译到
  `merge_lines` 合成的**逻辑串字节坐标**才能喂 `atomize`。分段线性:
  `layout.merge_lines_mapped` 产出 `segs[k]={lstart,lend,strip_lead}`;`blocks.strip_prefix`
  额外返回每行剥掉的前缀字节数 `removed`（存入 `block.content_removed`）。则
  `源行偏移 = buffer_col − removed_k`,`逻辑偏移 = seg.lstart + (源行偏移 − strip_lead)`;
  `col < removed_k` 的落在前缀区（M5-B）。`conceal.lua` 是唯一新碰 extmark API 的 vim 层模块;
  `layout`/`spacing`/`chardata` 仍零 vim 依赖（`merge_lines_mapped` 与前缀宽度覆盖均纯函数,可单测）。
- **conform 链式失同步保护**：conform 串多个 formatter 时在内存里逐棒传 `lines`,中途不回写
  buffer,故 `ctx.buf` 的 extmark 相对传入 `lines` 可能是旧的。裁定:`conceal.gather` 接
  `expected_lines`,**逐行内容比对**,buffer 行与传入行不符则**丢弃该行 extmark**（回退纯
  tree-sitter）。`format_buffer` 路径 buffer 即真相源,不传 `expected_lines`。
- **anti-conceal 光标行**：render-markdown 的 anti-conceal 使**光标所在行**临时显示原始标记
  （不渲染）。mdwrap 按**当前 extmark 实况**记账——光标行此刻无渲染 extmark → 按原始宽折行,
  与「光标行此刻显示原始标记」一致;不强制重渲染。**已知行为**,非缺陷。
- **门控**：`respect_conceallevel=false` 或 `respect_extmark_conceal=false` 或窗口
  `conceallevel=0` → 不读 extmark（增量 0,退化为纯 tree-sitter 宽度）。headless 无渲染插件
  ⇒ 无持久 extmark ⇒ 增量 0 ⇒ 既有 29 golden 零回归。
- **注入式 golden**：`test_runner` 支持每例可选 `setup.lua`（签名 `function(bufnr)`),格式化前
  注入合成 extmark 模拟渲染插件。须**按内容定位**（扫 `[..](..)`/`$..$`/段首）,因 test_runner
  的幂等/块外/语义复跑会在重折后的 buffer 上再灌一次,固定坐标会错位。新增:
  `30-extmark-inline-link`（链接塌缩,隐藏 + 图标）、`31-extmark-highlight`（inline 图标 +add
  把断点前移一字）、`32-extmark-list-prefix`（任务框 `- [ ] ` 塌成图标,前缀渲染宽 6→2）、
  `33-extmark-quote-prefix`（引用 `> ` 渲成 0 宽行内前缀,首行+续行前缀同覆盖）。
- **前缀净增量实现细化**：前缀区隐藏宽用 `block.prefix_first`/`prefix_rest` 字符串切片量
  （`width_fn(prefix:sub(cs+1, min(ce,removed)))`），**未**在 block 另存 `content_prefix`——
  标准 `- [ ] `/`> ` 前缀下,首行 prefix_first、续行 prefix_rest 即剥掉的前缀文本,够用且更省。
  续行 prefix_rest_width 取**首个有前缀 mark 的续行** delta 为代表（渲染一致，互为代表）。
  前缀渲染宽 = 字面宽 + (Σadd − Σhidden) ≥ 0（hidden 是前缀子串,必 ≤ 字面宽;add ≥ 0）。

# 中文严格「只在标点断行」+ 字间断兜底（cjk_break_at_punct_only，默认开）

- **背景**：design 4.3.4 的 normal 等级允许**任意相邻 CJK 字之间断行**（传统逐字排版）。当一行的
  标点断点（句末／逗号）都被短行容忍度拒绝时,折行退化为「在某个汉字之间断」,与用户全局 Markdown
  规则「中文 punctuation is the only legal break point」相悖。README 第 14 行那条特性正是触发此现象
  的实例：`width=70` 时断在「显示」与「一致」之间。
- **用户裁定（两问收敛）**：
  1. **默认中文仅在标点处断行**——`gap_breakable` 中普通 CJK 字间不再是断点,只有全角标点旁
     （`punct_no_break_before`／`punct_no_break_after`）才可断。
  2. **字间断仅作兜底**——遇到「比一行还长且中间无任何标点」的子句（否则无合法断点,会退化成单字
     一行）,才临时放开字间断按宽填满。
  3. **落地为配置开关 `cjk_break_at_punct_only`,默认 `true`**；置 `false` 退回传统逐字可断。
- **实现**：纯逻辑,集中在 `layout.wrap`。每行循环开始处用「仅标点」口径（`allow_cjk_cur=false`）探测
  拟合区 [i,k] 有无断点：有 → 严格只在标点断；一个都没有 → 置 `allow_cjk_cur=true` 兜底。新增
  `is_punct_class` 区分「全角标点」与「普通 CJK」;`config.lua`／`types.lua`／`init.lua` 透传字段。
- **零回归**：既有 33 个 golden 全部经各自 `opts.lua` 注入 `cjk_break_at_punct_only=false` 保持字节
  不变（旧用例 `expected` 一字未改,守住「不得为过测试改 expected」红线）；严格模式另立新用例覆盖。

# 括号配对作整体（bracket_as_unit，默认开）

- **背景**：括号内含逗号时,子句断点会把括号从中间劈开（如 `（插件无关，见上「外部渲染感知」）`
  在内部逗号断）。用户裁定:括号配对应作整体,能整组放进一行就不在内部断。
- **用户裁定（两问收敛）**：
  1. **落地为配置开关 `bracket_as_unit`,默认 `true`**。
  2. **覆盖中英文括号,不含引号**——`（）《》【】〔〕〈〉` + 半角 `()[]{}`；引号「」『』不锁
     （引号内仍可按标点断）。配对表 `chardata.bracket_open`（open 码点 → close 码点）。
- **实现**：纯逻辑,`layout.wrap` 用栈匹配配对括号得组区间 `[open,close]`,**组宽 ≤ 续行整行可用宽
  （`width − prefix_rest_width`）**时锁定组内所有间隙（`locked_gap[k]=true` → `gap_breakable` 返回
  false）。判据是「能放进某一行」而非「放进当前行」:组放不下当前行剩余时,`（` 之前未锁仍可断,整组
  下移；组宽超一整行才解锁、回退逐标点/字间兜底。优先级低于 ZWSP（括号内 ZWSP 仍可断）。
  半角括号紧贴内容时落在 word 原子首/尾字符,故按 token 文本首/末字符判定 open/close。
- **零回归**：既有 33 个 golden 默认开 `bracket_as_unit` 全部字节不变（无「组放不下当前行剩余但放得下
  整行且内含可断点」的情形）,故无需注入 `false`。

# 句末优先模式取消字间断兜底，改为整段溢出（按 wrap_sentence 分流）

- **背景**：严格模式初版「无标点超长子句字间断兜底」对所有模式生效。用户修订裁定:
  `wrap_sentence=false`（句末优先排版）时,超长行也绝不在非标点处断——宁可整段溢出。
  这**修订**了前文「字间断仅作兜底」一节的无条件兜底。
- **裁定（按模式分流）**：
  - `wrap_sentence=true`（按宽填满）→ 字间断兜底（保留,符合「填满」语义）。
  - `wrap_sentence=false`（默认）→ 整段溢出到下一个标点（或行尾）,不在非标点处断。
- **atomic 边界例外**：链接/引用/数学/shortcode 等 atomic 原子是不可分单元,其边界**恒可断**
  （相当于一个「词」,不受「仅标点断」约束）——在其前后换行是合理排版,非「汉字硬断」。
  故含 atomic 的行不会溢出,在 atomic 边界断（golden 07/09/10/11 据此不变）。
- **实现**：`layout.wrap` 兜底探测分流出 `overflow_to_punct`（从拟合边界找下一个标点断点或行尾）;
  `gap_breakable` 加「`a/b` 任一为 atomic class 则恒可断」。
- **golden 调整**：13/14/33（正文纯 CJK 无标点,原测字间断的续行前缀）正文加标点,保「续行前缀」
  覆盖；新增 `34-overflow-nopunct` 覆盖溢出行为。**这是为适配修订后的用户需求,经候选确认后改,
  非为过测试擅改 expected。**

# 句末对齐断行（句级标点无短行下限）+ 全角句末标点分类修复

- **背景**：用户裁定「尽量一句一行」——句级标点(`。；：！？．`)断行应压倒填满,行尾力求落在句末,
  即使行较短。
- **裁定（B：句末对齐、可含多句）**：`wrap_sentence=false` 下,句级断点**取消短行下限**(去掉
  `allow_s`),取拟合区内**最远**的句级标点;一行可含多个短分句,但行尾必落句级标点,绝不跨句填到
  次级(逗号/顿号)或溢出。次级 `clause` 仍保留 `allow_c` 下限。
- **潜伏缺陷修复**：全角 `；：！？．`(`0xFF1B/0xFF1A/0xFF01/0xFF1F/0xFF0E`)原本**只在 `sentence_sep`
  (断行偏好)、却不在 `forbit_break_before`(字符分类)**,被 `char_attr` 当成普通 CJK → atom class=cjk。
  于是严格模式下 `gap_breakable`(认 atom class)不把它们当标点断点,`level_of`(认 sentence_sep)虽判
  sentence 却因 `after_breakable` 为假而记不上 `sent`。旧「字间断兜底」碰巧掩盖,改溢出后暴露。
  **修复:把这 5 个码点补进 `forbit_break_before`**(句末标点绝不落行首,本就该在此表)。
  教训:标点须同时进 `sentence_sep`/`clause_sep`(偏好)与 `forbit_break_*`(分类)两套表才完整生效。

# gqq 只折当前行（偏离 design §146）

- **背景**：design §146 规定 `gqq`/`gqip`/可视 `gq` 都「扩展到完整块」。用户裁定 `gqq` 只折当前行,
  不波及整段。
- **实测依据**：`formatexpr` 下 `gqq` → `v:count==1`;`gqip`(多行段落)→ `count>1`;可视/`gqj` → `count>1`。
- **裁定（修订）**：`formatexpr` 中 `count<=1` 且当前行落在**多行 wrap 块**内 → **只用 mdwrap 折当前行**
  (`format_single_line`:把该行当单行块、不合并整段)。`gqip`/可视 `gq`(count>1)与单行块仍走 mdwrap 整块。
- **修订原因**：原裁定此处 `return 1` 回退 Neovim 默认折行引擎,但该引擎不在 CJK 之间断行——对中文
  等于「不折」。意图(「只折当前行」)不变,机制从「回退默认」改为「mdwrap 单行折行」,中文才真正生效。


# 盘古空格降级 + 行尾必落标点（B+A，严格模式）

- **背景**：`cjk_break_at_punct_only` 堵死了「汉字之间硬断」这条退路,却没堵盘古空格。
  `spacing.apply` 插入的 CJK↔拉丁空格在原子流里 `class=="space"`,与原文的英文词间空格毫无区别,
  而 `gap_breakable` 对 `space` 无条件放行——于是它成了 PUSH 回退时的「救命稻草」。
  用户实例（width≥90）：
  「……各方普遍以补贴争取项目，而 APEC 成员在 2021 至 2023 / 年间实施的补贴类措施……」
  断在「2023」与「年间」之间,把一个语义单元劈开。成因是两条规则叠加:
  ① 拟合区内最后一个逗号 `cum=62` 低于 `clause` 短行门槛 `avail−allow_c`,被拒；
  ② 贪心点落在汉字间(严格模式不可断)→ PUSH 回退,撞上的第一个可断间隙就是那个盘古空格。
- **用户裁定（B+A 两项同时落地，不新增配置项，随 `cjk_break_at_punct_only` 生效）**：
  1. **B — 盘古空格降级**：落在 CJK↔拉丁／行内代码边界上的半角空格,严格模式下**默认不是断点**,
     仅当拟合区内一个标点断点都没有时才放开兜底（`allow_pangu_cur`）,且仍排在汉字间硬断之前。
     原文的英文词间空格（两侧同为拉丁）不受影响,照常可断。
     **判据是文本属性,不是来源标记**——`spacing.is_pangu_boundary` 是该边界的唯一定义,
     插入与降级共用它。初版把它做成 `spacing.apply` 打的 `pangu=true` 标记,是错的:
     `need_space` 的幂等守卫使**原文已写好的空格永远拿不到标记**,于是 B 对正常输入完全失效
     (修好用户那句的其实是 A),而在「源文本未写空格」时第一遍生效、第二遍失效,
     `wrap_sentence=true` 下实测 `format(format(x)) ~= format(x)`。
  2. **A — 行尾必落标点**：严格模式 + 句末优先下,若行尾会停在**涉及中文的非标点断点**
     （盘古空格兜底、行内代码／链接等 atomic 边界）,则**无视 `clause` 短行下限**,
     回落到拟合区内最远的标点断点（`punct_far`,含顿号）。纯拉丁语境的断点不涉中文,不触发回落。
- **实现**：纯逻辑,`layout.wrap`。断行许可从两档变三档——每行开始先以「仅标点」口径探测拟合区,
  无断点则放开盘古空格再探测,仍无才按 `wrap_sentence` 分流（字间断兜底／溢出到下一个标点）。
  新增 `punct_break`（行尾是否落标点,复用 `level_of` 并补顿号）、`cjk_involved`、`needs_punct_end`；
  回落点挂在「贪心断点」与「PUSH 回退」两个分支上,`ZWSP`／`sentence`／`colon`／`clause` 四个
  既有优先级分支不受影响（ZWSP 是用户手工标记,绝不被回落覆盖）。
- **零回归**：既有 43 个 golden 全绿,三不变式全绿；`allow_pangu_cur = not punct_only`,
  非严格模式（既有用例注入 `cjk_break_at_punct_only=false`）行为与改动前逐字节一致。
  新用例 `44-pangu-space-break`（width=40）固化三个场景:回落到逗号（A）、
  无标点时盘古空格兜底仍可断（第二档）、纯英文段落的词间空格不受影响、atomic 边界回落（A）。
- **已知待办**（`/simplify` 四路审查记录）：~~① 链接／数学／引用／shortcode 与中文之间的
  空格仍是无条件断点~~、~~② PULL 分支（禁前断标点拉回）未接 `needs_punct_end`~~、
  ~~③ `punct_far` 不设短行下限,极端输入下 A 可能折出很短的行~~、~~④ 逐行探测比改前多一档,
  `wrap_sentence=true` + 严格模式实测慢约 40%~~ —— **四条已在「断点档位统一」一节处理完毕**
  （①经审查判定不做,②③④ 已修）。


# 断点档位统一：adm / qual / wide 三个静态数组 + 出口收尾函数

本节处理上一节末尾记的四条待办 ①②③④，外加审查中发现的第五条（记作 ④′）。四个症状同源，
根因不在四处各自的实现，而在 `layout.wrap` 里有**三套重叠的判定各管一段**——
`gap_breakable`（这个间隙能不能断）、`level_of`（断在哪一级标点）、
`punct_break`／`needs_punct_end`（行尾落在这里合不合法）。三者谁都看不见全貌，
于是每加一条规则要在三处各补一刀，而四个决定 `endj` 的出口只有其中两个接上了回落逻辑。

分两阶段落地：阶段 A 零行为变更（只换判定的数据结构），阶段 B 才改选择规则。
阶段 A 零差异，故阶段 B 跑出的任何差异都必定源自 B 本身，无需再区分是重构写错了还是预期变化。

## 10. 断点的三个属性互相独立，压不成一根有序标尺

- **裁定**：每个间隙由三个**静态**数组描述，整段算一次，逐行只做一趟扫描：
  - `adm[t]` ∈ 0..5 —— 准入档：断在 token t 之后**能不能断**；
  - `qual[t]` ∈ 0..4 —— 质量档：断在这里，行尾**落在什么标点上**（即旧 `level_of` 的编码）；
  - `wide[t]` ∈ bool —— 该间隙**涉不涉中文**。
- **为何不能合成一根标尺**（这是本次两轮审查最贵的发现，各指一个方向）：
  - 全角括号旁 `《「（》」）`：**可断**（`adm=4`，恒为断行机会）却**不配当行尾**（`qual=0`，不是句读）。
    单标尺方案把「可断且非标点且涉中文」一律归为汉字档，严格模式下
    `甲乙丙丁《书名》戊己` 会退化成不可断。
  - `Hello!|世`（半角句读粘连汉字）：**配当行尾**（`qual=4`）却在严格模式**不可断**（`adm=1`）。
    让 `qual` 参与准入即破此例。
  - 纯拉丁的粘连 atomic 边界：可断（`adm=3`），但「涉不涉中文」从 `adm` **推不出来**，
    必须单独存 `wide`。
- **逐行状态只剩一个 `min_tier` 整数**，取代 `allow_cjk_cur`／`allow_pangu_cur` 两个布尔开关；
  `has_break` 的逐行探测删除——「区间内按某口径有无断点」等价于「区间最高档 >= 该口径阈值」。
  这修掉 ④：3000 次 `wrap`（atoms=1764、少标点）下 `wrap_sentence=true` + 严格模式
  由 2.39s 降到 1.65s（−31%）；代价是 `qual` 改为全 token 预计算，严格默认模式略慢约 5%。
- **两条结构不变式**（写进代码注释，它们是两条既有裁定能守住的唯一依靠）：
  1. **合法性检查只看 `qual` / `wide`，绝不看 `adm`。** ZWSP 落点的 `qual` 是 normal，
     若改用「可断性」口径，CJK + ZWSP 的落点会被判不合法而遭回落覆盖，第 1 条裁定当场破。
  2. **选择用的 if 链顺序不得重排。** `zbest` / `sent` 排在贪心与 PULL/PUSH 之前，
     是「走到回落出口时拟合区内必定已无 ZWSP、无句末候选」的保证；一旦重排，
     「句级标点不设短行下限」会被回落档的下限间接破坏。

## 11. 出口收尾函数：同一套下限施加到所有出口（②③④′ 同一处修复）

决定 `endj` 的出口有六个：溢出、ZWSP、标点族（sent/colon/clause）、贪心点 k、PULL、PUSH。
改版前只有「贪心点 k」与「PUSH」接了回落，且回落路径本身不设下限。现共用一个收尾函数。

- **落点够格的判据**：句级标点无条件够格（第 9 节裁定，不得动）；次级标点（冒号／逗号／顿号）
  要求 `cum >= avail − allow_c`；非标点落点只有**不涉中文**才够格。
- **不够格时按两种情形分岔**（这个分岔是 07/09/11/34/44 不受影响的**唯一**理由，
  不可简化为「不够格就溢出」）：
  - 拟合区内**有**标点候选 → 取最远且过 `allow_c` 下限者；
  - 拟合区内**一个标点候选都没有** → 维持现状，落在最好的排版断点上（atomic 边界恒可断）。
- **③ —— 一个都没过下限时，再分一次**：**只有落点短得离谱（不足四分之一可用宽，
  `cum*4 < avail`）才升级为溢出**，否则回落到那个偏短的标点。用户的原话「宁可长一行，
  也不吐 4 列的行」针对的是那种两头都坏的输出（4 列的行后面跟一个 82 列的行）；而 golden 44
  第 2 行那种 24 列 / 40 列可用宽的落点，换成 96 列的溢出行明显更差。`allow_c` 仍是回落的
  首选门槛，这道分界只决定「回落」还是「溢出」。**原计划只用 `allow_c` 一道门槛会连带改掉
  golden 44。**
  - **阈值从 1/2 改成 1/4 是被真实用例打出来的**（见第 13 节）：1/2 会把「逗号在 48 列 /
    100 列可用宽、回落后下一行 73 列正常」这种纯赚的回落误判成溢出，**只差 4 列**。
    1/4 在已知反例上留了 10% 对 48% 的余量。
  - 真正对应现象的判据其实是「回落之后下一行会不会照样超宽」——「两头都坏」是个复合现象，
    不是单看短行那一头。但准确的前瞻要把整条档位阶梯（三档 min_tier 的取舍）复制一遍才算得准：
    实测用 `legal_end` 近似会误判 golden 44 第 3 行那种「靠第二档放开盘古空格才断得开」的下一行。
    **故目前用阈值近似，并记下这笔债。**
- **② —— PULL 的落点第一次走上回落路径**。但 PULL 的 walk 停止条件含
  `can_break_before(tokens[e+1])`，可能停在 `adm == TIER_NONE` 的间隙上——那是禁则刻意为之的
  落点，收尾函数显式跳过，不得改写。超宽单 token 出口（`k < i`）与 ZWSP 出口同样不经收尾函数。
- **④′（审查新发现，不在原四条待办里）—— `overflow_to_punct` 名不副实**：它前向扫描的是
  「下一个**可断点**」而非「下一个**合法行尾**」，且进入该分支时盘古档已放开，于是会停在
  盘古空格上，把一个英文词单独甩成一行、行尾停在汉字上——正是严格模式声称要杜绝的两件事。
  **裁定的扫描口径**：停在段尾、ZWSP、标点（`qual > 0`）、不涉中文的断点，或 atomic 边界
  （`adm == TIER_ATOMIC`）；跳过汉字间与盘古空格，也跳过「可断但不配当行尾」的全角括号旁。
  **停在 atomic 边界这一条守住了本文件「含 atomic 的行不会溢出，在 atomic 边界断」那条裁定**
  ——一律扫到标点会推翻它的一角。
- **新增 golden**：`45-shortline-overflow`（③，width=40）、`46-overflow-legal-end`（④′，width=20），
  `expected` 均手工推导后经用户确认再落盘。

## 12. 待办 ① 经审查判定**不做**：两档不同即破幂等

- **待办原文**：「链接／数学／引用／shortcode 与中文之间的空格仍是无条件断点」。
  审查（T2）把范围缩小为「只把 CJK↔atomic 的**手写空格**降到盘古档，粘连边界留在 atomic 档不动」。
- **实测推翻**：降档后 golden 09／10／44 的**幂等不变式当场失败**（设计文档 6.2 之一）。
  机制在 `merge_lines`：折行一旦把 CJK 与 atomic 分到两行，重折合并时会在中间**插一个空格**
  （左末为 CJK、右首为 `[` 属 OTHER，走 `sep = " "` 分支）——于是同一个语义边界在「粘连」与
  「带空格」两种形态之间来回变化。**两种形态档位不同，即 `format(format(x)) ~= format(x)`。**
- **裁定**：CJK 与链接／数学／引用／shortcode 之间的**手写空格必须与粘连边界同档**
  （都是 `TIER_ATOMIC`，恒可断）。这也是「折行结果不取决于源文件排没排过版」这条既有原则
  在 atomic 边界上的必然推论——与第 9 节给盘古空格立的判据同源。
- **连带否掉的目标**：原计划想用一个 golden 固化「中文 + 空格 + 链接」与「中文 + 紧贴链接」
  **折行结果一致**。字面上做不到——多一个空格就是不同的文本，拟合区差 1 列，断点必然分化。
  同档已是能做到的最强一致性，幂等不变式则是它的自动验收。
- 代码里在 `compute_tiers` 的对应分支留了注释，防止后来者重蹈。


# 短尾巴并入 + 两处既有缺陷（真实使用反馈）

以下三条源于用户在真实中文文稿上的使用反馈，以及新落地的属性测试（`tests/unit/test_property.lua`）
随机跑出的两个既有缺陷。前者暴露了「逐行贪心看不见下一行」这个结构性局限的两面。

## 13. 短尾巴并入：断点之后只剩一小截就到句末时，并进本行

- **现象**（width=80，用户实例）：
  `……六成记在中国香港名下，` (72 列) ／ `十年未降[^hkbook]。` (19 列)
  第 1 行断在拟合区内最远的逗号上，自身无可指摘；第 2 行那 19 列的孤行却很难看。
- **成因是两条各自正确的规则叠加**：句号落在 91 列、**已在拟合区（80 列）之外**，贪心够不着；
  而第 9 节「句级标点不设短行下限」又让那 19 列的尾巴立刻成行。
- **裁定**：断点之后若在 **avail/4** 之内就遇到句级标点，把那一截并进本行，允许有限超宽
  （超宽幅度因此也 ≤ avail/4）。四条守卫缺一不可：
  1. 仅 `strict_end`——与收尾函数同门控，`wrap_sentence=true`（按宽填满）绝不超宽；
  2. 本行落点**不是**句级标点——已落句末就没有短尾巴问题，否则连续短句会被黏成一行，
     「一句一行」当场破（注意这与「拟合区内取最远句号、一行可含多个短分句」不矛盾，
     那是 `sent` 槽的既有行为，不经本函数）；
  3. 目标句级标点 `t < m`——`t == m` 是段落最后一行，**末行短本来就是正常的**，
     否则每段的最后一行都会被前一行黏走；
  4. ZWSP 落点不动（用户手工标记）。
- **这与第 11 节的回落下限是同一个结构性局限的两面**：`M.wrap` 逐行贪心，看不见下一行。
  一面是「断在 48 列的逗号是对的，因为下一行 73 列正常」，另一面是「断在 72 列的逗号不对，
  因为下一行只剩 19 列」。两者都要看下一行才判得准，而贪心只能用阈值近似。
  **完整解是 Knuth–Plass 式整段最优（DP + 总 badness），它能同时看见这一行短与下一行长；
  代价是改写几乎全部 golden，并与 design §4.3 的「贪心 + 优先级扫描」冲突，留作独立提案。**
- 验收：`47-fallback-short-line`（width=100）、`48-short-tail-merge`（width=80），
  `expected` 即用户给出的理想输出。

## 14. 两个既有缺陷（属性测试抓到，与本次重构无关）

**14.1 PUSH 退无可退时破坏禁则。** `《` 之后紧跟一个比整行还宽的 token（实例：长 URL）时，
PUSH 一路退到行首仍找不到可断点，旧代码 `endj = (e >= i) and e or i` 便让 `《` 独占一行——
禁后断标点落在了行尾。**判据错在「退没退回到 `i`」：`e == i` 时 `i` 之后未必可断。**
改为判「退回去的落点可不可断」，退无可退时向前拉到第一个可断处，宁可这一行超宽（4.3.6 允许）。

**14.2 `．`（U+FF0E）同时在两张禁则表里，无解。** 它被 REF 的表列进 `forbit_break_after`
（邻居全是左括号、开引号与货币符号——`＄100` 不能在 `＄` 后断），而第 9 节修复又把它补进了
`forbit_break_before`。结果它**既不能落行首、又不能落行尾**，折行必然破其中一条；
且 `char_attr` 的判定顺序（after 先于 before）把它归成了「开括号类」。
它是句末标点，语义等同 `。`。**裁定：从 `forbit_break_after` 移除**，分类由
`forbit_break_before` 承担。这是本次唯一一处 `chardata.lua` 改动（原计划范围外，经用户确认）。
既有 48 个 golden 零差异。

## 15. 属性测试：随机原子流 × 四条独立不变式

- golden 钉死「这个输入应折成这样」，属性测试钉死「无论什么输入都不该违反这几条」。
  后者的价值在随机形态——重构断点判定时最容易漏掉的，正是 golden 没覆盖到的字符组合。
- **不变式必须独立于实现**，否则是循环论证（「行尾落在合法处」的「合法」就是实现本身）。
  四条：P1 非空格字符序列守恒；P2 禁则；P3 严格模式不在汉字之间断；P4 幂等。
- **P1 不能用 `merge_lines` 做逆运算来验**：它按 4.3.3 的规则决定两行之间插不插空格
  （中文行之间无、英文行之间恰一个），改变字节是设计使然，而 `wrap` 又会消费掉落在断点处的
  空格。拿字节相等去断言二者互逆必然假阳性（实测被 `budget（庚》` 这种拉丁贴全角括号的形态
  打出来过）。故 P1 只钉内容、忽略空格，空格的正确性交给 P4 与 golden。
- width 下限取 20：更窄时 `avail` 小到容不下一个合法断点，禁则被迫让路是 4.3.6 允许的降级。
- 本机 5 个 seed × 86,400 次 `wrap` 全绿；seed 固定，CI 可复现，`MDWRAP_PROP_CASES` 可加大深跑。
