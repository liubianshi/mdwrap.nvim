-- luacheck 配置
-- 项目主体运行在 Neovim 的 LuaJIT（Lua 5.1）运行时；纯模块 layout/spacing/chardata 禁止
-- require vim，但同样跑在 5.1 下，故全局基线统一为 luajit。

std = "luajit"

-- Neovim 注入的全局（只读引用，不允许整体赋值）
read_globals = { "vim" }

-- types.lua 是 LuaCATS meta 文件，运行时从不被 require，仅含 ---@class 注解，排除。
exclude_files = { "lua/mdwrap/types.lua" }

-- 逐码点对齐的字符表与中文注释会拉长行；行宽不是 lint 重点，交给 markdown/格式约定管。
max_line_length = false

-- 接口/回调签名常带未用参数（如 conform formatter 的 self/ctx），不视为问题。
unused_args = false
