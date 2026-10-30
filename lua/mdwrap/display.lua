local atoms = require("mdwrap.atoms")
local blocks = require("mdwrap.blocks")
local conceal = require("mdwrap.conceal")
local layout = require("mdwrap.layout")

local M = {}
local buffers, windows, parsed = {}, {}, {}
---@type mdwrap.DisplayOpts
local display_options = {}
local configured, pending, changing, warned = false, false, false, false
local managed = { wrap = true, linebreak = false, breakindent = false, showbreak = "NONE", list = false }

local function notify(message)
  vim.notify("[mdwrap display] " .. message, vim.log.levels.WARN)
end

local function supported()
  return vim.fn.has("nvim-0.11") == 1 and type(vim.api.nvim__ns_set) == "function"
end

local function display_mode()
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then return "v" end
  return mode == "n" and "n" or mode:sub(1, 1) == "i" and "i" or nil
end

local function release(window)
  local state = windows[window]
  if not state then return end
  windows[window] = nil
  if vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  end
  if vim.api.nvim_win_is_valid(window) then
    changing = true
    for name, value in pairs(managed) do
      if vim.api.nvim_get_option_value(name, { win = window, scope = "local" }) == value then
        vim.api.nvim_set_option_value(name, state.saved[name], { win = window, scope = "local" })
      end
    end
    changing = false
  end
end

local function release_buffer(buffer)
  local targets = {}
  for window, state in pairs(windows) do
    if state.buf == buffer then targets[#targets + 1] = window end
  end
  for _, window in ipairs(targets) do release(window) end
end

local function fail(buffer, message)
  local state = buffers[buffer]
  if state then state.failed = true end
  release_buffer(buffer)
  notify("disabled for buffer " .. buffer .. ": " .. tostring(message))
end

local function acquire(window, buffer)
  local state = windows[window]
  if state and state.buf ~= buffer then release(window); state = nil end
  if not state then
    local namespace = vim.api.nvim_create_namespace("mdwrap.display." .. window)
    conceal.ignore_namespace(namespace)
    vim.api.nvim__ns_set(namespace, { wins = { window } })
    state = { buf = buffer, ns = namespace, saved = {}, cache = {}, plans = {} }
    windows[window] = state
  end
  changing = true
  for name, value in pairs(managed) do
    local current = vim.api.nvim_get_option_value(name, { win = window, scope = "local" })
    if state.saved[name] == nil or current ~= value then state.saved[name] = current end
    if current ~= value then vim.api.nvim_set_option_value(name, value, { win = window, scope = "local" }) end
  end
  changing = false
  return state
end

local function shifted_marks(marks, first, last)
  local result = {}
  for _, mark in ipairs(marks) do
    if mark.cs < last and mark.ce >= first then
      local start = math.max(mark.cs, first)
      local ending = math.min(mark.ce, last)
      result[#result + 1] = {
        sc = start - first, ce = math.max(start, ending) - first,
        add = mark.cs >= first and mark.cs < last and mark.add or 0,
      }
    end
  end
  return result
end

local function sum_width(items)
  local width = 0
  for _, item in ipairs(items) do width = width + item.width end
  return width
end

local function native_width(source, first, last, marks)
  local width = vim.fn.strdisplaywidth(source:sub(first + 1, last))
  for _, mark in ipairs(marks) do
    if mark.cs >= first and mark.cs < last then width = width + (mark.inline or 0) end
  end
  return width
end

local function blank_gap(source, first, last, cached)
  local cursor = first
  for _, range in ipairs(cached.hidden) do
    local start, ending = cached.offset + range.sc, cached.offset + range.ec
    if start >= last then break end
    if ending > cursor then
      if not source:sub(cursor + 1, math.min(start, last)):match("^ *$") then return false end
      cursor = math.min(ending, last)
    end
  end
  return source:sub(cursor + 1, last):match("^ *$") ~= nil
end

local function plan_breaks(source, cached, plan)
  local endings = {}
  for index, current in ipairs(plan) do
    local following = plan[index + 1]
    local ending = following and cached.offset + cached.atoms[following.first].sc or #source
    local column = cached.offset + cached.atoms[current.last].ec
    if not blank_gap(source, column, ending, cached) then return nil end
    endings[#endings + 1] = ending
  end
  return endings
end

local function padding_marks(source, row, rest_width, endings, width, marks)
  local result = {}
  local start, indentation = 0, 0
  for index, ending in ipairs(endings) do
    local occupied = native_width(source, start, ending, marks) + indentation
    if occupied > width then return nil end
    local padding = width - occupied + rest_width
    if index < #endings and padding > 0 then
      result[#result + 1] = { row, ending, {
        virt_text = { { string.rep(" ", padding) } }, virt_text_pos = "inline", priority = 0,
        right_gravity = false,
      } }
    end
    start, indentation = ending, rest_width
  end
  return result
end

local function row_plan(window, state, row, prefix, rest_prefix, width, plan_width, mode, cursor_range)
  local previous = state.plans[row]
  state.plans[row] = nil
  if (vim.wo[window].number or vim.wo[window].relativenumber)
      and vim.o.cpoptions:find("n", 1, true) then return {} end
  local source = vim.api.nvim_buf_get_lines(state.buf, row, row + 1, false)[1]
  if not source or source:find("\t", 1, true) or source:find("\226\128\139", 1, true) then return {} end
  local level = vim.wo[window].conceallevel
  if level ~= 0 and level ~= 3 then return {} end
  local concealed = level == 3 and (not cursor_range or row < cursor_range[1] or row > cursor_range[2]
    or vim.wo[window].concealcursor:find(mode, 1, true) ~= nil)
  local marks, unsafe = conceal.gather(state.buf, row, row, nil, {
    conceal = concealed, conceallevel = level, overlap = true, win = window,
  })
  if unsafe then return {} end
  local query = concealed and vim.treesitter.highlighter.active[state.buf] ~= nil
  local key = vim.json.encode({ source, prefix, rest_prefix, concealed, query, marks, vim.o.ambiwidth })
  local cached = state.cache[row]
  if not cached or cached.key ~= key then
    local offset = #prefix
    local body = source:sub(offset + 1)
    if body == "" then return {} end
    local prefix_atoms = prefix ~= "" and atoms.atomize_mapped(prefix, {
      query_conceal = false, extmark_conceal = shifted_marks(marks, 0, offset),
    }) or {}
    local body_atoms, hidden = atoms.atomize_mapped(body, {
      conceal = concealed, query_conceal = query,
      extmark_conceal = shifted_marks(marks, offset, #source),
    })
    cached = {
      key = key, offset = offset, prefix_width = sum_width(prefix_atoms),
      atoms = body_atoms, hidden = hidden,
    }
    cached.rest_width = math.max(0,
      vim.fn.strdisplaywidth(rest_prefix) - vim.fn.strdisplaywidth(prefix) + cached.prefix_width)
    local leading_width, leading_end = 0, 0
    for _, item in ipairs(cached.atoms) do
      if item.class ~= "space" then break end
      leading_width, leading_end = leading_width + item.width, item.ec
    end
    cached.first_width = cached.prefix_width + leading_width
    cached.native_prefix_width = native_width(source, 0, offset + leading_end, marks)
    state.cache[row] = cached
  end
  if cached.first_width >= plan_width or cached.rest_width >= plan_width then return {} end
  local options = require("mdwrap").options
  local wrap_sentence = display_options.wrap_sentence
  if wrap_sentence == nil then wrap_sentence = options.wrap_sentence end
  local settings = {
    width = plan_width, prefix_first_width = cached.first_width, prefix_rest_width = cached.rest_width,
    wrap_sentence = wrap_sentence, cjk_break_at_punct_only = options.cjk_break_at_punct_only,
    bracket_as_unit = options.bracket_as_unit,
  }
  local plan_key = vim.json.encode({
    source, prefix, rest_prefix, width, plan_width, level, vim.o.ambiwidth,
    wrap_sentence, options.cjk_break_at_punct_only, options.bracket_as_unit,
  })
  local preserve = mode == "v" or (mode == "i" and display_options.insert_mode == "wrap")
  if preserve and previous and previous.key == plan_key then
    local result = padding_marks(source, row, cached.rest_width, previous.endings, width, marks)
    if result then state.plans[row] = previous; return result end
  end
  local plan = layout.plan(cached.atoms, settings)
  if not plan then return {} end
  local endings = plan_breaks(source, cached, plan)
  local result = endings and padding_marks(source, row, cached.rest_width, endings, width, marks)
  if not result then
    if not cached.native_atoms then
      cached.native_atoms = vim.deepcopy(cached.atoms)
      for _, item in ipairs(cached.native_atoms) do
        item.width = native_width(source, cached.offset + item.sc, cached.offset + item.ec, marks)
      end
    end
    settings.prefix_first_width = cached.native_prefix_width
    plan = layout.plan(cached.native_atoms, settings)
    endings = plan and plan_breaks(source, cached, plan)
    result = endings and padding_marks(source, row, cached.rest_width, endings, width, marks)
  end
  if result then state.plans[row] = { key = plan_key, endings = endings } end
  return result or {}
end

local function refresh_window(window, buffer, mode, active_window)
  local state = acquire(window, buffer)
  local cursor_row = window == active_window and vim.api.nvim_win_get_cursor(window)[1] - 1 or nil
  local cursor_range = cursor_row and { cursor_row, cursor_row } or nil
  if mode == "v" and buffer == vim.api.nvim_win_get_buf(active_window) then
    local active_row = vim.api.nvim_win_get_cursor(active_window)[1] - 1
    local anchor = vim.fn.getpos("v")[2] - 1
    cursor_range = { math.min(anchor, active_row), math.max(anchor, active_row) }
  end
  local info = vim.fn.getwininfo(window)[1]
  local width = vim.api.nvim_win_get_width(window) - info.textoff
  state.width, state.textoff = width, info.textoff
  local margin = display_options.right_margin
  if margin == nil or margin == "auto" then margin = info.textoff end
  local plan_width = math.min(width - margin, display_options.max_width or width)
  if plan_width < 1 then
    vim.api.nvim_buf_clear_namespace(buffer, state.ns, 0, -1)
    state.cache, state.plans, state.marks, state.tick = {}, {}, {}, nil
    return
  end
  local view = vim.api.nvim_win_call(window, function()
    return { vim.fn.line("w0") - 1, vim.fn.line("w$") - 1 }
  end)
  local tick = vim.api.nvim_buf_get_changedtick(buffer)
  if not parsed[buffer] or parsed[buffer].tick ~= tick then
    parsed[buffer] = { tick = tick, blocks = blocks.split(buffer) }
  end
  local next_marks, next_cache, next_plans = {}, {}, {}
  for _, block in ipairs(parsed[buffer].blocks) do
    if block.action == "wrap" and block.erow >= view[1] and block.srow <= view[2] then
      for row = math.max(block.srow, view[1]), math.min(block.erow, view[2]) do
        if mode ~= "i" or display_options.insert_mode == "wrap" or row ~= cursor_row then
          local prefix = block.content_prefix[row - block.srow + 1] or ""
          vim.list_extend(next_marks,
            row_plan(window, state, row, prefix, block.prefix_rest, width, plan_width, mode, cursor_range))
          next_cache[row] = state.cache[row]
          next_plans[row] = state.plans[row]
        end
      end
    end
  end
  state.cache, state.plans = next_cache, next_plans
  if tick ~= vim.api.nvim_buf_get_changedtick(buffer) then M.request_refresh(); return end
  if state.tick == tick and vim.deep_equal(state.marks, next_marks) then return end
  vim.api.nvim_buf_clear_namespace(buffer, state.ns, 0, -1)
  for _, mark in ipairs(next_marks) do
    vim.api.nvim_buf_set_extmark(buffer, state.ns, mark[1], mark[2], mark[3])
  end
  state.marks, state.tick = next_marks, tick
end

function M.refresh()
  pending = false
  local mode = display_mode()
  local active_window = vim.api.nvim_get_current_win()
  local visible = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    visible[window] = true
    local buffer = vim.api.nvim_win_get_buf(window)
    local state = buffers[buffer]
    if state and state.enabled and state.rendered and not state.failed
        and mode and not vim.wo[window].diff then
      local ok, message = pcall(refresh_window, window, buffer, mode, active_window)
      changing = false
      if not ok then fail(buffer, message) end
    else
      release(window)
    end
  end
  local closed = {}
  for window in pairs(windows) do if not visible[window] then closed[#closed + 1] = window end end
  for _, window in ipairs(closed) do release(window) end
end

function M.request_refresh()
  if pending then return end
  pending = true
  vim.schedule(M.refresh)
end

---@param opts mdwrap.DisplayOpts?
function M.configure(opts)
  if not supported() then
    if not warned then notify("requires Neovim >= 0.11 with nvim__ns_set; integration is disabled"); warned = true end
    return false
  end
  local max_width = opts and opts.max_width
  if max_width ~= nil then
    assert(type(max_width) == "number" and max_width >= 1 and max_width % 1 == 0,
      "[mdwrap display] max_width must be a positive integer")
  end
  local right_margin = opts and opts.right_margin
  assert(right_margin == nil or right_margin == "auto"
    or (type(right_margin) == "number" and right_margin >= 0 and right_margin % 1 == 0),
    '[mdwrap display] right_margin must be "auto" or a non-negative integer')
  local insert_mode = opts and opts.insert_mode
  assert(insert_mode == nil or insert_mode == "native" or insert_mode == "wrap",
    '[mdwrap display] insert_mode must be "native" or "wrap"')
  display_options = vim.deepcopy(opts or {})
  if configured then
    M.request_refresh()
    return true
  end
  configured = true
  vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("mdwrap.display.geometry"), {
    on_win = function(_, window)
      local state = windows[window]
      if state then
        local info = vim.fn.getwininfo(window)[1]
        if info and (state.width ~= vim.api.nvim_win_get_width(window) - info.textoff
            or state.textoff ~= info.textoff) then
          M.request_refresh()
        end
      end
      return false
    end,
  })
  local group = vim.api.nvim_create_augroup("MdwrapDisplay", { clear = true })
  local known_windows = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do known_windows[window] = true end
  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    callback = function()
      local parent = windows[vim.api.nvim_get_current_win()]
        or windows[vim.fn.win_getid(vim.fn.winnr("#"))]
      for _, window in ipairs(vim.api.nvim_list_wins()) do
        if not known_windows[window] then
          known_windows[window] = true
          if parent and vim.api.nvim_win_get_config(window).relative == "" then
            changing = true
            for name, value in pairs(managed) do
              if vim.api.nvim_get_option_value(name, { win = window, scope = "local" }) == value then
                vim.api.nvim_set_option_value(name, parent.saved[name], { win = window, scope = "local" })
              end
            end
            changing = false
          end
        end
      end
      M.request_refresh()
    end,
  })
  vim.api.nvim_create_autocmd({
    "BufWinEnter", "WinEnter", "WinResized", "VimResized", "WinScrolled", "TextChanged", "TextChangedI", "TextChangedP",
    "CursorMoved", "CursorMovedI", "ModeChanged", "OptionSet",
  }, {
    group = group,
    callback = function(event)
      if changing then return end
      if event.event == "OptionSet" then
        local window = vim.api.nvim_get_current_win()
        local window_state = windows[window]
        if window_state and managed[event.match] ~= nil and vim.v.option_command ~= "setglobal" then
          window_state.saved[event.match] = vim.api.nvim_get_option_value(event.match, { win = window, scope = "local" })
        end
        for _, state in pairs(windows) do state.cache = {} end
      end
      if not display_mode() then
        local targets = vim.tbl_keys(windows)
        for _, window in ipairs(targets) do release(window) end
      end
      M.request_refresh()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      release_buffer(event.buf)
      buffers[event.buf], parsed[event.buf] = nil, nil
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local window = tonumber(event.match)
      if window then
        known_windows[window] = nil
        release(window)
      end
    end,
  })
  return true
end

function M.render(context)
  if not configured then return end
  local state = buffers[context.buf] or { enabled = true }
  state.rendered = true
  buffers[context.buf] = state
  M.request_refresh()
end

function M.clear(context)
  local state = buffers[context.buf]
  if not state then return end
  state.rendered = false
  M.request_refresh()
end

function M.command(action)
  action = action ~= "" and action or "toggle"
  if action ~= "enable" and action ~= "disable" and action ~= "toggle" then
    notify("expected enable, disable or toggle")
    return
  end
  local buffer = vim.api.nvim_get_current_buf()
  if not configured then
    notify("pass mdwrap.integrations.render_markdown.extend(render_opts) to render-markdown.setup() first")
    return
  end
  local state = buffers[buffer] or { enabled = true }
  buffers[buffer] = state
  state.enabled = action == "enable" or (action == "toggle" and not state.enabled)
  if action == "enable" then state.failed = nil end
  if not state.enabled then release_buffer(buffer) end
  M.request_refresh()
end

return M
