-- Minimal test harness. Run with:  nvim -l tests/harness.lua [pattern]
-- Each tests/*_spec.lua returns a table of { ["name"] = function(t) ... end }.

vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local pass, fail = 0, 0
local failures = {}

local t = {}

function t.eq(got, want, msg)
  if not vim.deep_equal(got, want) then
    error(
      ("%s\n  expected: %s\n  got:      %s"):format(
        msg or "values differ",
        vim.inspect(want),
        vim.inspect(got)
      ),
      2
    )
  end
end

function t.truthy(v, msg)
  if not v then
    error(msg or "expected truthy, got " .. vim.inspect(v), 2)
  end
end

function t.falsy(v, msg)
  if v then
    error(msg or "expected falsy, got " .. vim.inspect(v), 2)
  end
end

function t.match(got, pattern, msg)
  if type(got) ~= "string" or not got:match(pattern) then
    error(
      ("%s\n  pattern: %s\n  got:     %s"):format(msg or "no match", pattern, vim.inspect(got)),
      2
    )
  end
end

local filter = arg and arg[1]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local specs = vim.fn.glob(root .. "/*_spec.lua", false, true)
table.sort(specs)

for _, spec in ipairs(specs) do
  local suite = dofile(spec)
  local names = vim.tbl_keys(suite)
  table.sort(names)
  local label = vim.fn.fnamemodify(spec, ":t:r")
  for _, name in ipairs(names) do
    local full = label .. " :: " .. name
    if not filter or full:lower():find(filter:lower(), 1, true) then
      local ok, err = pcall(suite[name], t)
      if ok then
        pass = pass + 1
      else
        fail = fail + 1
        table.insert(failures, { name = full, err = err })
      end
    end
  end
end

for _, f in ipairs(failures) do
  io.write("\n\27[31mFAIL\27[0m  ", f.name, "\n      ", tostring(f.err):gsub("\n", "\n      "), "\n")
end

io.write(("\n%d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
