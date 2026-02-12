-- Phase 5 POP API test
-- This script tests POP (popups & overlays) API functions

local hx = require("hexe")

print("Testing POP API functions...")

-- Test hexe.pop.notify.setup()
print("\n✓ Testing hexe.pop.notify.setup()")

hx.pop.notify.setup({
  carrier = {
    fg = 232,
    bg = 1,
    bold = true,
    padding_x = 1,
    padding_y = 0,
    offset = 1,
    alignment = "center",
    duration_ms = 3000,
  },
  pane = {
    fg = 0,
    bg = 3,
    bold = true,
    padding_x = 1,
    padding_y = 0,
    offset = 0,
    alignment = "center",
    duration_ms = 3000,
  },
})

-- Test hexe.pop.confirm.setup()
print("✓ Testing hexe.pop.confirm.setup()")

hx.pop.confirm.setup({
  carrier = {
    fg = 0,
    bg = 4,
    bold = true,
    padding_x = 2,
    padding_y = 1,
    yes_label = "Yes",
    no_label = "No",
  },
  pane = {
    fg = 0,
    bg = 4,
    bold = true,
    padding_x = 2,
    padding_y = 1,
    yes_label = "Y",
    no_label = "N",
  },
})

-- Test hexe.pop.choose.setup()
print("✓ Testing hexe.pop.choose.setup()")

hx.pop.choose.setup({
  carrier = {
    fg = 7,
    bg = 0,
    highlight_fg = 0,
    highlight_bg = 7,
    bold = false,
    padding_x = 1,
    padding_y = 0,
    visible_count = 10,
  },
  pane = {
    fg = 7,
    bg = 0,
    highlight_fg = 0,
    highlight_bg = 7,
    visible_count = 10,
  },
})

-- Test hexe.pop.widgets.pokemon()
print("✓ Testing hexe.pop.widgets.pokemon()")

hx.pop.widgets.pokemon({
  enabled = true,
  position = "topright",
  shiny_chance = 0.01,
})

-- Test hexe.pop.widgets.keycast()
print("✓ Testing hexe.pop.widgets.keycast()")

hx.pop.widgets.keycast({
  enabled = false,
  position = "bottomright",
  duration_ms = 3000,
  max_entries = 5,
  grouping_timeout_ms = 500,
})

-- Test hexe.pop.widgets.digits()
print("✓ Testing hexe.pop.widgets.digits()")

hx.pop.widgets.digits({
  enabled = false,
  position = "topright",
  size = "small",
})

print("\n" .. string.rep("=", 50))
print("Phase 5 POP API test: PASSED")
print("Popup and overlay APIs are functional!")
print(string.rep("=", 50))

return {
  success = true,
  apis_tested = {
    "hexe.pop.notify.setup",
    "hexe.pop.confirm.setup",
    "hexe.pop.choose.setup",
    "hexe.pop.widgets.pokemon",
    "hexe.pop.widgets.keycast",
    "hexe.pop.widgets.digits",
  },
  config_sections = 6,
}
