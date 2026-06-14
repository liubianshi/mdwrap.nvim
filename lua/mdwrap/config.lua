-- config.lua — 默认配置与校验
--
-- 配置项对照 mdwrap CLI 见 README；默认值映射自 REF 的 Wrap.pm / script/mdwrap。

local M = {}

--- 返回一份默认配置（每次新建表，避免共享可变状态）。
---@return mdwrap.Config
function M.defaults()
  return {
    width = nil,                 -- nil 则取 textwidth，再退 80（REF: --line-width）
    wrap_sentence = false,       -- REF: --wrap-sentence；false 时启用句末优先断行
    keep_origin_wrap = false,    -- REF: --keep-origin-wrap；true 时不合并原有换行
    lang = "zh",                 -- 预留；v1 仅 zh
    cjk_english_spacing = true,  -- 盘古之白 pass
    cjk_break_at_punct_only = true, -- 中文严格只在标点处断行；无标点的超长子句才字间断兜底
    bracket_as_unit = true,      -- 括号配对作整体：能整组放下就不在括号内部断（整组宽超一行才内部断）
    respect_conceallevel = true, -- conceallevel=0 的窗口不扣 conceal 宽度
    respect_extmark_conceal = true, -- 读持久 conceal extmark（render-markdown/markview 等渲染插件的宽度增量）；插件无关
    notify_on_error_node = true, -- 块含 ERROR 节点跳过时提示
    set_formatexpr = true,       -- false 时不注册 formatexpr，把 gq 让回默认（交 conform 等接管）
  }
end

return M
