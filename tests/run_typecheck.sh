#!/usr/bin/env bash
# 本地一键：纯模块硬约束冒烟 + 领域类型检查，两道护栏合一。
#   A) chardata / layout / spacing / table_align 在 bare luajit 下独立加载——「禁止 require vim」
#      LuaLS 无法表达，只能靠这道冒烟把守（真把 vim 拖进纯模块，require 链即崩）。
#      **先跑**：它是该硬约束的唯一护栏，依赖最少（仅 luajit），不应被 LLS 是否安装挡住。
#   B) lua-language-server --check 静态校验领域类型（注入真实 $VIMRUNTIME，
#      使 vim.* 与 TSNode 等获得真实定义，目标是抓**我们自己**的 mdwrap.* 类型 bug）。
#
# 判定：本机 lua-language-server 3.18.2-dev 实测**不**生成 check.json（计划原拟以其存在与否
#       判定，对此版本失效）；改用「退出码非 0」与「输出末行问题计数 > 0」双信号取或——
#       退出码为主（本机可靠），计数为兜底；任一为真即视为有诊断。任一护栏失败即 exit 1。
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# ---------------------------------------------------------------------------
# A) 纯模块硬约束冒烟（no-vim / Lua 5.1）——先于类型检查，依赖最少
# ---------------------------------------------------------------------------
LUAJIT="$(command -v luajit || command -v lua5.1 || true)"
if [[ -z "$LUAJIT" ]]; then
  echo "luajit / lua5.1 not found; cannot run pure-module smoke" >&2
  exit 1
fi
echo "== pure-module smoke (${LUAJIT##*/}: no-vim / Lua 5.1) =="
for mod in chardata layout spacing table_align; do
  if "$LUAJIT" -e "package.path='$ROOT/lua/?.lua;'..package.path; require('mdwrap.$mod')"; then
    echo "  ok: mdwrap.$mod"
  else
    echo "  FAIL: mdwrap.$mod (no-vim/5.1 constraint broken)" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# B) 领域类型检查（lua-language-server --check）
# ---------------------------------------------------------------------------
LLS="$(command -v lua-language-server || true)"
if [[ -z "$LLS" ]]; then
  echo "lua-language-server not found" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/luarc.json"
LOG="$TMP/log"
OUT="$TMP/check.out"
mkdir -p "$LOG"

# 临时配置派生自 .luarc.json（单一真相源），仅注入 workspace.library:[<VIMRUNTIME>/lua]。
# 复用解析 VIMRUNTIME 的同一次 nvim 调用：用 vim.json 读出 .luarc.json、加键、回写 $CFG，
# 并把 VIMRUNTIME 打到 stdout 供下方提示——避免手抄配置键造成的漂移。
VIMRUNTIME="$(nvim --headless -u NONE \
  -c "lua local rt=vim.env.VIMRUNTIME; local f=assert(io.open('.luarc.json')); local c=vim.json.decode(f:read('*a')); f:close(); c['workspace.library']={rt..'/lua'}; local o=assert(io.open([[$CFG]],'w')); o:write(vim.json.encode(c)); o:close(); io.write(rt)" \
  -c 'qa!' 2>/dev/null)"
if [[ -z "$VIMRUNTIME" || ! -s "$CFG" ]]; then
  echo "failed to resolve VIMRUNTIME / build temp luarc via nvim" >&2
  exit 1
fi

echo "== lua-language-server --check (Lua 5.1; VIMRUNTIME=$VIMRUNTIME) =="
"$LLS" --check="$ROOT" --configpath="$CFG" --checklevel=Warning --logpath="$LOG" 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}

# 末行形如 "Diagnosis complete, N problems found"；取该 N（无则视为 0）。
count="$(sed -nE 's/.*[^0-9]([0-9]+) problems? found.*/\1/p' "$OUT" | tail -1)"
count="${count:-0}"
if [[ "$rc" -ne 0 || "$count" -gt 0 ]]; then
  echo "type check FAILED: rc=$rc, problems=$count (see diagnostics above)" >&2
  exit 1
fi
echo "type check passed (no diagnostics)."

echo "all checks passed."
