import logging
import os
from pathlib import Path
import unittest

import pynvim


logging.disable(logging.CRITICAL)
ROOT = Path(__file__).resolve().parents[2]
RENDER = Path(os.environ.get("RENDER_MARKDOWN_PATH", Path.home() / ".local/share/nvim/lazy/render-markdown.nvim"))


class DisplayTests(unittest.TestCase):
    def setUp(self):
        self.editor = pynvim.attach("child", argv=[
            "nvim", "--embed", "--headless", "--clean", "-n", "-u", str(ROOT / "tests/minimal_init.lua"),
        ])
        self.editor.ui_attach(40, 16, rgb=True)
        self.editor.exec_lua("""
            vim.o.number = false
            vim.o.relativenumber = false
            vim.o.signcolumn = 'no'
            vim.o.foldcolumn = '0'
            vim.o.laststatus = 0
            vim.o.ruler = false
            vim.o.wrap = false
            vim.o.linebreak = true
            vim.o.breakindent = true
            vim.o.showbreak = '>>'
            vim.o.list = true
            vim.o.conceallevel = 3
            vim.o.concealcursor = 'n'
            _G.display_messages = {}
            vim.notify = function(message) table.insert(_G.display_messages, message) end
        """)

    def tearDown(self):
        try:
            self.editor.command("qa!")
        except (EOFError, OSError):
            pass
        self.editor.close()

    def settle(self):
        self.editor.exec_lua("vim.wait(60, function() return false end, 5)")
        self.editor.command("redraw!")

    def source(self, lines):
        self.editor.exec_lua("""
            local lines = ...
            vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
            vim.bo.filetype = 'markdown'
            vim.bo.modified = false
            vim.treesitter.start(0, 'markdown')
        """, lines)

    def render(self, lines, width=40, display_options=None):
        self.editor.ui_try_resize(width, 16)
        self.source(lines)
        self.editor.exec_lua("""
            _G.render_opts = require('mdwrap.integrations.render_markdown').extend({}, ...)
            _G.render_opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """, display_options or {})
        self.settle()

    def rows(self, count=5, window=0):
        return self.editor.exec_lua("""
            local count, window = ...
            local position = vim.api.nvim_win_get_position(window)
            local width = vim.api.nvim_win_get_width(window)
            local rows = {}
            for row = 1, count do
                local cells = {}
                for column = 1, width do
                    cells[#cells + 1] = vim.fn.screenstring(position[1] + row, position[2] + column)
                end
                rows[#rows + 1] = table.concat(cells):gsub(' +$', '')
            end
            return rows
        """, count, window)

    def marks(self):
        return self.editor.exec_lua("""
            local result = {}
            for name, namespace in pairs(vim.api.nvim_get_namespaces()) do
                if name:match('^mdwrap%.display%.') then
                    vim.list_extend(result, vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {details = true}))
                end
            end
            return result
        """)

    def snapshot(self):
        return self.editor.exec_lua("""
            return {
                lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
                tick = vim.api.nvim_buf_get_changedtick(0), modified = vim.bo.modified,
                undo = vim.fn.undotree(), register = vim.fn.getreginfo('a'),
            }
        """)

    def option(self, name):
        return self.editor.eval("&" + name)

    def test_sentence_break_and_no_text_changes(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        self.editor.funcs.setreg("a", "unchanged")
        before = self.snapshot()
        self.editor.exec_lua("""
            local opts = require('mdwrap.integrations.render_markdown').extend({})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence.", "Last sentence."])
        self.assertTrue(self.marks())
        self.assertEqual(before, self.snapshot())
        self.editor.exec_lua("for _ = 1, 5 do require('mdwrap.display').refresh() end")
        self.assertEqual(before, self.snapshot())
        self.editor.command("normal! 0gj")
        self.assertEqual(self.editor.current.window.cursor[0], 1)
        self.editor.command('normal! "ayy')
        self.assertEqual(self.editor.funcs.getreg("a"), before["lines"][0] + "\n")
        self.assertGreater(self.editor.funcs.search("Last", "w"), 0)

    def test_mapped_conceal_coordinates(self):
        self.source(["**中文** 后文"])
        mapped = self.editor.exec_lua("return require('mdwrap.atoms').atomize_mapped('**中文** 后文')")
        self.assertEqual([item["text"] for item in mapped], ["中", "文", " ", "后", "文"])
        self.assertEqual([(item["sc"], item["ec"]) for item in mapped], [(0, 5), (5, 10), (10, 11), (11, 14), (14, 17)])
        self.assertEqual(sum(item["width"] for item in mapped), 9)

    def test_display_wrap_sentence_override_does_not_change_formatter(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        before = self.snapshot()
        self.editor.exec_lua("""
            require('mdwrap').setup({wrap_sentence = false})
            local opts = require('mdwrap.integrations.render_markdown').extend({}, {wrap_sentence = true})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence. Last", "sentence."])
        self.assertFalse(self.editor.exec_lua("return require('mdwrap').options.wrap_sentence"))
        self.assertEqual(before, self.snapshot())

    def test_display_wrap_sentence_false_overrides_formatter_true(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        self.editor.exec_lua("""
            require('mdwrap').setup({wrap_sentence = true})
            local opts = require('mdwrap.integrations.render_markdown').extend({}, {wrap_sentence = false})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence.", "Last sentence."])
        self.assertTrue(self.editor.exec_lua("return require('mdwrap').options.wrap_sentence"))

    def test_display_wrap_sentence_inherits_formatter_when_omitted(self):
        self.editor.exec_lua("require('mdwrap').setup({wrap_sentence = true})")
        self.render(["First sentence. Second sentence. Last sentence."])
        self.assertEqual(self.rows(2), ["First sentence. Second sentence. Last", "sentence."])

    def test_display_wrap_sentence_fills_cjk_rows(self):
        self.editor.ui_try_resize(20, 16)
        self.source(["这是第一句。这是第二句。这是第三句。这是第四句。"])
        before = self.snapshot()
        self.editor.exec_lua("""
            local opts = require('mdwrap.integrations.render_markdown').extend({}, {wrap_sentence = true})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertEqual(self.rows(3), ["这是第一句。这是第二", "句。这是第三句。这是", "第四句。"])
        self.assertEqual(before, self.snapshot())

    def test_display_max_width_caps_wide_windows(self):
        self.render(["中" * 30], width=40, display_options={"max_width": 20, "wrap_sentence": True})
        before = self.snapshot()
        self.assertEqual(self.rows(3), ["中" * 10] * 3)
        self.editor.ui_try_resize(60, 16)
        self.settle()
        self.assertEqual(self.rows(3), ["中" * 10] * 3)
        self.editor.ui_try_resize(16, 16)
        self.settle()
        self.assertEqual(self.rows(4), ["中" * 8] * 3 + ["中" * 6])
        self.assertEqual(before, self.snapshot())

    def test_display_max_width_includes_list_indent(self):
        self.render(["- " + "中" * 18], width=40, display_options={"max_width": 20, "wrap_sentence": True})
        self.assertEqual(self.rows(2), ["- " + "中" * 9, "  " + "中" * 9])

    def test_display_max_width_120_in_large_window(self):
        self.render(["中" * 150], width=180, display_options={"max_width": 120, "wrap_sentence": True})
        self.assertEqual(self.rows(3), ["中" * 60] * 2 + ["中" * 30])

    def test_display_max_width_respects_number_column_in_narrow_window(self):
        self.render(["中" * 30], width=20, display_options={"max_width": 20, "wrap_sentence": True})
        self.editor.command("setlocal number numberwidth=4")
        self.settle()
        self.assertEqual(self.rows(4), ["  1 " + "中" * 8] + ["    " + "中" * 8] * 2 + ["    " + "中" * 6])

    def test_display_max_width_can_be_removed_without_rewrapping_callbacks(self):
        self.render(["中" * 30], width=40, display_options={"max_width": 20, "wrap_sentence": True})
        self.assertEqual(self.rows(3), ["中" * 10] * 3)
        self.editor.exec_lua("require('mdwrap.integrations.render_markdown').extend(_G.render_opts, {wrap_sentence = true})")
        self.settle()
        self.assertEqual(self.rows(2), ["中" * 20, "中" * 10])

    def test_display_max_width_rejects_invalid_values(self):
        for width in (0, -1, 2.5, "20", False):
            result = self.editor.exec_lua("""
                local width = ...
                local ok, message = pcall(require('mdwrap.integrations.render_markdown').extend, {}, {max_width = width})
                return {ok, tostring(message)}
            """, width)
            self.assertFalse(result[0], width)
            self.assertIn("max_width must be a positive integer", result[1])
        self.assertFalse(self.option("wrap"))

    def test_new_adapter_options_restore_formatter_inheritance(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        self.editor.exec_lua("""
            local adapter = require('mdwrap.integrations.render_markdown')
            local opts = adapter.extend({}, {wrap_sentence = true})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence. Last", "sentence."])
        self.editor.exec_lua("require('mdwrap.integrations.render_markdown').extend({})")
        self.settle()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence.", "Last sentence."])

    def test_display_options_can_refresh_without_duplicate_callbacks(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        self.editor.exec_lua("""
            _G.render_count = 0
            _G.render_opts = require('mdwrap.integrations.render_markdown').extend({
                on = {render = function() _G.render_count = _G.render_count + 1 end},
            })
            _G.render_opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence.", "Last sentence."])
        self.assertTrue(self.editor.exec_lua("""
            return require('mdwrap.integrations.render_markdown').extend(_G.render_opts, {wrap_sentence = true}) == _G.render_opts
        """))
        self.settle()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence. Last", "sentence."])
        self.editor.exec_lua("_G.render_opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})")
        self.settle()
        self.assertEqual(self.editor.exec_lua("return _G.render_count"), 2)

    def test_concealed_bold_and_source_mapping(self):
        self.render(["**中文句子。** 后面的句子。最后一句。"], width=20)
        self.assertEqual(self.rows(3), ["中文句子。", "后面的句子。", "最后一句。"])

    def test_break_before_query_concealed_bold_keeps_display_plan(self):
        self.render(["First sentence. **Second sentence.** Last sentence."], width=24)
        before = self.snapshot()
        self.assertTrue(self.marks())
        self.assertEqual(self.rows(3), ["First sentence.", "Second sentence.", "Last sentence."])
        self.settle()
        self.assertEqual(before, self.snapshot())

    def test_break_before_extmark_concealed_prefix_keeps_display_plan(self):
        self.source(["First sentence. ~~Second sentence.~~ Last sentence."])
        self.editor.ui_try_resize(24, 16)
        self.editor.exec_lua("""
            vim.treesitter.query.set('markdown_inline', 'highlights', '')
            local namespace = vim.api.nvim_create_namespace('display-gap-test')
            vim.api.nvim_buf_set_extmark(0, namespace, 0, 16, {end_col = 18, conceal = ''})
            vim.api.nvim_buf_set_extmark(0, namespace, 0, 34, {end_col = 36, conceal = ''})
            local opts = require('mdwrap.integrations.render_markdown').extend({})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertTrue(self.marks())
        self.assertEqual(self.rows(3), ["First sentence.", "Second sentence.", "Last sentence."])

    def test_visible_gap_bytes_still_use_native_wrap(self):
        self.source(["First sentence. **Second sentence.** Last sentence."])
        self.editor.ui_try_resize(24, 16)
        self.editor.exec_lua("""
            local original = require('mdwrap.atoms').atomize_mapped
            require('mdwrap.atoms').atomize_mapped = function(...)
                local mapped, hidden = original(...)
                mapped[5].sc = mapped[5].sc + 1
                return mapped, hidden
            end
            local opts = require('mdwrap.integrations.render_markdown').extend({})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertFalse(self.marks())
        self.assertEqual(self.editor.exec_lua("return _G.display_messages"), [])

    def test_spaces_are_not_normalized(self):
        self.render(["First.   Second.   Third.   Fourth."], width=24)
        self.assertEqual(self.rows(2), ["First.   Second.", "Third.   Fourth."])

    def test_cjk_fallback_stays_inside_window(self):
        self.render(["中" * 15], width=12)
        self.assertEqual(self.rows(3), ["中" * 6, "中" * 6, "中" * 3])

    def test_list_hanging_indent(self):
        self.render(["- First sentence. Second sentence. Last sentence."], width=30)
        self.assertEqual(self.rows(3), ["- First sentence.", "  Second sentence.", "  Last sentence."])

    def test_list_physical_continuation_keeps_hanging_indent(self):
        for marker, indentation in (("- ", "  "), ("1. ", "   "), ("  - ", "    ")):
            with self.subTest(marker=marker):
                lines = [marker + "one", indentation + "First sentence. Second sentence. Last sentence."]
                self.render(lines, width=30)
                before = self.snapshot()
                self.assertEqual(self.rows(4), [
                    marker + "one", indentation + "First sentence.",
                    indentation + "Second sentence.", indentation + "Last sentence.",
                ])
                self.settle()
                self.assertEqual(before, self.snapshot())

    def test_lazy_list_continuation_keeps_hanging_indent(self):
        self.render(["- one", "First sentence. Second sentence. Last sentence."], width=30)
        self.assertEqual(self.rows(4), [
            "- one", "First sentence.", "  Second sentence.", "  Last sentence.",
        ])

    def test_list_continuation_fill_reserves_initial_source_indent(self):
        self.render(["- one", "  " + "中" * 28], width=20, display_options={"wrap_sentence": True})
        self.assertEqual(self.rows(5), ["- one"] + ["  " + "中" * 9] * 3 + ["  中"])

    def test_conceal_replacement_is_hidden_at_level_three(self):
        self.render(["- First sentence. Second sentence. Last sentence."], width=24)
        self.editor.exec_lua("""
            local namespace = vim.api.nvim_create_namespace('display-test')
            vim.api.nvim_buf_set_extmark(0, namespace, 0, 0, {end_col = 1, conceal = '>'})
            require('mdwrap.display').refresh()
        """)
        self.settle()
        self.assertEqual(self.rows(3), [" First sentence.", " Second sentence.", " Last sentence."])

    def test_number_column_reduces_available_width(self):
        self.editor.command("setlocal number numberwidth=4")
        self.render(["First sentence. Second sentence. Last sentence."], width=34)
        self.assertEqual([row[4:] for row in self.rows(3)], [
            "First sentence.", "Second sentence.", "Last sentence.",
        ])

    def test_automatic_sign_column_refreshes_without_other_events(self):
        self.editor.command("setlocal signcolumn=auto")
        self.render(["First sentence. Second sentence. Last sentence."], width=34)
        before = self.snapshot()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence.", "Last sentence."])
        self.editor.exec_lua("""
            _G.sign_namespace = vim.api.nvim_create_namespace('display-sign-test')
            vim.defer_fn(function()
                vim.api.nvim_buf_set_extmark(0, _G.sign_namespace, 0, 0, {sign_text = '!'})
            end, 10)
        """)
        self.settle()
        self.settle()
        self.assertEqual(self.rows(2), ["! First sentence.", "  Second sentence. Last sentence."])
        self.editor.exec_lua("""
            vim.defer_fn(function()
                vim.api.nvim_buf_clear_namespace(0, _G.sign_namespace, 0, -1)
            end, 10)
        """)
        self.settle()
        self.settle()
        self.assertEqual(self.rows(2), ["First sentence. Second sentence.", "Last sentence."])
        self.assertEqual(before, self.snapshot())

    def test_stable_redraw_does_not_replan(self):
        self.render(["First sentence. Second sentence. Last sentence."], width=34)
        self.settle()
        self.editor.exec_lua("""
            local display = require('mdwrap.display')
            local refresh = display.refresh
            _G.refresh_count = 0
            display.refresh = function()
                _G.refresh_count = _G.refresh_count + 1
                return refresh()
            end
        """)
        for _ in range(3):
            self.settle()
        self.assertEqual(self.editor.exec_lua("return _G.refresh_count"), 0)

    def test_variable_continuation_width_uses_native_wrap(self):
        self.editor.command("setlocal number")
        self.editor.command("set cpoptions+=n")
        self.render(["First sentence. Second sentence. Last sentence."], width=34)
        self.assertFalse(self.marks())
        self.assertTrue(self.option("wrap"))

    def test_physical_newlines_and_non_content_blocks(self):
        lines = [
            "First sentence. Second sentence. Last sentence.",
            "Another sentence. Final sentence.", "", "```", "x" * 80, "```", "",
            "<!-- mdwrap-ignore-line -->", "First sentence. Second sentence. Last sentence.",
        ]
        self.render(lines, width=30)
        self.assertEqual(self.rows(5), [
            "First sentence.", "Second sentence.", "Last sentence.",
            "Another sentence.", "Final sentence.",
        ])
        self.assertEqual(self.editor.current.buffer[:], lines)
        self.assertTrue(all(mark[1] < 2 for mark in self.marks()))

    def test_edit_scroll_and_buffer_replacement(self):
        self.render(["First sentence. Second sentence. Last sentence."] * 50, width=30)
        original = self.editor.current.buffer.handle
        before = self.snapshot()
        self.editor.command("normal! Gzt")
        self.settle()
        self.assertTrue(self.marks())
        self.assertTrue(all(mark[1] >= 40 for mark in self.marks()))
        self.assertEqual(before, self.snapshot())
        self.editor.api.buf_set_lines(0, 49, 50, False, ["New sentence. Another sentence. Final sentence."])
        self.settle()
        self.assertEqual(self.rows(3), ["New sentence.", "Another sentence.", "Final sentence."])
        self.editor.command("enew!")
        self.settle()
        self.assertFalse(self.option("wrap"))
        self.editor.command("bwipeout! #")
        self.settle()
        self.assertFalse(self.editor.api.buf_is_valid(original))

    def test_full_row_reserves_original_boundary_space(self):
        self.render(["First sentence. Second sentence. Last sentence."], width=32)
        self.assertEqual(self.rows(2), ["First sentence.", "Second sentence. Last sentence."])

    def test_independent_windows_and_resize(self):
        self.render(["First sentence. Second sentence. Last sentence."], width=80)
        original = self.editor.current.window.handle
        self.editor.command("vsplit")
        narrow = self.editor.current.window.handle
        self.editor.api.win_set_width(narrow, 30)
        self.settle()
        self.assertEqual(self.rows(3, narrow), ["First sentence.", "Second sentence.", "Last sentence."])
        self.assertEqual(self.rows(1, original), ["First sentence. Second sentence. Last sentence."])
        self.editor.api.win_set_width(narrow, 40)
        self.settle()
        self.assertEqual(self.rows(2, narrow), ["First sentence. Second sentence.", "Last sentence."])
        self.editor.command("close")
        self.settle()
        self.assertEqual(self.rows(1), ["First sentence. Second sentence. Last sentence."])

    def test_external_marks_are_measured_in_their_own_window(self):
        self.render(["First sentence. Second sentence. Last sentence."], width=80)
        original = self.editor.current.window.handle
        self.editor.command("vsplit")
        narrow = self.editor.current.window.handle
        self.editor.api.win_set_width(narrow, 30)
        self.editor.exec_lua("""
            local window = ...
            local namespace = vim.api.nvim_create_namespace('display-test')
            vim.api.nvim__ns_set(namespace, {wins = {window}})
            vim.api.nvim_buf_set_extmark(0, namespace, 0, 0, {virt_text = {{'ICON '}}, virt_text_pos = 'inline'})
            require('mdwrap.display').refresh()
        """, original)
        self.settle()
        self.assertEqual(self.rows(3, narrow), ["First sentence.", "Second sentence.", "Last sentence."])
        self.assertEqual(self.rows(2, original), ["ICON First sentence. Second sentence.", "Last sentence."])

    def test_new_split_does_not_retain_inherited_managed_options(self):
        self.render(["First sentence. Second sentence. Last sentence."], width=80)
        self.editor.command("vsplit")
        self.settle()
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        result = self.editor.exec_lua("""
            local result = {}
            for _, window in ipairs(vim.api.nvim_list_wins()) do
                result[#result + 1] = {vim.wo[window].wrap, vim.wo[window].list, vim.wo[window].showbreak}
            end
            return result
        """)
        self.assertEqual(result, [[False, True, ">>"], [False, True, ">>"]])

    def test_modes_and_option_restoration(self):
        self.render(["First sentence. Second sentence. Last sentence."])
        before = self.snapshot()
        for key in ("i", "v", "V", "\x16"):
            self.editor.input(key)
            self.settle()
            self.assertFalse(self.marks())
            self.assertFalse(self.option("wrap"))
            self.assertTrue(self.option("linebreak"))
            self.assertTrue(self.option("breakindent"))
            self.assertTrue(self.option("list"))
            self.assertEqual(self.option("showbreak"), ">>")
            self.editor.input("\x1b")
            self.settle()
            self.assertTrue(self.marks())
        self.assertEqual(before, self.snapshot())

    def test_clear_and_buffer_toggle(self):
        self.render(["First sentence. Second sentence. Last sentence."])
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        self.assertFalse(self.marks())
        self.assertFalse(self.option("wrap"))
        self.editor.command("MdwrapDisplay")
        self.settle()
        self.assertTrue(self.marks())
        self.editor.exec_lua("_G.render_opts.on.clear({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})")
        self.settle()
        self.assertFalse(self.marks())
        self.assertFalse(self.option("wrap"))

    def test_command_without_integration_explains_setup(self):
        self.editor.command("MdwrapDisplay enable")
        messages = self.editor.exec_lua("return _G.display_messages")
        self.assertEqual(len(messages), 1)
        self.assertIn("render-markdown.setup", messages[0])
        self.assertFalse(self.option("wrap"))

    def test_enable_before_first_render_waits_for_callback(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        before = self.snapshot()
        self.editor.exec_lua("_G.render_opts = require('mdwrap.integrations.render_markdown').extend({})")
        self.editor.command("MdwrapDisplay enable")
        self.settle()
        self.assertEqual(self.editor.exec_lua("return _G.display_messages"), [])
        self.assertFalse(self.marks())
        self.assertFalse(self.option("wrap"))
        self.editor.exec_lua("_G.render_opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})")
        self.settle()
        self.assertTrue(self.marks())
        self.assertTrue(self.option("wrap"))
        self.assertEqual(before, self.snapshot())

    def test_disable_before_first_render_survives_callback(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        self.editor.exec_lua("_G.render_opts = require('mdwrap.integrations.render_markdown').extend({})")
        self.editor.command("MdwrapDisplay disable")
        self.editor.exec_lua("_G.render_opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})")
        self.settle()
        self.assertEqual(self.editor.exec_lua("return _G.display_messages"), [])
        self.assertFalse(self.marks())
        self.assertFalse(self.option("wrap"))
        self.editor.command("MdwrapDisplay toggle")
        self.settle()
        self.assertTrue(self.marks())

    def test_user_option_changes_survive_disable(self):
        self.render(["First sentence. Second sentence. Last sentence."])
        self.editor.command("setlocal showbreak=NEW")
        self.settle()
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        self.assertEqual(self.option("showbreak"), "NEW")

    def test_explicit_managed_values_survive_disable(self):
        self.render(["First sentence. Second sentence. Last sentence."])
        self.editor.command("setlocal wrap nolinebreak nobreakindent nolist showbreak=NONE")
        self.settle()
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        self.assertTrue(self.option("wrap"))
        self.assertFalse(self.option("linebreak"))
        self.assertFalse(self.option("breakindent"))
        self.assertFalse(self.option("list"))
        self.assertEqual(self.option("showbreak"), "NONE")

    def test_global_only_option_changes_do_not_replace_saved_local_values(self):
        self.render(["First sentence. Second sentence. Last sentence."])
        self.editor.command("setglobal wrap nolinebreak nobreakindent nolist showbreak=NONE")
        self.settle()
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        self.assertFalse(self.option("wrap"))
        self.assertTrue(self.option("linebreak"))
        self.assertTrue(self.option("breakindent"))
        self.assertTrue(self.option("list"))
        self.assertEqual(self.editor.api.get_option_value("showbreak", {"scope": "local", "win": 0}), "")

    def test_explicit_option_changes_are_saved_in_the_target_window(self):
        self.render(["First sentence. Second sentence. Last sentence."], width=80)
        original = self.editor.current.window.handle
        self.editor.command("vsplit")
        self.settle()
        self.editor.api.set_option_value("wrap", True, {"win": original, "scope": "local"})
        self.settle()
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        self.assertTrue(self.editor.api.get_option_value("wrap", {"win": original, "scope": "local"}))
        self.assertFalse(self.option("wrap"))

    def test_global_local_option_inheritance_is_restored(self):
        self.render(["First sentence. Second sentence. Last sentence."])
        self.editor.command("setglobal showbreak=GLOBAL")
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        self.assertEqual(self.option("showbreak"), "GLOBAL")
        self.assertEqual(self.editor.exec_lua("return vim.api.nvim_get_option_value('showbreak', {scope = 'local', win = 0})"), "")

    def test_acquiring_options_preserves_global_defaults(self):
        defaults = self.editor.exec_lua("""
            local result = {}
            for _, name in ipairs({'wrap', 'linebreak', 'breakindent', 'showbreak', 'list'}) do
                result[name] = vim.api.nvim_get_option_value(name, {scope = 'global'})
            end
            return result
        """)
        self.render(["First sentence. Second sentence. Last sentence."])
        for name, value in defaults.items():
            with self.subTest(name=name):
                self.assertEqual(self.editor.api.get_option_value(name, {"scope": "global"}), value)

    def test_restoring_options_preserves_distinct_global_and_local_values(self):
        self.editor.command("setglobal wrap")
        self.editor.command("setlocal nowrap")
        self.render(["First sentence. Second sentence. Last sentence."])
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        self.assertTrue(self.editor.api.get_option_value("wrap", {"scope": "global"}))
        self.assertFalse(self.option("wrap"))

    def test_new_tab_option_repair_preserves_global_defaults(self):
        self.render(["First sentence. Second sentence. Last sentence."])
        self.editor.command("tabnew")
        self.settle()
        self.assertFalse(self.editor.api.get_option_value("wrap", {"scope": "global"}))
        self.assertFalse(self.option("wrap"))

    def test_new_split_option_repair_preserves_distinct_global_defaults(self):
        self.editor.command("setglobal wrap")
        self.editor.command("setlocal nowrap")
        self.render(["First sentence. Second sentence. Last sentence."], width=80)
        self.editor.command("vsplit")
        self.settle()
        self.assertTrue(self.editor.api.get_option_value("wrap", {"scope": "global"}))
        self.editor.command("MdwrapDisplay disable")
        self.settle()
        self.assertFalse(self.option("wrap"))
        self.editor.command("close")
        self.assertFalse(self.option("wrap"))
        self.assertTrue(self.editor.api.get_option_value("wrap", {"scope": "global"}))

    def test_own_marks_do_not_affect_hard_formatting(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        before = self.editor.exec_lua("return require('mdwrap').format_lines(vim.api.nvim_buf_get_lines(0, 0, -1, false), {bufnr = vim.api.nvim_get_current_buf(), width = 32})")
        self.editor.exec_lua("""
            local opts = require('mdwrap.integrations.render_markdown').extend({})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        after = self.editor.exec_lua("return require('mdwrap').format_lines(vim.api.nvim_buf_get_lines(0, 0, -1, false), {bufnr = vim.api.nvim_get_current_buf(), width = 32})")
        self.assertEqual(before, after)

    def test_unsupported_lines_use_native_wrap(self):
        for source in ("First.\tSecond. Third. Fourth.", "x" * 80, "`" + "x" * 80 + "`",
                       "First. [Link](https://example.test/a/very/long/path). Last."):
            self.render([source], width=24)
            self.assertFalse(self.marks())
            self.assertTrue(self.option("wrap"))

    def test_cross_line_conceal_and_repeated_inline_marks_fall_back(self):
        self.render(["prefix", "First sentence. Second sentence. Last sentence.", "suffix"], width=30)
        self.editor.exec_lua("""
            local namespace = vim.api.nvim_create_namespace('display-test')
            vim.api.nvim_buf_set_extmark(0, namespace, 0, 0, {end_row = 2, end_col = 1, conceal = ''})
            require('mdwrap.display').refresh()
        """)
        self.assertFalse(self.marks())
        self.editor.exec_lua("""
            local namespace = vim.api.nvim_get_namespaces()['display-test']
            vim.api.nvim_buf_clear_namespace(0, namespace, 0, -1)
            vim.api.nvim_buf_set_extmark(0, namespace, 1, 0, {
                virt_text = {{'icon '}}, virt_text_pos = 'inline', virt_text_repeat_linebreak = true,
            })
            require('mdwrap.display').refresh()
        """)
        self.assertFalse(self.marks())

    def test_callback_composition_without_renderer_dependency(self):
        result = self.editor.exec_lua("""
            local count = 0
            local original = {on = {render = function() count = count + 1 end}, heading = {enabled = false}}
            local adapter = require('mdwrap.integrations.render_markdown')
            local extended = adapter.extend(original)
            extended.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
            return {count, original.on.render ~= extended.on.render, not extended.heading.enabled,
                adapter.extend(extended) == extended, package.loaded['render-markdown'] == nil}
        """)
        self.assertEqual(result, [1, True, True, True, True])

    def test_missing_api_is_safe(self):
        result = self.editor.exec_lua("""
            vim.api.nvim__ns_set = nil
            local opts = require('mdwrap.integrations.render_markdown').extend({heading = {enabled = false}})
            return {opts.on == nil, not opts.heading.enabled, #_G.display_messages}
        """)
        self.assertEqual(result, [True, True, 1])
        self.assertFalse(self.option("wrap"))

    def test_internal_failure_restores_options(self):
        self.source(["First sentence. Second sentence. Last sentence."])
        self.editor.exec_lua("""
            require('mdwrap.blocks').split = function() error('test parser failure') end
            local opts = require('mdwrap.integrations.render_markdown').extend({})
            opts.on.render({buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win()})
        """)
        self.settle()
        self.assertFalse(self.marks())
        self.assertFalse(self.option("wrap"))
        self.assertEqual(len(self.editor.exec_lua("return _G.display_messages")), 1)

    @unittest.skipUnless(RENDER.is_dir(), "render-markdown checkout unavailable")
    def test_real_render_markdown(self):
        self.editor.exec_lua("vim.opt.runtimepath:append(...)", str(RENDER))
        self.editor.exec_lua("""
            local opts = require('mdwrap.integrations.render_markdown').extend({
                debounce = 0, anti_conceal = {enabled = false},
                win_options = {concealcursor = {rendered = 'n'}},
                heading = {enabled = false}, code = {enabled = false},
            })
            require('render-markdown').setup(opts)
            vim.cmd('runtime! plugin/render-markdown.lua')
        """)
        self.source(["First sentence. [Link](https://x). Last sentence."])
        self.settle()
        self.assertTrue(self.marks())
        visible = "\n".join(self.rows(3))
        self.assertNotIn("https", visible)
        self.assertIn("Last sentence.", visible)
        self.assertNotIn("[", visible)
        self.editor.ui_try_resize(24, 16)
        self.settle()
        self.assertEqual(self.rows(3), ["First sentence.", "\U000f059f Link.", "Last sentence."])
        self.editor.exec_lua("require('render-markdown').disable()")
        self.settle()
        self.assertFalse(self.marks())


if __name__ == "__main__":
    if os.environ.get("REQUIRE_RENDER_MARKDOWN") and not RENDER.is_dir():
        raise SystemExit("RENDER_MARKDOWN_PATH must point to the integration-test checkout")
    unittest.main(verbosity=2)
