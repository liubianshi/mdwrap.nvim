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
- **已知待办**（`/simplify` 四路审查记录,留待下一次同类问题时一并处理）：
  ① 链接／数学／引用／shortcode 与中文之间的空格仍是无条件断点——`spacing` 按 DECISIONS 第 2 条
  本就不在那里插空格,故不在盘古边界之列；A 能兜住有标点的情形,拟合区无标点时仍会断在那里。
  ② PULL 分支（禁前断标点拉回）未接 `needs_punct_end`,其落点可能不是标点。
  ③ `punct_far` 不设短行下限,极端输入下 A 可能折出很短的行(实测有 6 列的例子),
  ④ 逐行探测比改前多一档,`wrap_sentence=true` + 严格模式实测慢约 40%（3000 次 `wrap`
  的合成基准；默认的 `wrap_sentence=false` 严格模式与非严格模式均在 +10% 以内）。
  且救不了下一行。这三条与「`gap_breakable`／`level_of`／`punct_break` 三套重叠的行尾判定」
  同源,真正的解法是给每个间隙一个有序档位（tier）并把短行容忍从硬门槛改为排序权重,
  代价是重写 `M.wrap` 内层循环并重新批准一批 golden expected,须用户拍板后单独做。
