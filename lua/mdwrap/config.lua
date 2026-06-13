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
    respect_conceallevel = true, -- conceallevel=0 的窗口不扣 conceal 宽度
    notify_on_error_node = true, -- 块含 ERROR 节点跳过时提示
  }
end

return M
