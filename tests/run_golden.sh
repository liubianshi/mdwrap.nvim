#!/usr/bin/env bash
# golden 集成测试：nvim --headless 驱动，逐字节 diff input→expected，跑三项不变量。
set -uo pipefail

cd "$(dirname "$0")/.."

nvim --headless --clean -u tests/minimal_init.lua \
  -c "lua require('mdwrap.test_runner').run_all()"
rc=$?
exit "$rc"
