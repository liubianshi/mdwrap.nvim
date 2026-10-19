local layout = require("mdwrap.layout")

local function atom(text, width, class)
  return { text = text, width = width, class = class or "word" }
end

local sentence = {
  atom("One.", 4), atom(" ", 1, "space"), atom("Two.", 4),
  atom(" ", 1, "space"), atom("Three.", 6),
}
local plan = assert(layout.plan(sentence, { width = 12 }))
assert(#plan == 2 and plan[1].first == 1 and plan[1].last == 3)
assert(plan[1].width == 9 and plan[2].first == 5)

local spaces = { atom("one", 3), atom("   ", 3, "space"), atom("two", 3) }
plan = assert(layout.plan(spaces, { width = 8 }))
assert(#plan == 2 and plan[1].width == 3)
assert(layout.wrap(spaces, { width = 8 })[1] == "one two")
assert(layout.plan({ atom("one", 3), atom("   ", 3, "space"), atom("two", 3) }, { width = 5 }) == nil)

local chinese = {}
for _ = 1, 12 do chinese[#chinese + 1] = atom("中", 2, "cjk") end
plan = assert(layout.plan(chinese, { width = 8, cjk_break_at_punct_only = true }))
assert(#plan == 3)
for _, line in ipairs(plan) do assert(line.width <= 8) end
assert(layout.plan({ atom("verylongword", 12) }, { width = 8 }) == nil)

local brackets = {
  atom("中", 2, "cjk"), atom("中", 2, "cjk"),
  atom("（", 2, "punct_no_break_after"), atom("文", 2, "cjk"),
  atom("）", 2, "punct_no_break_before"), atom("文", 2, "cjk"),
}
plan = assert(layout.plan(brackets, { width = 8, bracket_as_unit = true }))
assert(plan[1].last == 2 and plan[2].first == 3)

local marked = { atom("中", 2, "cjk"), atom("\226\128\139", 0, "zwsp"), atom("文", 2, "cjk") }
layout.wrap(marked, { width = 2 })
layout.plan(marked, { width = 2 })
assert(marked[1].text == "中", "layout must not mutate input atoms")

print("display plan tests passed")
