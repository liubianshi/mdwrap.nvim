local M = {}
local wrapped = setmetatable({}, { __mode = "k" })

---@param opts table?
---@param display_opts mdwrap.DisplayOpts?
---@return table
function M.extend(opts, display_opts)
  local display = require("mdwrap.display")
  if opts and wrapped[opts] then
    if display_opts then display.configure(display_opts) end
    return opts
  end
  local result = vim.deepcopy(opts or {})
  if not display.configure(display_opts) then return result end
  result.on = result.on or {}
  for _, name in ipairs({ "render", "clear" }) do
    local original = result.on[name]
    local handler = display[name]
    result.on[name] = function(context)
      if original then original(context) end
      handler(context)
    end
  end
  wrapped[result] = true
  return result
end

return M
