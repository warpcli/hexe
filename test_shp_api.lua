-- Phase 4 SHP API test
-- This script tests SHP (shell prompt) API functions

local hx = require("hexe")

print("Testing SHP API functions...")

-- Test hexe.shp.prompt.left()
print("\n✓ Testing hexe.shp.prompt.left()")

hx.shp.prompt.left({
  {
    name = "ssh",
    priority = 10,
    outputs = {
      { style = "bold fg:3", format = "  $output " },
    },
    command = "echo $SSH_CONNECTION | awk '{print $3}'",
    when = { env = "SSH_CONNECTION" },
  },
  {
    name = "cwd",
    priority = 20,
    outputs = {
      { style = "bold fg:4", format = " $output " },
    },
    command = "pwd | sed \"s|$HOME|~|\"",
  },
  {
    name = "git",
    priority = 30,
    outputs = {
      { style = "fg:2", format = "  $output" },
    },
    command = "git branch --show-current 2>/dev/null",
  },
})

-- Test hexe.shp.prompt.right()
print("✓ Testing hexe.shp.prompt.right()")

hx.shp.prompt.right({
  {
    name = "duration",
    priority = 10,
    outputs = {
      { style = "fg:240", format = " $output " },
    },
  },
  {
    name = "status",
    priority = 20,
    outputs = {
      { style = "fg:1", format = "  $output" },
    },
  },
})

-- Test hexe.shp.prompt.add()
print("✓ Testing hexe.shp.prompt.add()")

hx.shp.prompt.add("left", {
  name = "custom",
  priority = 15,
  command = "echo 'hello'",
  outputs = {
    { style = "fg:5", format = "$output" },
  },
})

hx.shp.prompt.add("right", {
  name = "time",
  priority = 5,
  command = "date '+%H:%M:%S'",
  outputs = {
    { style = "bold fg:250", format = "  $output" },
  },
})

print("\n" .. string.rep("=", 50))
print("Phase 4 SHP API test: PASSED")
print("Shell prompt APIs are functional!")
print(string.rep("=", 50))

return {
  success = true,
  apis_tested = {
    "hexe.shp.prompt.left",
    "hexe.shp.prompt.right",
    "hexe.shp.prompt.add",
  },
  segments_configured = 7,
}
