#!/usr/bin/env bash
# 纯 Lua 单元测试驱动：覆盖 layout / spacing / chardata（无 Neovim 依赖）。
# 优先 busted（若已安装），否则用极简断言脚本（luajit / lua5.1 / lua）。
set -euo pipefail

cd "$(dirname "$0")/.."

LUA="$(command -v luajit || command -v lua5.1 || command -v lua || true)"
if [[ -z "$LUA" ]]; then
  echo "no lua interpreter (luajit/lua5.1/lua) found" >&2
  exit 1
fi

export LUA_PATH="./lua/?.lua;./tests/unit/?.lua;;"

rc=0
for f in tests/unit/test_*.lua; do
  [[ -e "$f" ]] || continue
  echo "== $f (${LUA##*/}) =="
  if ! "$LUA" "$f"; then rc=1; fi
done
exit "$rc"
