local helpers = dofile('tests/helpers.lua')

local child = helpers.new_child_neovim()
local expect, eq = helpers.expect, helpers.expect.equality
local new_set = MiniTest.new_set

local path_sep = package.config:sub(1, 1)
local project_root = vim.fn.fnamemodify(vim.fn.getcwd(), ':p')

-- Helpers with child processes
--stylua: ignore start
local load_module = function(config) child.mini_load('misc', config) end
local unload_module = function() child.mini_unload('misc') end
local reload_module = function(config) unload_module(); load_module(config) end
local set_cursor = function(...) return child.set_cursor(...) end
local get_cursor = function(...) return child.get_cursor(...) end
local set_lines = function(...) return child.set_lines(...) end
local get_lines = function(...) return child.get_lines(...) end
local type_keys = function(...) return child.type_keys(...) end
local make_path = function(...) return table.concat({...}, path_sep):gsub(path_sep .. path_sep, path_sep) end
local make_abspath = function(...) return make_path(project_root, ...) end
local getcwd = function() return child.fn.fnamemodify(child.fn.getcwd(), ':p') end
--stylua: ignore end

local get_fold_range = function(line_num) return { child.fn.foldclosed(line_num), child.fn.foldclosedend(line_num) } end

-- Output test set ============================================================
T = new_set({
  hooks = {
    pre_case = function()
      child.setup()
      load_module()
    end,
    post_once = child.stop,
  },
})

-- Unit tests =================================================================
T['setup()'] = new_set()

T['setup()']['creates side effects'] = function()
  -- Global variable
  eq(child.lua_get('type(_G.MiniMisc)'), 'table')
end

T['setup()']['creates `config` field'] = function()
  eq(child.lua_get('type(_G.MiniMisc.config)'), 'table')

  eq(child.lua_get('MiniMisc.config.make_global'), { 'put', 'put_text' })
end

T['setup()']['respects `config` argument'] = function()
  reload_module({ make_global = { 'put' } })
  eq(child.lua_get('MiniMisc.config.make_global'), { 'put' })
end

T['setup()']['validates `config` argument'] = function()
  unload_module()

  local expect_config_error = function(config, name, target_type)
    expect.error(load_module, vim.pesc(name) .. '.*' .. vim.pesc(target_type), config)
  end

  expect_config_error('a', 'config', 'table')
  expect_config_error({ make_global = 'a' }, 'make_global', 'table')
  expect_config_error({ make_global = { 'a' } }, 'make_global', 'actual fields')
end

T['setup()']['creates global functions'] = function()
  eq(child.lua_get('type(_G.put)'), 'function')
  eq(child.lua_get('type(_G.put_text)'), 'function')
end

T['bench_time()'] = new_set({
  hooks = {
    pre_case = function() child.lua('_G.f = function(ms) ms = ms or 10; vim.loop.sleep(ms); return ms end') end,
  },
})

local bench_time = function(...) return unpack(child.lua_get('{ MiniMisc.bench_time(_G.f, ...) }', { ... })) end

-- Validate that benchmark is within tolerable error from target. This is
-- needed due to random nature of benchmarks.
local validate_benchmark = function(time_tbl, target, error)
  error = error or 0.2
  local s, n = 0, 0
  for _, x in ipairs(time_tbl) do
    s, n = s + x, n + 1
  end

  eq(n * target * (1 - error) < s, true)
  eq(s < target * (1 + error) * n, true)
end

T['bench_time()']['works'] = function()
  local b, res = bench_time()
  -- By default should run function once
  eq(#b, 1)
  validate_benchmark(b, 0.01)
  -- Second value is function output
  eq(res, 10)
end

T['bench_time()']['respects `n` argument'] = function()
  local b, _ = bench_time(5)
  -- By default should run function once
  eq(#b, 5)
  validate_benchmark(b, 0.01)
end

T['bench_time()']['respects `...` as benched time arguments'] = function()
  local b, res = bench_time(1, 50)
  validate_benchmark(b, 0.05)
  -- Second value is function output
  eq(res, 50)
end

T['get_gutter_width()'] = new_set()

T['get_gutter_width()']['works'] = function()
  -- By default there is no gutter ('sign column')
  eq(child.lua_get('MiniMisc.get_gutter_width()'), 0)

  -- This setting indeed makes gutter with width of two columns
  child.wo.signcolumn = 'yes:1'
  eq(child.lua_get('MiniMisc.get_gutter_width()'), 2)
end

T['get_gutter_width()']['respects `win_id` argument'] = function()
  child.cmd('split')
  local windows = child.api.nvim_list_wins()

  child.api.nvim_win_set_option(windows[1], 'signcolumn', 'yes:1')
  eq(child.lua_get('MiniMisc.get_gutter_width(...)', { windows[2] }), 0)
end

T['move_selection()'] = new_set()

local move = function(direction) child.lua('MiniMisc.move_selection(...)', { direction }) end

-- These mappings also serve as tests for documented suggested mappings
local map_move = function(direction)
  local key = ({ left = 'H', down = 'J', up = 'K', right = 'L' })[direction]
  local rhs = string.format([[<Cmd>lua MiniMisc.move_selection('%s')<CR>]], direction)
  child.api.nvim_set_keymap('x', key, rhs, { noremap = true })
end

local validate_move_state = function(lines, selection)
  eq(get_lines(), lines)
  eq({ { child.fn.line('v'), child.fn.col('v') }, { child.fn.line('.'), child.fn.col('.') } }, selection)
end

local validate_move_state1d =
  function(line, range) validate_move_state({ line }, { { 1, range[1] }, { 1, range[2] } }) end

T['move_selection()']['works charwise horizontally'] = function()
  -- Test for this many moves because there can be special cases when movement
  -- involves second or second to last character
  set_lines({ 'XXabcd' })
  set_cursor(1, 0)
  type_keys('vl')
  validate_move_state1d('XXabcd', { 1, 2 })

  move('right')
  validate_move_state1d('aXXbcd', { 2, 3 })
  move('right')
  validate_move_state1d('abXXcd', { 3, 4 })
  move('right')
  validate_move_state1d('abcXXd', { 4, 5 })
  move('right')
  validate_move_state1d('abcdXX', { 5, 6 })
  -- Should allow to try to move past line end without error
  move('right')
  validate_move_state1d('abcdXX', { 5, 6 })

  move('left')
  validate_move_state1d('abcXXd', { 4, 5 })
  move('left')
  validate_move_state1d('abXXcd', { 3, 4 })
  move('left')
  validate_move_state1d('aXXbcd', { 2, 3 })
  move('left')
  validate_move_state1d('XXabcd', { 1, 2 })
  -- Should allow to try to move past line start without error
  move('left')
  validate_move_state1d('XXabcd', { 1, 2 })
end

T['move_selection()']['respects `v:count` charwise horizontally'] = function()
  map_move('right')
  map_move('left')

  set_lines({ 'XXabcd' })
  set_cursor(1, 0)
  type_keys('vl')
  validate_move_state1d('XXabcd', { 1, 2 })

  type_keys('1L')
  validate_move_state1d('aXXbcd', { 2, 3 })
  type_keys('2L')
  validate_move_state1d('abcXXd', { 4, 5 })
  -- Can allow overshoot without error
  type_keys('2L')
  validate_move_state1d('abcdXX', { 5, 6 })

  type_keys('1H')
  validate_move_state1d('abcXXd', { 4, 5 })
  type_keys('2H')
  validate_move_state1d('aXXbcd', { 2, 3 })
  -- Can allow overshoot without error
  type_keys('2H')
  validate_move_state1d('XXabcd', { 1, 2 })
end

T['move_selection()']['works charwise vertically'] = function()
  set_lines({ '1XXx', '2a', '3b', '4c', '5d' })
  set_cursor(1, 1)
  type_keys('vl')
  validate_move_state({ '1XXx', '2a', '3b', '4c', '5d' }, { { 1, 2 }, { 1, 3 } })

  move('down')
  validate_move_state({ '1x', '2XXa', '3b', '4c', '5d' }, { { 2, 2 }, { 2, 3 } })
  move('down')
  validate_move_state({ '1x', '2a', '3XXb', '4c', '5d' }, { { 3, 2 }, { 3, 3 } })
  move('down')
  validate_move_state({ '1x', '2a', '3b', '4XXc', '5d' }, { { 4, 2 }, { 4, 3 } })
  move('down')
  validate_move_state({ '1x', '2a', '3b', '4c', '5XXd' }, { { 5, 2 }, { 5, 3 } })
  -- Should allow to try to move past last line without error
  move('down')
  validate_move_state({ '1x', '2a', '3b', '4c', '5XXd' }, { { 5, 2 }, { 5, 3 } })

  move('up')
  validate_move_state({ '1x', '2a', '3b', '4XXc', '5d' }, { { 4, 2 }, { 4, 3 } })
  move('up')
  validate_move_state({ '1x', '2a', '3XXb', '4c', '5d' }, { { 3, 2 }, { 3, 3 } })
  move('up')
  validate_move_state({ '1x', '2XXa', '3b', '4c', '5d' }, { { 2, 2 }, { 2, 3 } })
  move('up')
  validate_move_state({ '1XXx', '2a', '3b', '4c', '5d' }, { { 1, 2 }, { 1, 3 } })
  -- Should allow to try to move past first line without error
  move('up')
  validate_move_state({ '1XXx', '2a', '3b', '4c', '5d' }, { { 1, 2 }, { 1, 3 } })
end

T['move_selection()']['respects `v:count` charwise vertically'] = function()
  map_move('down')
  map_move('up')

  set_lines({ '1XXx', '2a', '3b', '4c', '5d' })
  set_cursor(1, 1)
  type_keys('vl')
  validate_move_state({ '1XXx', '2a', '3b', '4c', '5d' }, { { 1, 2 }, { 1, 3 } })

  type_keys('1J')
  validate_move_state({ '1x', '2XXa', '3b', '4c', '5d' }, { { 2, 2 }, { 2, 3 } })
  type_keys('2J')
  validate_move_state({ '1x', '2a', '3b', '4XXc', '5d' }, { { 4, 2 }, { 4, 3 } })
  -- Should allow overshoot without error
  type_keys('2J')
  validate_move_state({ '1x', '2a', '3b', '4c', '5XXd' }, { { 5, 2 }, { 5, 3 } })

  type_keys('1K')
  validate_move_state({ '1x', '2a', '3b', '4XXc', '5d' }, { { 4, 2 }, { 4, 3 } })
  type_keys('2K')
  validate_move_state({ '1x', '2XXa', '3b', '4c', '5d' }, { { 2, 2 }, { 2, 3 } })
  -- Should allow overshoot without error
  type_keys('2K')
  validate_move_state({ '1XXx', '2a', '3b', '4c', '5d' }, { { 1, 2 }, { 1, 3 } })
end

T['move_selection()']['works with folds charwise'] = function()
  local setup_folds = function()
    child.ensure_normal_mode()
    set_lines({ '1XX', '2aa', '3bb', '4cc', '5YY' })

    -- Create fold
    type_keys('zE')
    set_cursor(2, 0)
    type_keys('zf', '2j')
  end

  -- Down
  setup_folds()
  set_cursor(1, 1)
  type_keys('vl')
  validate_move_state({ '1XX', '2aa', '3bb', '4cc', '5YY' }, { { 1, 2 }, { 1, 3 } })
  eq(get_fold_range(2), { 2, 4 })

  -- - When moving "into fold", it should open it
  move('down')
  validate_move_state({ '1', '2XXaa', '3bb', '4cc', '5YY' }, { { 2, 2 }, { 2, 3 } })
  eq(get_fold_range(2), { -1, -1 })

  -- Up
  setup_folds()
  set_cursor(5, 1)
  type_keys('vl')
  validate_move_state({ '1XX', '2aa', '3bb', '4cc', '5YY' }, { { 5, 2 }, { 5, 3 } })
  eq(get_fold_range(2), { 2, 4 })

  -- - When moving "into fold", it should open it. But it happens only after
  --   entering fold, so cursor is at the start of fold. Would be nice to
  --   change so that fold is opened before movement, but it requires some
  --   extra non-trivial steps.
  move('up')
  validate_move_state({ '1XX', '2YYaa', '3bb', '4cc', '5' }, { { 2, 2 }, { 2, 3 } })
  eq(get_fold_range(2), { -1, -1 })
end

T['move_selection()']['works charwise vertically on line start/end'] = function()
  -- Line start
  set_lines({ 'XXx', 'a', 'b' })
  set_cursor(1, 0)
  type_keys('vl')
  validate_move_state({ 'XXx', 'a', 'b' }, { { 1, 1 }, { 1, 2 } })

  move('down')
  validate_move_state({ 'x', 'XXa', 'b' }, { { 2, 1 }, { 2, 2 } })
  move('down')
  validate_move_state({ 'x', 'a', 'XXb' }, { { 3, 1 }, { 3, 2 } })
  move('up')
  validate_move_state({ 'x', 'XXa', 'b' }, { { 2, 1 }, { 2, 2 } })
  move('up')
  validate_move_state({ 'XXx', 'a', 'b' }, { { 1, 1 }, { 1, 2 } })

  child.ensure_normal_mode()

  -- Line end
  set_lines({ 'xXX', 'a', 'b' })
  set_cursor(1, 1)
  type_keys('vl')
  validate_move_state({ 'xXX', 'a', 'b' }, { { 1, 2 }, { 1, 3 } })

  move('down')
  validate_move_state({ 'x', 'aXX', 'b' }, { { 2, 2 }, { 2, 3 } })
  move('down')
  validate_move_state({ 'x', 'a', 'bXX' }, { { 3, 2 }, { 3, 3 } })
  move('up')
  validate_move_state({ 'x', 'aXX', 'b' }, { { 2, 2 }, { 2, 3 } })
  move('up')
  validate_move_state({ 'xXX', 'a', 'b' }, { { 1, 2 }, { 1, 3 } })

  child.ensure_normal_mode()

  -- Whole line (but in charwise mode)
  set_lines({ 'XX', '', '' })
  set_cursor(1, 0)
  type_keys('vl')
  validate_move_state({ 'XX', '', '' }, { { 1, 1 }, { 1, 2 } })

  move('down')
  validate_move_state({ '', 'XX', '' }, { { 2, 1 }, { 2, 2 } })
  move('down')
  validate_move_state({ '', '', 'XX' }, { { 3, 1 }, { 3, 2 } })
  move('up')
  validate_move_state({ '', 'XX', '' }, { { 2, 1 }, { 2, 2 } })
  move('up')
  validate_move_state({ 'XX', '', '' }, { { 1, 1 }, { 1, 2 } })
end

T['move_selection()']['works blockwise horizontally'] = function()
  set_lines({ 'XXabcd', 'XXabcd' })
  set_cursor(1, 0)
  type_keys('<C-v>', 'lj')
  validate_move_state({ 'XXabcd', 'XXabcd' }, { { 1, 1 }, { 2, 2 } })

  move('right')
  validate_move_state({ 'aXXbcd', 'aXXbcd' }, { { 1, 2 }, { 2, 3 } })
  move('right')
  validate_move_state({ 'abXXcd', 'abXXcd' }, { { 1, 3 }, { 2, 4 } })
  move('right')
  validate_move_state({ 'abcXXd', 'abcXXd' }, { { 1, 4 }, { 2, 5 } })
  move('right')
  validate_move_state({ 'abcdXX', 'abcdXX' }, { { 1, 5 }, { 2, 6 } })
  -- Should allow to try to move past line end without error
  move('right')
  validate_move_state({ 'abcdXX', 'abcdXX' }, { { 1, 5 }, { 2, 6 } })

  move('left')
  validate_move_state({ 'abcXXd', 'abcXXd' }, { { 1, 4 }, { 2, 5 } })
  move('left')
  validate_move_state({ 'abXXcd', 'abXXcd' }, { { 1, 3 }, { 2, 4 } })
  move('left')
  validate_move_state({ 'aXXbcd', 'aXXbcd' }, { { 1, 2 }, { 2, 3 } })
  move('left')
  validate_move_state({ 'XXabcd', 'XXabcd' }, { { 1, 1 }, { 2, 2 } })
  -- Should allow to try to move past line start without error
  move('left')
  validate_move_state({ 'XXabcd', 'XXabcd' }, { { 1, 1 }, { 2, 2 } })
end

T['move_selection()']['respects `v:count` blockwise horizontally'] = function()
  map_move('right')
  map_move('left')

  set_lines({ 'XXabcd', 'XXabcd' })
  set_cursor(1, 0)
  type_keys('<C-v>', 'lj')
  validate_move_state({ 'XXabcd', 'XXabcd' }, { { 1, 1 }, { 2, 2 } })

  type_keys('1L')
  validate_move_state({ 'aXXbcd', 'aXXbcd' }, { { 1, 2 }, { 2, 3 } })
  type_keys('2L')
  validate_move_state({ 'abcXXd', 'abcXXd' }, { { 1, 4 }, { 2, 5 } })
  -- Should allow overshoot without error
  type_keys('2L')
  validate_move_state({ 'abcdXX', 'abcdXX' }, { { 1, 5 }, { 2, 6 } })

  type_keys('1H')
  validate_move_state({ 'abcXXd', 'abcXXd' }, { { 1, 4 }, { 2, 5 } })
  type_keys('2H')
  validate_move_state({ 'aXXbcd', 'aXXbcd' }, { { 1, 2 }, { 2, 3 } })
  -- Should allow overshoot without error
  type_keys('2H')
  validate_move_state({ 'XXabcd', 'XXabcd' }, { { 1, 1 }, { 2, 2 } })
end

T['move_selection()']['works blockwise vertically'] = function()
  set_lines({ '1XXa', '2YYb', '3c', '4d', '5e' })
  set_cursor(1, 1)
  type_keys('<C-v>', 'lj')
  validate_move_state({ '1XXa', '2YYb', '3c', '4d', '5e' }, { { 1, 2 }, { 2, 3 } })

  move('down')
  validate_move_state({ '1a', '2XXb', '3YYc', '4d', '5e' }, { { 2, 2 }, { 3, 3 } })
  move('down')
  validate_move_state({ '1a', '2b', '3XXc', '4YYd', '5e' }, { { 3, 2 }, { 4, 3 } })
  move('down')
  validate_move_state({ '1a', '2b', '3c', '4XXd', '5YYe' }, { { 4, 2 }, { 5, 3 } })
  -- Should allow to try to move past last line without error and not
  -- going outside of buffer lines
  move('down')
  validate_move_state({ '1a', '2b', '3c', '4XXd', '5YYe' }, { { 4, 2 }, { 5, 3 } })

  move('up')
  validate_move_state({ '1a', '2b', '3XXc', '4YYd', '5e' }, { { 3, 2 }, { 4, 3 } })
  move('up')
  validate_move_state({ '1a', '2XXb', '3YYc', '4d', '5e' }, { { 2, 2 }, { 3, 3 } })
  move('up')
  validate_move_state({ '1XXa', '2YYb', '3c', '4d', '5e' }, { { 1, 2 }, { 2, 3 } })
  -- Should allow to try to move past first line without error
  move('up')
  validate_move_state({ '1XXa', '2YYb', '3c', '4d', '5e' }, { { 1, 2 }, { 2, 3 } })
end

T['move_selection()']['respects `v:count` blockwise vertically'] = function()
  map_move('down')
  map_move('up')

  set_lines({ '1XXa', '2YYb', '3c', '4d', '5e' })
  set_cursor(1, 1)
  type_keys('<C-v>', 'lj')
  validate_move_state({ '1XXa', '2YYb', '3c', '4d', '5e' }, { { 1, 2 }, { 2, 3 } })

  type_keys('1J')
  validate_move_state({ '1a', '2XXb', '3YYc', '4d', '5e' }, { { 2, 2 }, { 3, 3 } })
  type_keys('2J')
  validate_move_state({ '1a', '2b', '3c', '4XXd', '5YYe' }, { { 4, 2 }, { 5, 3 } })
  -- Should allow overshoot without error
  type_keys('2J')
  validate_move_state({ '1a', '2b', '3c', '4XXd', '5YYe' }, { { 4, 2 }, { 5, 3 } })

  type_keys('1K')
  validate_move_state({ '1a', '2b', '3XXc', '4YYd', '5e' }, { { 3, 2 }, { 4, 3 } })
  type_keys('2K')
  validate_move_state({ '1XXa', '2YYb', '3c', '4d', '5e' }, { { 1, 2 }, { 2, 3 } })
  -- Should allow overshoot without error
  type_keys('2K')
  validate_move_state({ '1XXa', '2YYb', '3c', '4d', '5e' }, { { 1, 2 }, { 2, 3 } })
end

T['move_selection()']['works with folds blockwise'] = function()
  local setup_folds = function()
    child.ensure_normal_mode()
    set_lines({ '1XX', '2YY', '3aa', '4bb', '5cc', '6XX', '7YY' })

    -- Create fold
    type_keys('zE')
    set_cursor(3, 0)
    type_keys('zf', '2j')
  end

  -- Down
  setup_folds()
  set_cursor(1, 1)
  type_keys('<C-v>', 'jl')
  validate_move_state({ '1XX', '2YY', '3aa', '4bb', '5cc', '6XX', '7YY' }, { { 1, 2 }, { 2, 3 } })
  eq(get_fold_range(3), { 3, 5 })

  -- - When moving "into fold", it should open it, but this is determined by
  --   top-left corner of selection. So in this case whole fold is selected.
  move('down')
  validate_move_state({ '1', '2XX', '3YYaa', '4bb', '5cc', '6XX', '7YY' }, { { 2, 2 }, { 5, 4 } })
  eq(get_fold_range(3), { 3, 5 })

  -- Up
  setup_folds()
  set_cursor(6, 1)
  type_keys('<C-v>', 'jl')
  validate_move_state({ '1XX', '2YY', '3aa', '4bb', '5cc', '6XX', '7YY' }, { { 6, 2 }, { 7, 3 } })
  eq(get_fold_range(3), { 3, 5 })

  -- - When moving "into fold", it should open it. But it happens only after
  --   entering fold, so cursor is at the start of fold. Would be nice to
  --   change so that fold is opened before movement, but it requires some
  --   extra non-trivial steps.
  move('up')
  validate_move_state({ '1XX', '2YY', '3XXaa', '4YYbb', '5cc', '6', '7' }, { { 3, 2 }, { 4, 3 } })
  eq(get_fold_range(2), { -1, -1 })
end

T['move_selection()']['works linewise horizontally'] = function()
  -- Should be the same as indent (`>`) and dedent (`<`)
  set_lines({ 'aa', '  bb' })
  set_cursor(1, 0)
  type_keys('Vj')
  validate_move_state({ 'aa', '  bb' }, { { 1, 1 }, { 2, 1 } })

  move('right')
  validate_move_state({ '\taa', '\t  bb' }, { { 1, 1 }, { 2, 1 } })
  move('right')
  validate_move_state({ '\t\taa', '\t\t  bb' }, { { 1, 1 }, { 2, 1 } })

  move('left')
  validate_move_state({ '\taa', '\t  bb' }, { { 1, 1 }, { 2, 1 } })
  move('left')
  validate_move_state({ 'aa', '  bb' }, { { 1, 1 }, { 2, 1 } })
  move('left')
  validate_move_state({ 'aa', 'bb' }, { { 1, 1 }, { 2, 1 } })
  -- Should allow to try impossible dedent without error
  move('left')
  validate_move_state({ 'aa', 'bb' }, { { 1, 1 }, { 2, 1 } })
end

T['move_selection()']['respects `v:count` linewise horizontally'] = function()
  map_move('right')
  map_move('left')

  set_lines({ 'aa', '  bb' })
  set_cursor(1, 0)
  type_keys('Vj')
  validate_move_state({ 'aa', '  bb' }, { { 1, 1 }, { 2, 1 } })

  type_keys('1L')
  validate_move_state({ '\taa', '\t  bb' }, { { 1, 1 }, { 2, 1 } })
  type_keys('2L')
  validate_move_state({ '\t\t\taa', '\t\t\t  bb' }, { { 1, 1 }, { 2, 1 } })

  type_keys('1H')
  validate_move_state({ '\t\taa', '\t\t  bb' }, { { 1, 1 }, { 2, 1 } })
  type_keys('2H')
  validate_move_state({ 'aa', '  bb' }, { { 1, 1 }, { 2, 1 } })
  -- Should allow overshoot without error
  type_keys('2H')
  validate_move_state({ 'aa', 'bb' }, { { 1, 1 }, { 2, 1 } })
end

T['move_selection()']['works linewise vertically'] = function()
  set_lines({ 'XX', 'YY', 'aa', 'bb', 'cc' })
  set_cursor(1, 0)
  type_keys('Vj')
  validate_move_state({ 'XX', 'YY', 'aa', 'bb', 'cc' }, { { 1, 1 }, { 2, 1 } })

  move('down')
  validate_move_state({ 'aa', 'XX', 'YY', 'bb', 'cc' }, { { 2, 1 }, { 3, 1 } })
  move('down')
  validate_move_state({ 'aa', 'bb', 'XX', 'YY', 'cc' }, { { 3, 1 }, { 4, 1 } })
  move('down')
  validate_move_state({ 'aa', 'bb', 'cc', 'XX', 'YY' }, { { 4, 1 }, { 5, 1 } })
  -- Should allow to try to move past last line without error
  move('down')
  validate_move_state({ 'aa', 'bb', 'cc', 'XX', 'YY' }, { { 4, 1 }, { 5, 1 } })

  move('up')
  validate_move_state({ 'aa', 'bb', 'XX', 'YY', 'cc' }, { { 3, 1 }, { 4, 1 } })
  move('up')
  validate_move_state({ 'aa', 'XX', 'YY', 'bb', 'cc' }, { { 2, 1 }, { 3, 1 } })
  move('up')
  validate_move_state({ 'XX', 'YY', 'aa', 'bb', 'cc' }, { { 1, 1 }, { 2, 1 } })
  -- Should allow to try to move past first line without error
  move('up')
  validate_move_state({ 'XX', 'YY', 'aa', 'bb', 'cc' }, { { 1, 1 }, { 2, 1 } })
end

T['move_selection()']['respects `v:count` linewise vertically'] = function()
  map_move('down')
  map_move('up')

  set_lines({ 'XX', 'YY', 'aa', 'bb', 'cc' })
  set_cursor(1, 0)
  type_keys('Vj')
  validate_move_state({ 'XX', 'YY', 'aa', 'bb', 'cc' }, { { 1, 1 }, { 2, 1 } })

  type_keys('1J')
  validate_move_state({ 'aa', 'XX', 'YY', 'bb', 'cc' }, { { 2, 1 }, { 3, 1 } })
  type_keys('2J')
  validate_move_state({ 'aa', 'bb', 'cc', 'XX', 'YY' }, { { 4, 1 }, { 5, 1 } })
  -- Should allow overshoot without error
  type_keys('2J')
  validate_move_state({ 'aa', 'bb', 'cc', 'XX', 'YY' }, { { 4, 1 }, { 5, 1 } })

  type_keys('1K')
  validate_move_state({ 'aa', 'bb', 'XX', 'YY', 'cc' }, { { 3, 1 }, { 4, 1 } })
  type_keys('2K')
  validate_move_state({ 'XX', 'YY', 'aa', 'bb', 'cc' }, { { 1, 1 }, { 2, 1 } })
  -- Should allow overshoot without error
  type_keys('2K')
  validate_move_state({ 'XX', 'YY', 'aa', 'bb', 'cc' }, { { 1, 1 }, { 2, 1 } })
end

T['move_selection()']['works with folds linewise'] = function()
  local setup_folds = function()
    child.ensure_normal_mode()
    set_lines({ '1XX', '2YY', '3aa', '4bb', '5cc', '6XX', '7YY' })

    -- Create fold
    type_keys('zE')
    set_cursor(3, 0)
    type_keys('zf', '2j')
  end

  -- Down
  setup_folds()
  set_cursor(1, 0)
  type_keys('Vj')
  validate_move_state({ '1XX', '2YY', '3aa', '4bb', '5cc', '6XX', '7YY' }, { { 1, 1 }, { 2, 1 } })
  eq(get_fold_range(3), { 3, 5 })

  -- - Folds should be moved altogether
  move('down')
  validate_move_state({ '3aa', '4bb', '5cc', '1XX', '2YY', '6XX', '7YY' }, { { 4, 1 }, { 5, 1 } })
  eq(get_fold_range(3), { 1, 3 })

  -- Up
  setup_folds()
  set_cursor(6, 0)
  type_keys('Vj')
  validate_move_state({ '1XX', '2YY', '3aa', '4bb', '5cc', '6XX', '7YY' }, { { 6, 1 }, { 7, 1 } })
  eq(get_fold_range(3), { 3, 5 })

  -- - Folds should be moved altogether
  move('up')
  validate_move_state({ '1XX', '2YY', '6XX', '7YY', '3aa', '4bb', '5cc' }, { { 3, 1 }, { 4, 1 } })
  eq(get_fold_range(5), { 5, 7 })
end

--stylua: ignore
T['move_selection()']['reindents linewise vertically'] = function()
  set_lines({ 'XX', 'YY', 'aa', '\tbb', '\t\tcc', '\tdd', 'ee' })
  set_cursor(1, 0)
  type_keys('Vj')
  validate_move_state({ 'XX', 'YY',   'aa',     '\tbb',   '\t\tcc', '\tdd', 'ee' }, { { 1, 1 }, { 2, 1 } })

  move('down')
  validate_move_state({ 'aa', 'XX',   'YY',     '\tbb',   '\t\tcc', '\tdd', 'ee' }, { { 2, 1 }, { 3, 1 } })
  move('down')
  validate_move_state({ 'aa', '\tbb', '\tXX',   '\tYY',   '\t\tcc', '\tdd', 'ee' }, { { 3, 1 }, { 4, 1 } })
  move('down')
  validate_move_state({ 'aa', '\tbb', '\t\tcc', '\t\tXX', '\t\tYY', '\tdd', 'ee' }, { { 4, 1 }, { 5, 1 } })
  move('down')
  validate_move_state({ 'aa', '\tbb', '\t\tcc', '\tdd',   '\tXX',   '\tYY', 'ee' }, { { 5, 1 }, { 6, 1 } })
  move('down')
  validate_move_state({ 'aa', '\tbb', '\t\tcc', '\tdd',   'ee',     'XX',   'YY' }, { { 6, 1 }, { 7, 1 } })
end

T['move_selection()']['moves cursor respecting initial `curswant`'] = function()
  set_lines({ 'aaX', 'aa', 'a', '', 'a', 'aa', 'aa' })
  set_cursor(1, 2)
  type_keys('v')
  validate_move_state({ 'aaX', 'aa', 'a', '', 'a', 'aa', 'aa' }, { { 1, 3 }, { 1, 3 } })

  move('down')
  validate_move_state({ 'aa', 'aaX', 'a', '', 'a', 'aa', 'aa' }, { { 2, 3 }, { 2, 3 } })
  move('down')
  validate_move_state({ 'aa', 'aa', 'aX', '', 'a', 'aa', 'aa' }, { { 3, 2 }, { 3, 2 } })
  move('down')
  validate_move_state({ 'aa', 'aa', 'a', 'X', 'a', 'aa', 'aa' }, { { 4, 1 }, { 4, 1 } })
  move('down')
  validate_move_state({ 'aa', 'aa', 'a', '', 'aX', 'aa', 'aa' }, { { 5, 2 }, { 5, 2 } })
  move('down')
  validate_move_state({ 'aa', 'aa', 'a', '', 'a', 'aaX', 'aa' }, { { 6, 3 }, { 6, 3 } })
  move('down')
  validate_move_state({ 'aa', 'aa', 'a', '', 'a', 'aa', 'aaX' }, { { 7, 3 }, { 7, 3 } })

  move('up')
  validate_move_state({ 'aa', 'aa', 'a', '', 'a', 'aaX', 'aa' }, { { 6, 3 }, { 6, 3 } })
  move('up')
  validate_move_state({ 'aa', 'aa', 'a', '', 'aX', 'aa', 'aa' }, { { 5, 2 }, { 5, 2 } })
  move('up')
  validate_move_state({ 'aa', 'aa', 'a', 'X', 'a', 'aa', 'aa' }, { { 4, 1 }, { 4, 1 } })
  move('up')
  validate_move_state({ 'aa', 'aa', 'aX', '', 'a', 'aa', 'aa' }, { { 3, 2 }, { 3, 2 } })
  move('up')
  validate_move_state({ 'aa', 'aaX', 'a', '', 'a', 'aa', 'aa' }, { { 2, 3 }, { 2, 3 } })
  move('up')
  validate_move_state({ 'aaX', 'aa', 'a', '', 'a', 'aa', 'aa' }, { { 1, 3 }, { 1, 3 } })

  -- Single horizontal move should reset `curswant`
  move('down')
  validate_move_state({ 'aa', 'aaX', 'a', '', 'a', 'aa', 'aa' }, { { 2, 3 }, { 2, 3 } })
  move('left')
  validate_move_state({ 'aa', 'aXa', 'a', '', 'a', 'aa', 'aa' }, { { 2, 2 }, { 2, 2 } })
  move('up')
  validate_move_state({ 'aXa', 'aa', 'a', '', 'a', 'aa', 'aa' }, { { 1, 2 }, { 1, 2 } })
end

T['move_selection()']['has no side effects'] = function()
  set_lines({ 'abXcd' })
  set_cursor(1, 0)

  -- Shouldn't modify used `z` register
  type_keys('"zyl')
  eq(child.fn.getreg('z'), 'a')

  -- Shouldn't modify 'virtualedit'
  child.o.virtualedit = 'block,insert'

  set_cursor(1, 2)
  type_keys('v')
  move('right')
  validate_move_state1d('abcXd', { 4, 4 })

  -- Check
  eq(child.fn.getreg('z'), 'a')
  eq(child.o.virtualedit, 'block,insert')
end

T['move_selection()']['works with `virtualedit=all`'] = function()
  MiniTest.skip('Needs investigation')
  -- child.o.virtualedit = 'all'
  --
  -- set_lines({ 'abX', '' })
  -- set_cursor(1, 2)
  -- type_keys('v')
  --
  -- move('right')
  -- validate_move_state({ 'ab X', '' }, { { 1, 4 }, { 1, 4 } })
  -- move('down')
  -- validate_move_state({ 'ab ', '   X' }, { { 2, 4 }, { 2, 4 } })
end

T['move_selection()']['undos all movements at once'] = function()
  MiniTest.skip('Needs investigation')
  -- set_lines({ 'aXbc', 'defg' })
  -- set_cursor(1, 1)
  -- type_keys('v')
  -- validate_move_state({ 'aXbc', 'defg' }, { { 1, 2 }, { 1, 2 } })
  --
  -- move('down')
  -- move('right')
  -- move('right')
  -- move('up')
  -- move('left')
  -- validate_move_state({ 'abXc', 'defg' }, { { 1, 3 }, { 1, 3 } })
end

T['move_selection()']['does not create unnecessary jumps'] = function()
  set_lines({ '1Xa', '2b', '3c', '4d' })
  set_cursor(1, 1)
  type_keys('m`')
  type_keys('v')

  move('down')
  move('down')
  move('down')
  validate_move_state({ '1a', '2b', '3c', '4Xd' }, { { 4, 2 }, { 4, 2 } })

  -- In jump list there should be only single entry
  eq(#child.fn.getjumplist()[1], 1)
end

local validate_put = {
  put = function(args, reference_output)
    local capture = child.cmd_capture(('lua MiniMisc.put(%s)'):format(args))
    eq(capture, table.concat(reference_output, '\n'))
  end,

  put_text = function(args, reference_output)
    set_lines({})
    child.lua(('MiniMisc.put_text(%s)'):format(args))

    -- Insert text under current line
    table.insert(reference_output, 1, '')
    eq(get_lines(), reference_output)
  end,
}

T['put()/put_text()'] = new_set({
  parametrize = { { 'put' }, { 'put_text' } },
})

T['put()/put_text()']['works'] = function(put_name)
  local validate = validate_put[put_name]

  validate('{ a = 1, b = true }', { '{', '  a = 1,', '  b = true', '}' })
end

T['put()/put_text()']['allows several arguments'] = function(put_name)
  local validate = validate_put[put_name]

  child.lua('_G.a = 1; _G.b = true')
  validate('_G.a, _G.b', { '1', 'true' })
end

T['put()/put_text()']['handles tuple function output'] = function(put_name)
  local validate = validate_put[put_name]

  child.lua('_G.f = function() return 1, true end')
  validate('_G.f()', { '1', 'true' })
end

T['put()/put_text()']['prints `nil` values'] = function(put_name)
  local validate = validate_put[put_name]

  validate('nil', { 'nil' })
  validate('1, nil', { '1', 'nil' })
  validate('nil, 2', { 'nil', '2' })
  validate('1, nil, 2', { '1', 'nil', '2' })
end

local resize_initial_width, resize_win_id
T['resize_window()'] = new_set({
  hooks = {
    pre_case = function()
      -- Prepare two windows
      resize_initial_width = child.api.nvim_win_get_width(0)
      child.cmd('vsplit')
      resize_win_id = child.api.nvim_list_wins()[1]
    end,
  },
})

T['resize_window()']['works'] = function()
  local target_width = math.floor(0.25 * resize_initial_width)
  -- This sets gutter width to 4
  child.api.nvim_win_set_option(resize_win_id, 'signcolumn', 'yes:2')

  child.lua('MiniMisc.resize_window(...)', { resize_win_id, target_width })
  eq(child.api.nvim_win_get_width(resize_win_id), target_width + 4)
end

T['resize_window()']['correctly computes default `text_width` argument'] = function()
  child.api.nvim_win_set_option(0, 'signcolumn', 'yes:2')

  -- min(vim.o.columns, 79) < textwidth < colorcolumn
  child.o.columns = 160
  child.lua('MiniMisc.resize_window(0)')
  eq(child.api.nvim_win_get_width(0), 79 + 4)

  child.o.columns = 60
  child.lua('MiniMisc.resize_window(0)')
  -- Should set to maximum available width, which is less than `columns` by 1
  -- (window separator) and 'winminwidth'
  eq(child.api.nvim_win_get_width(0), 60 - 1 - child.o.winminwidth)

  child.bo.textwidth = 50
  child.lua('MiniMisc.resize_window(0)')
  eq(child.api.nvim_win_get_width(0), 50 + 4)

  child.wo.colorcolumn = '+2,-2'
  child.lua('MiniMisc.resize_window(0)')
  eq(child.api.nvim_win_get_width(0), 52 + 4)

  child.wo.colorcolumn = '-2,+2'
  child.lua('MiniMisc.resize_window(0)')
  eq(child.api.nvim_win_get_width(0), 48 + 4)

  child.wo.colorcolumn = '40,-2'
  child.lua('MiniMisc.resize_window(0)')
  eq(child.api.nvim_win_get_width(0), 40 + 4)
end

local dir_misc_path = make_abspath('tests/dir-misc/')
local git_repo_path = make_abspath('tests/dir-misc/mocked-git-repo/')
local git_path = make_abspath('tests/dir-misc/mocked-git-repo/.git')
local test_file_makefile = make_abspath('tests/dir-misc/aaa.lua')
local test_file_git = make_abspath('tests/dir-misc/mocked-git-repo/bbb.lua')

local skip_if_no_fs = function()
  if child.lua_get('type(vim.fs)') == 'nil' then MiniTest.skip('No `vim.fs`.') end
end

local init_mock_git = function(git_type)
  if git_type == 'file' then
    -- File '.git' is used inside submodules
    child.fn.writefile({ '' }, git_path)
  else
    child.fn.mkdir(git_path)
  end
end

local cleanup_mock_git = function() child.fn.delete(git_path, 'rf') end

T['setup_auto_root()'] = new_set({ hooks = { post_case = cleanup_mock_git } })

local setup_auto_root = function(...) child.lua('MiniMisc.setup_auto_root(...)', { ... }) end

T['setup_auto_root()']['works'] = function()
  skip_if_no_fs()
  eq(getcwd(), project_root)
  child.o.autochdir = true

  setup_auto_root()

  -- Resets 'autochdir'
  eq(child.o.autochdir, false)

  -- Creates autocommand
  eq(child.lua_get([[#vim.api.nvim_get_autocmds({ group = 'MiniMiscAutoRoot' })]]) > 0, true)

  -- Respects 'Makefile'
  child.cmd('edit ' .. test_file_makefile)
  eq(getcwd(), dir_misc_path)

  -- Respects '.git' directory and file
  for _, git_type in ipairs({ 'directory', 'file' }) do
    init_mock_git(git_type)
    child.cmd('edit ' .. test_file_git)
    eq(getcwd(), git_repo_path)
    cleanup_mock_git()
  end
end

T['setup_auto_root()']['checks if no `vim.fs` is present'] = function()
  -- Don't test if `vim.fs` is actually present
  if child.lua_get('type(vim.fs)') == 'table' then return end

  child.o.cmdheight = 10
  setup_auto_root()

  eq(
    child.cmd_capture('1messages'),
    '(mini.misc) `setup_auto_root()` requires `vim.fs` module (present in Neovim>=0.8).'
  )
  expect.error(function() child.cmd_capture('au MiniMiscAutoRoot') end, 'No such group or event')
end

T['setup_auto_root()']['validates input'] = function()
  skip_if_no_fs()

  expect.error(function() setup_auto_root('a') end, '`names`.*array')
  expect.error(function() setup_auto_root({ 1 }) end, '`names`.*string')
end

T['setup_auto_root()']['respects `names` argument'] = function()
  skip_if_no_fs()
  init_mock_git('directory')
  setup_auto_root({ 'Makefile' })

  -- Should not stop on git repo directory, but continue going up
  child.cmd('edit ' .. test_file_git)
  eq(getcwd(), dir_misc_path)
end

T['setup_auto_root()']['allows callable `names`'] = function()
  skip_if_no_fs()
  init_mock_git('directory')
  child.lua([[_G.find_aaa = function(x) return x == 'aaa.lua' end]])
  child.lua('MiniMisc.setup_auto_root(_G.find_aaa)')

  -- Should not stop on git repo directory, but continue going up
  child.cmd('edit ' .. test_file_git)
  eq(child.lua_get('MiniMisc.find_root(0, _G.find_aaa)'), dir_misc_path)
  eq(getcwd(), dir_misc_path)
end

T['setup_auto_root()']['works in buffers without path'] = function()
  skip_if_no_fs()

  setup_auto_root()

  local scratch_buf_id = child.api.nvim_create_buf(false, true)

  local cur_dir = getcwd()
  child.api.nvim_set_current_buf(scratch_buf_id)
  eq(getcwd(), cur_dir)
end

T['find_root()'] = new_set({ hooks = { post_case = cleanup_mock_git } })

local find_root = function(...) return child.lua_get('MiniMisc.find_root(...)', { ... }) end

T['find_root()']['works'] = function()
  skip_if_no_fs()

  -- Respects 'Makefile'
  child.cmd('edit ' .. test_file_makefile)
  eq(find_root(), dir_misc_path)
  child.cmd('%bwipeout')

  -- Respects '.git' directory and file
  for _, git_type in ipairs({ 'directory', 'file' }) do
    init_mock_git(git_type)
    child.cmd('edit ' .. test_file_git)
    eq(find_root(), git_repo_path)
    child.cmd('%bwipeout')
    cleanup_mock_git()
  end
end

T['find_root()']['validates arguments'] = function()
  skip_if_no_fs()

  expect.error(function() find_root('a') end, '`buf_id`.*number')
  expect.error(function() find_root(0, 1) end, '`names`.*string')
  expect.error(function() find_root(0, '.git') end, '`names`.*array')
end

T['find_root()']['respects `buf_id` argument'] = function()
  skip_if_no_fs()
  init_mock_git('directory')

  child.cmd('edit ' .. test_file_makefile)
  local init_buf_id = child.api.nvim_get_current_buf()
  child.cmd('edit ' .. test_file_git)
  eq(child.api.nvim_get_current_buf() ~= init_buf_id, true)

  eq(find_root(init_buf_id), dir_misc_path)
end

T['find_root()']['respects `names` argument'] = function()
  skip_if_no_fs()
  init_mock_git('directory')

  -- Should not stop on git repo directory, but continue going up
  child.cmd('edit ' .. test_file_git)
  eq(find_root(0, { 'aaa.lua' }), dir_misc_path)
end

T['find_root()']['allows callable `names`'] = function()
  skip_if_no_fs()
  init_mock_git('directory')
  child.cmd('edit ' .. test_file_git)

  child.lua([[_G.find_aaa = function(x) return x == 'aaa.lua' end]])
  eq(child.lua_get('MiniMisc.find_root(0, _G.find_aaa)'), dir_misc_path)
end

T['find_root()']['works in buffers without path'] = function()
  skip_if_no_fs()

  local scratch_buf_id = child.api.nvim_create_buf(false, true)
  child.api.nvim_set_current_buf(scratch_buf_id)
  eq(find_root(), vim.NIL)
end

T['find_root()']['uses cache'] = function()
  skip_if_no_fs()

  child.cmd('edit ' .. test_file_git)
  -- Returns root based on 'Makefile' as there is no git root
  eq(find_root(), dir_misc_path)

  -- Later creation of git root should not affect output as it should be cached
  -- from first call
  init_mock_git('directory')
  eq(find_root(), dir_misc_path)
end

local stat_summary = function(...) return child.lua_get('MiniMisc.stat_summary({ ... })', { ... }) end

T['stat_summary()'] = new_set()

T['stat_summary()']['works'] = function()
  eq(stat_summary(10, 4, 3, 2, 1), { minimum = 1, mean = 4, median = 3, maximum = 10, n = 5, sd = math.sqrt(50 / 4) })
end

T['stat_summary()']['validates input'] = function()
  expect.error(stat_summary, 'array', 'a')
  expect.error(stat_summary, 'array', { a = 1 })
  expect.error(stat_summary, 'numbers', { 'a' })
end

T['stat_summary()']['works with one number'] =
  function() eq(stat_summary(10), { minimum = 10, mean = 10, median = 10, maximum = 10, n = 1, sd = 0 }) end

T['stat_summary()']['handles even/odd number of elements for `median`'] = function()
  eq(stat_summary(1, 2).median, 1.5)
  eq(stat_summary(3, 1, 2).median, 2)
end

T['tbl_head()/tbl_tail()'] = new_set({
  parametrize = { { 'tbl_head' }, { 'tbl_tail' } },
})

T['tbl_head()/tbl_tail()']['works'] = function(fun_name)
  local example_table = { a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7 }

  local validate = function(n)
    local output = child.lua_get(('MiniMisc.%s(...)'):format(fun_name), { example_table, n })
    local reference = math.min(vim.tbl_count(example_table), n or 5)
    eq(vim.tbl_count(output), reference)
  end

  -- The exact values vary greatly and so seem to be untestable
  validate(nil)
  validate(3)
  validate(0)
end

local comments_option
T['use_nested_comments()'] = new_set({
  hooks = {
    pre_case = function()
      child.api.nvim_set_current_buf(child.api.nvim_create_buf(true, false))
      comments_option = child.bo.comments
    end,
  },
})

T['use_nested_comments()']['works'] = function()
  child.api.nvim_buf_set_option(0, 'commentstring', '# %s')
  child.lua('MiniMisc.use_nested_comments()')
  eq(child.api.nvim_buf_get_option(0, 'comments'), 'n:#,' .. comments_option)
end

T['use_nested_comments()']["ignores 'commentstring' with two parts"] = function()
  child.api.nvim_buf_set_option(0, 'commentstring', '/*%s*/')
  child.lua('MiniMisc.use_nested_comments()')
  eq(child.api.nvim_buf_get_option(0, 'comments'), comments_option)
end

T['use_nested_comments()']['respects `buf_id` argument'] = function()
  local new_buf_id = child.api.nvim_create_buf(true, false)
  child.api.nvim_buf_set_option(new_buf_id, 'commentstring', '# %s')

  child.lua('MiniMisc.use_nested_comments(...)', { new_buf_id })

  eq(child.api.nvim_buf_get_option(0, 'comments'), comments_option)
  eq(child.api.nvim_buf_get_option(new_buf_id, 'comments'), 'n:#,' .. comments_option)
end

T['zoom()'] = new_set()

local get_floating_windows = function()
  return vim.tbl_filter(
    function(x) return child.api.nvim_win_get_config(x).relative ~= '' end,
    child.api.nvim_list_wins()
  )
end

T['zoom()']['works'] = function()
  child.set_size(5, 20)
  set_lines({ 'aaa', 'bbb' })
  child.o.statusline = 'Statusline should not be visible in floating window'

  local buf_id = child.api.nvim_get_current_buf()
  child.lua('MiniMisc.zoom()')
  local floating_wins = get_floating_windows()

  eq(#floating_wins, 1)
  local win_id = floating_wins[1]
  eq(child.api.nvim_win_get_buf(win_id), buf_id)
  local config = child.api.nvim_win_get_config(win_id)
  eq({ config.height, config.width }, { 1000, 1000 })

  -- No statusline should be present
  child.expect_screenshot()
end

T['zoom()']['respects `buf_id` argument'] = function()
  local buf_id = child.api.nvim_create_buf(true, false)
  child.lua('MiniMisc.zoom(...)', { buf_id })
  local floating_wins = get_floating_windows()

  eq(#floating_wins, 1)
  eq(child.api.nvim_win_get_buf(floating_wins[1]), buf_id)
end

T['zoom()']['respects `config` argument'] = function()
  child.set_size(5, 30)

  local custom_config = { width = 20 }
  child.lua('MiniMisc.zoom(...)', { 0, custom_config })
  local floating_wins = get_floating_windows()

  eq(#floating_wins, 1)
  local config = child.api.nvim_win_get_config(floating_wins[1])
  eq({ config.height, config.width }, { 1000, 20 })

  child.expect_screenshot()
end

return T
