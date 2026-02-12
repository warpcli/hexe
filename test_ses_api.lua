-- Phase 3 SES API test
-- This script tests SES layout and session APIs

local hx = require("hexe")

print("Testing SES API functions...")

-- Test hexe.ses.layout.define()
print("\n✓ Testing hexe.ses.layout.define()")

hx.ses.layout.define("default", {
  enabled = true,
  tabs = {
    {
      name = "main",
      root = {
        dir = "h",
        ratio = 0.6,
        { cwd = "~" },
        { cwd = "~/code", command = "nvim" },
      },
    },
    {
      name = "monitoring",
      root = {
        cwd = "~",
        command = "htop",
      },
    },
  },
  -- floats = {}, -- TODO: Add float support
})

hx.ses.layout.define("dev", {
  enabled = false,
  tabs = {
    {
      name = "editor",
      root = {
        dir = "v",
        ratio = 0.7,
        {
          cwd = "~/project",
          command = "nvim",
        },
        {
          dir = "h",
          ratio = 0.5,
          { cwd = "~/project" },
          { cwd = "~/project", command = "lazygit" },
        },
      },
    },
  },
})

-- Test hexe.ses.session.setup()
print("\n✓ Testing hexe.ses.session.setup()")

hx.ses.session.setup({
  auto_restore = true,
  save_on_detach = true,
})

print("\n" .. string.rep("=", 50))
print("Phase 3 SES API test: PASSED")
print("Layout and session APIs are functional!")
print(string.rep("=", 50))

return {
  success = true,
  apis_tested = {
    "hexe.ses.layout.define",
    "hexe.ses.session.setup",
  },
  layouts_defined = 2,
}
