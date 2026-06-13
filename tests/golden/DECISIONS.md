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

