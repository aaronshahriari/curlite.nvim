local size = require("curlite.size")

local M = {}

function M.fraction_resolves_against_the_editor(t)
  t.eq(size.resolve("width", 0.5, 200), 100)
  t.eq(size.resolve("width", 0.25, 200), 50)
  t.eq(size.resolve("height", 0.5, 40), 20)
end

function M.absolute_values_pass_through(t)
  t.eq(size.resolve("width", 88, 400), 88)
  t.eq(size.resolve("height", 20, 200), 20)
end

function M.disabled_and_invalid_values_defer_to_vim(t)
  t.eq(size.resolve("width", 0, 200), nil)
  t.eq(size.resolve("width", -1, 200), nil)
  t.eq(size.resolve("width", nil, 200), nil)
  t.eq(size.resolve("width", 0 / 0, 200), nil, "NaN is not a size")
end

function M.a_size_is_clamped_to_leave_the_other_window_usable(t)
  -- The bug: an absolute size larger than the screen is honoured by Vim by
  -- squeezing the other window to 'winwidth', which reads as a layout bug.
  local resolved = size.resolve("width", 500, 200)
  t.truthy(resolved < 200, "a size larger than the screen is clamped")
  t.truthy(resolved > 0)
  t.eq(size.resolve("width", 0.99, 200), resolved, "so is a fraction near 1")
end

function M.round_trips_through_a_fraction(t)
  local total = size.total("width")
  local fraction = size.as_fraction("width", math.floor(total / 2))
  t.truthy(math.abs(fraction - 0.5) < 0.01, "half the screen stores as ~0.5")
end

return M
