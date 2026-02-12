-- Phase 2 MUX API test
-- This script tests all MUX API functions

local hx = require("hexe")

print("Testing MUX API functions...")

-- Test hexe.mux.config
print("\n✓ Testing hexe.mux.config.set()")
hx.mux.config.set("confirm_on_exit", true)
hx.mux.config.set("winpulse_enabled", true)
hx.mux.config.set("winpulse_duration_ms", 500)
hx.mux.config.set("selection_color", 238)

print("✓ Testing hexe.mux.config.setup()")
hx.mux.config.setup({
  confirm_on_detach = true,
  confirm_on_close = true,
  winpulse_brighten_factor = 2.5,
})

-- Test hexe.mux.keymap
print("\n✓ Testing hexe.mux.keymap.set()")
hx.mux.keymap.set(
  {hx.key.ctrl, hx.key.alt, hx.key.q},
  "mux.quit"
)

hx.mux.keymap.set(
  {hx.key.ctrl, hx.key.alt, hx.key.t},
  "tab.new"
)

hx.mux.keymap.set(
  {hx.key.ctrl, hx.key.alt, hx.key.up},
  {type = "focus.move", dir = "up"}
)

-- Test hexe.mux.float
print("\n✓ Testing hexe.mux.float.set_defaults()")
hx.mux.float.set_defaults({
  size = {width = 80, height = 70},
  padding = {x = 1, y = 0},
  color = {active = 1, passive = 237},
})

print("✓ Testing hexe.mux.float.define()")
hx.mux.float.define("1", {
  command = "htop",
  title = "System Monitor",
})

hx.mux.float.define("2", {
  command = "lazygit",
  title = "Git",
})

-- Test hexe.mux.tabs
print("\n✓ Testing hexe.mux.tabs.set_status()")
hx.mux.tabs.set_status(true)

print("✓ Testing hexe.mux.tabs.add_segment()")
hx.mux.tabs.add_segment("left", {
  name = "time",
})

hx.mux.tabs.add_segment("right", {
  name = "session",
})

-- Test hexe.mux.splits
print("\n✓ Testing hexe.mux.splits.setup()")
hx.mux.splits.setup({
  color = {active = 1, passive = 237},
})

print("\n" .. string.rep("=", 50))
print("Phase 2 MUX API test: PASSED")
print("All MUX API functions are callable!")
print(string.rep("=", 50))

return {
  success = true,
  apis_tested = {
    "hexe.mux.config.set",
    "hexe.mux.config.setup",
    "hexe.mux.keymap.set",
    "hexe.mux.float.set_defaults",
    "hexe.mux.float.define",
    "hexe.mux.tabs.set_status",
    "hexe.mux.tabs.add_segment",
    "hexe.mux.splits.setup",
  },
}
