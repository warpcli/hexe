local hx = require("hexe")

return {
  mux = {
    input = {
      timing = { hold_ms = 400, double_tap_ms = 250 },
      binds = {
        { mods = { hx.mod.alt }, key = "q", context = { focus = "any" }, action = { type = hx.action.mux_quit } },
        { mods = { hx.mod.alt, hx.mod.shift }, key = "d", context = { focus = "any" }, action = { type = hx.action.mux_detach } },

        { mods = { hx.mod.alt }, key = "z", context = { focus = "any" }, action = { type = hx.action.pane_disown } },
        { mods = { hx.mod.alt }, key = "a", context = { focus = "any" }, action = { type = hx.action.pane_adopt } },

        { mods = { hx.mod.alt }, key = "h", context = { focus = "split" }, action = { type = hx.action.split_h } },
        { mods = { hx.mod.alt }, key = "v", context = { focus = "split" }, action = { type = hx.action.split_v } },

        { mods = { hx.mod.alt }, key = "t", context = { focus = "any" }, action = { type = hx.action.tab_new } },
        { mods = { hx.mod.alt }, key = ".", context = { focus = "any" }, action = { type = hx.action.tab_next } },
        { mods = { hx.mod.alt }, key = ",", context = { focus = "any" }, action = { type = hx.action.tab_prev } },
        { mods = { hx.mod.alt }, key = "x", context = { focus = "any" }, action = { type = hx.action.tab_close } },

        { mods = { hx.mod.alt }, key = "up", context = { focus = "any" }, action = { type = hx.action.focus_move, dir = "up" } },
        { mods = { hx.mod.alt }, key = "down", context = { focus = "any" }, action = { type = hx.action.focus_move, dir = "down" } },
        { mods = { hx.mod.alt }, key = "left", context = { focus = "any" }, action = { type = hx.action.focus_move, dir = "left" } },
        { mods = { hx.mod.alt }, key = "right", context = { focus = "any" }, action = { type = hx.action.focus_move, dir = "right" } },

        { mods = { hx.mod.alt, hx.mod.shift }, key = "k", context = { focus = "float" }, action = { type = hx.action.float_nudge, dir = "up" } },
        { mods = { hx.mod.alt, hx.mod.shift }, key = "j", context = { focus = "float" }, action = { type = hx.action.float_nudge, dir = "down" } },
        { mods = { hx.mod.alt, hx.mod.shift }, key = "h", context = { focus = "float" }, action = { type = hx.action.float_nudge, dir = "left" } },
        { mods = { hx.mod.alt, hx.mod.shift }, key = "l", context = { focus = "float" }, action = { type = hx.action.float_nudge, dir = "right" } },

        { mods = { hx.mod.alt }, key = "space", context = { focus = "any" }, action = { type = hx.action.float_toggle, float = "0" } },
      },
    },

    confirm_on_exit = true,
    confirm_on_detach = true,
    confirm_on_disown = true,
    confirm_on_close = true,

    floats = {
      {
        padding = { x = 2, y = 1 },
        style = {
          border = {
            color = { active = 1, passive = 237 },
          },
        },
      },
      {
        key = "1",
        attributes = { per_cwd = true, sticky = true },
      },
      {
        key = "2",
      },
      {
        key = "3",
        position = { x = 100, y = 0 },
        size = { width = 40, height = 50 },
        padding = { x = 0, y = 0 },
        attributes = { global = false },
      },
      {
        key = "4",
        attributes = { destroy = true },
      },
      {
        key = "f",
        command = "btop",
        title = "btop",
        attributes = { exclusive = true },
        style = {
          title = {
            position = "topright",
            outputs = {
              { style = "bg:0 fg:1", format = "[" },
              { style = "bg:237 fg:250", format = " $output " },
              { style = "bg:0 fg:1", format = "]" },
            },
          },
        },
      },
    },

    splits = {
      color = { active = 1, passive = 237 },
      separator_v = "│",
      separator_h = "─",
    },

    tabs = {
      status = {
        enabled = true,

        left = {
          {
            name = "time",
            priority = 10,
            outputs = {
              { style = "bg:237 fg:250", format = " " },
              { style = "bold bg:237 fg:250", format = "$output" },
              { style = "bg:237 fg:250", format = " " },
              { style = "fg:237 bg:1", format = "" },
            },
          },
          {
            name = "netspeed",
            priority = 30,
            outputs = {
              { style = "bg:1 fg:0", format = " $output " },
              { style = "fg:1", format = "" },
            },
          },
          {
            name = "uptime",
            priority = 100,
            outputs = {
              { style = "fg:7", format = " $output" },
            },
          },
        },

        center = {
          {
            name = "tabs",
            priority = 1,
            tab_title = "basename",
            active_style = "bg:1 fg:0",
            inactive_style = "bg:237 fg:250",
            separator = " | ",
            separator_style = "fg:7",
          },
        },

        right = {
          {
            name = "session",
            priority = 5,
            outputs = {
              { style = "fg:7", format = "| $output " },
              { style = "fg:1", format = "" },
            },
          },
          {
            name = "cpu",
            priority = 15,
            outputs = {
              { style = "bg:1 fg:0", format = " $output " },
              { style = "fg:1 bg:237", format = "" },
            },
          },
          {
            name = "mem",
            priority = 20,
            outputs = {
              { style = "bg:237 fg:250", format = " $output " },
            },
          },
          {
            name = "battery",
            priority = 40,
            outputs = {
              { style = "bg:237 fg:250", format = "$output " },
            },
          },
          {
            name = "jobs",
            priority = 200,
            outputs = {
              { style = "fg:7", format = " $output" },
            },
          },
        },
      },
    },
  },

  pop = {
    carrier = {
      notification = {
        fg = 232,
        bg = 1,
        bold = true,
        padding_x = 3,
        padding_y = 1,
        offset = 3,
        alignment = "center",
        duration_ms = 3000,
      },
      confirm = {
        fg = 232,
        bg = 1,
        bold = true,
        padding_x = 3,
        padding_y = 1,
      },
      choose = {
        fg = 232,
        bg = 1,
        highlight_fg = 1,
        highlight_bg = 232,
        visible_count = 10,
      },
    },
    pane = {
      notification = {
        fg = 232,
        bg = 1,
        bold = true,
        padding_x = 3,
        padding_y = 1,
        offset = 2,
        alignment = "center",
        duration_ms = 3000,
      },
      confirm = {
        fg = 232,
        bg = 1,
        bold = true,
        padding_x = 3,
        padding_y = 1,
      },
      choose = {
        fg = 232,
        bg = 1,
        highlight_fg = 1,
        highlight_bg = 232,
        visible_count = 10,
      },
    },
  },

  shp = {
    prompt = {
      left = {
        {
          name = "ssh",
          priority = 60,
          command = "echo //",
          when = "[[ -n $SSH_CONNECTION ]]",
          outputs = {
            { style = "bg:237 italic fg:15", format = " $output" },
          },
        },
        {
          name = "hostname",
          priority = 15,
          outputs = {
            { style = "bg:237 italic fg:15", format = "$output " },
          },
        },
        {
          name = "distro",
          priority = 10,
          command = "/env/dot/.func/shell/distrologo",
          when = "true",
          outputs = {
            { style = "bg:1 fg:0", format = " $output" },
          },
        },
        {
          name = "username",
          priority = 1,
          outputs = {
            { style = "bg:1 fg:0", format = "$output " },
          },
        },
        {
          name = "direnv",
          priority = 25,
          command = "echo ▓",
          when = "[[ -n $DIRENV_DIR ]]",
          outputs = {
            { style = "bg:1 fg:0", format = "$output" },
          },
        },
        {
          name = "sudo",
          priority = 6,
          outputs = {
            { style = "bold bg:240 fg:171", format = " ROOT " },
          },
        },
        {
          name = "tab",
          priority = 30,
          command = "echo $TAB | tr -d '/'",
          when = "[[ -n $TAB ]]",
          outputs = {
            { style = "fg:7", format = "|" },
            { style = "bg:6 italic fg:0", format = " t: $output " },
          },
        },
        {
          name = "tab2",
          priority = 35,
          command = "echo $(( $(tab -l 2> /dev/null | wc -l) - 1 ))",
          when = "[[ ! -n $TAB ]] && [[ $(( $(tab -l 2> /dev/null | wc -l) - 1 )) -gt 0 ]]",
          outputs = {
            { style = "fg:7", format = "|" },
            { style = "bg:237 italic fg:15", format = " $output " },
          },
        },
        {
          name = "status",
          priority = 3,
          outputs = {
            { style = "bg:0 fg:9", format = " $output " },
          },
        },
        {
          name = "container",
          priority = 50,
          command = "/env/dot/.func/shell/incontainer",
          when = "[[ $(systemd-detect-virt) != 'none' ]]",
          outputs = {
            { style = "bg:0 fg:0", format = " " },
            { style = "bg:5 fg:0", format = "$output" },
          },
        },
        {
          name = "separator",
          priority = 20,
          outputs = {
            { style = "fg:7", format = "|" },
          },
        },
      },

      right = {
        {
          name = "container2",
          priority = 55,
          command = "/env/dot/.func/shell/incontainer2",
          when = "[[ $(systemd-detect-virt) != 'none' ]]",
          outputs = {
            { style = "fg:7", format = "|" },
            { style = "bg:5 fg:0", format = " $output " },
            { style = "fg:7", format = "||" },
          },
        },
        {
          name = "separator",
          priority = 20,
          outputs = {
            { style = "fg:7", format = "|" },
          },
        },
        {
          name = "git_branch",
          priority = 4,
          outputs = {
            { style = "bg:1 fg:0", format = "  " },
            { style = "bg:1 fg:0", format = "$output " },
          },
        },
        {
          name = "git_status",
          priority = 5,
          outputs = {
            { style = "bg:1 fg:0", format = "$output " },
          },
        },
        {
          name = "directory",
          priority = 2,
          outputs = {
            { style = "bg:237 fg:15", format = "$output " },
          },
        },
      },
    },
  },
}
