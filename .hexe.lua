local hx = require("hexe")

return {
  mux = {
    input = {
      binds = {
        {
          mods = { hx.mod.alt },
          key = "r",
          action = { type = hx.action.keycast_toggle }
        },
      },
    },
  },
}
