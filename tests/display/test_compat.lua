vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.wrap = false
local warnings, calls = 0, 0
rawset(vim, "notify", function() warnings = warnings + 1 end)
local original = { on = { render = function() calls = calls + 1 end } }
local adapter = require("mdwrap.integrations.render_markdown")
local result = adapter.extend(original)
assert(result ~= original and result.on.render == original.on.render)
result.on.render({ buf = vim.api.nvim_get_current_buf() })
adapter.extend(original)
assert(calls == 1 and warnings == 1 and not vim.wo.wrap)
require("mdwrap").create_commands()
assert(vim.fn.exists(":MdwrapFormat") == 2)
assert(require("mdwrap.layout").wrap({ { text = "test", width = 4, class = "word" } }, { width = 10 })[1] == "test")
print("unsupported-version compatibility passed")
