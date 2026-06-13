# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This is a Neovim plugin project that is **not yet implemented**. The repo currently holds only the
design document; code is to be built out against it incrementally.

**`mdwrap-nvim-design.md` is the authoritative spec**, not advisory notes. Read it in full before any
implementation work. This file only adds the facts the design doc leaves implicit and the hard
constraints that are easiest to violate — it does not restate the design. On any conflict of detail,
defer to `mdwrap-nvim-design.md`, and treat its Section 6 golden cases as the final acceptance criteria.

## What the plugin does

Provides **conceal-aware hard line wrapping** for Pandoc/Quarto-dialect Chinese Markdown: wraps by the
width Neovim actually displays (subtracting parts hidden by conceal — `**`, inline-code backticks, link
URLs, etc.) so text aligns visually. It also implements Chinese kinsoku (forbidden line-start/end
punctuation), sentence-end-preferred breaking, merging lines without inserting spaces between Chinese
characters, and CJK/Latin spacing (pangu). Entry points are `formatexpr` (the `gq` family) and the
`:MdwrapFormat` command.

It replaces an existing Perl tool, mdwrap (reference repo below), but **migrates domain knowledge only,
not architecture**.

## Reference repo (confirmed local path)

The old Perl implementation lives at **`~/Repositories/mdwrap/`** (the design doc refers to it as
`REF/`). It is the *source of behavioral truth*, **not an architectural template**. Extract domain
knowledge only; the per-file extraction list is in design doc Section 2. The most valuable files:

- `lib/App/Markdown/Utils.pm` — `_char_attr` (from `:153`): the character-classification codepoint
  tables (no-break-before / no-break-after punctuation, CJK ranges). **Port these verbatim** into
  `lua/mdwrap/chardata.lua`, keeping the codepoint comments. Also `indent` (`:61`) and
  `format_quote_line` (`:106`) for prefix / quote normalization semantics.
- `lib/App/Markdown/Text.pm` — line-merge rule `update_when_new_line`, sentence detection
  `_sentence_end`, short-line tolerance `support_shorter_line`, the `%LANG_CONFIG` zh sentence regex and
  separator sets, default constants.
- `lib/App/Markdown/Inline.pm` — how much each inline structure conceals (**take only this, not the
  probe-closure mechanism**).
- `lib/App/Markdown/Handler.pm` — the full set of block types and each block's "preserve vs wrap"
  classification decision.

Don't assume the path prefix; substitute `~/Repositories/mdwrap/` for every `REF/` in the design doc.

## Architecture: three-layer separation (the core invariant)

1. **Parse layer** — block and inline structure come from tree-sitter (built-in `markdown` +
   `markdown_inline` parsers, confirmed available on this machine; nvim-treesitter is *not* required).
   `blocks.lua` does block-level splitting and prefix computation; `atoms.lua` turns the inline tree into
   a flat list of atoms (`{ indivisible unit + visual width }`).
2. **Layout layer** — `layout.lua` (the wrapping core) and `spacing.lua` (CJK/Latin spacing) are **pure
   functions**.
3. **Dependency injection** — the layout layer receives `width_fn` as a parameter: production injects an
   implementation backed by `vim.fn.strdisplaywidth` plus conceal metadata; unit tests inject a
   table-lookup stub. This is the keystone of the whole test strategy.

**Hard constraint: `layout.lua`, `spacing.lua`, and `chardata.lua` must never `require` any `vim.*`
module**, and must load and test under bare `luajit` / `lua5.1`. Before committing, verify with
`luajit -e "require('mdwrap.layout')"` (with `lua/` on the path).

Target module layout is in design doc Section 3.2; `init.lua` is the editor integration and `formatexpr`
entry point.

## Single source of truth for visual width

Conceal widths must come from the capture ranges carrying `conceal` metadata in the `markdown_inline`
`highlights` query — **do not maintain a separate hand-written list of "what gets hidden"**, which would
drift from what the editor actually displays. `strdisplaywidth` already honors `ambiwidth`; do not
recompute East Asian width yourself. See design doc 4.2.1.

## Development workflow: tests first + local empirical checks

- **Tree-sitter node names are determined by local experiment**, never assumed from memory. Use
  `nvim --headless --clean` to load sample text and print `node:sexpr()` to confirm node types, and record
  the observed results in the header comments of `blocks.lua` / `atoms.lua` (the node names in design doc
  Section 4 are *expected* values — on mismatch, the observed value wins and must be noted).
- **Write tests before implementation for each milestone.** The 26 golden cases (design doc 6.3) must have
  their `input.md` and `expected.md` written to disk *before* implementing layout, and **`expected` is
  constructed by hand precisely, then shown to the user for confirmation before any implementation begins**.
- The implementation order M0→M4 is in design doc Section 7; at the end of each milestone, report
  pass/fail case lists and any deviation from the spec.

## Test commands (will exist once implemented)

```bash
tests/run_unit.sh      # Pure-Lua unit tests (busted if available, else minimal asserts); covers layout/spacing/chardata
tests/run_golden.sh    # nvim --headless driver, byte-exact diff input -> expected
tests/run_typecheck.sh # lua-language-server --check (domain types, Lua 5.1) + pure-module no-vim smoke
luacheck lua/          # Must be warning-free when available
```

Type annotations are LuaCATS; all domain types (`mdwrap.Atom`, `mdwrap.Block`, `mdwrap.Config`,
`mdwrap.WidthFn`, the various `*Opts`) live in `lua/mdwrap/types.lua`, a meta file that is **never
`require`d at runtime** — LuaLS resolves `---@class` by name across the workspace, so the pure modules
reference these types in comments only and the no-`require`-`vim` constraint stays intact. `.luarc.json`
pins `runtime.version: "Lua 5.1"` (machine guard for the three pure modules) and silences `vim` via
`diagnostics.globals`; `run_typecheck.sh` injects the real `$VIMRUNTIME` so `vim.*` / `TSNode` resolve
during the check, and folds in the `luajit` no-vim smoke as a second guard. In the editor, install
[lazydev.nvim](https://github.com/folke/lazydev.nvim) for full `vim` / tree-sitter types.

Run a single golden case:
```bash
nvim --headless --clean -u tests/minimal_init.lua \
  -c "lua require('mdwrap.test_runner').run('tests/golden/01-basic-cjk')" -c 'qa!'
```

Three invariants run automatically over **all** golden inputs (design doc 6.2):
(1) idempotence `format(format(x))==format(x)`; (2) bytes outside the target block unchanged;
(3) pandoc-AST semantic preservation (when pandoc is present).

## Anti-patterns (forbidden — violating these is a spec deviation)

- Do not reproduce the Perl version's eleven-layer handler character state machine or its
  word/sentence/line three-buffer control flow.
- Do not reproduce the `Inline.pm` ~line-110 citation-probe bug where `=` was written instead of `=~`.
- Do not implement the `--tonewsboat` mode (out of scope).
- The layout layer must not `require` any `vim.*`.
- **Do not edit golden `expected` files to make tests pass**; if a change is genuinely needed, stop and
  explain it to the user.

## Markdown style for docs/comments

This project is itself a Chinese-Markdown writing tool, so `.md` documents in the repo follow the user's
global Markdown rules: semantic line breaks (≤120 width, CJK counts as 2, break only at punctuation),
pangu spacing (one space between CJK and Latin/digits), Chinese corner brackets「」for quotes, and `---`
only where syntax requires it (YAML, etc.), never as a body separator.
