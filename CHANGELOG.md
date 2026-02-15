# Changelog

## [0.0.3] - 2026-02-15

### <!-- 0 -->⛰️  Features

- Enhance Lua API for extended configuration
- Implement 'when' condition parsing for keybindings
- Implement new config setup and keymap API
- Use ConfigBuilder for module config
- Wire popup/overlay APIs to Lua hexe.pop module
- Add notification/dialog/widget parsing and C API functions
- Wire prompt APIs to Lua hexe.shp.prompt module
- Add segment parsing helpers and prompt C API functions
- Wire SES C API functions to Lua module
- Implement hexe.ses.session.setup() C API
- Implement hexe.ses.layout.define() C API
- Add recursive layout parsing helpers for panes and splits
- Wire all MUX C API functions to Lua module
- Implement tabs.add_segment, tabs.set_status, splits.setup C APIs
- Implement hexe.mux.float.define() C API
- Implement hexe.mux.float.set_defaults() C API
- Implement hexe.mux.keymap.set() C API
- Add action parsing helpers for simple and parametric actions
- Add key parsing helpers for unified key format
- Implement hexe.mux.config.setup() C API
- Implement hexe.mux.config.set() C API
- Inject hexe.mux/ses/shp/pop/autocmd/api/plugin module structure
- Integrate ConfigBuilder into LuaRuntime
- Add api_bridge skeleton with builder registry helpers
- Add PopConfigBuilder with notification/dialog/widgets config
- Add ShpConfigBuilder with left/right segments
- Add SesConfigBuilder with layouts list
- Add MuxConfigBuilder with full field set
- Add ConfigBuilder skeleton with section builders
- Enable `config validate` and `ses export` commands
- Introduce config validation, SES stats, and resource limits
- Implement session recovery and robust reattach
- Optimize wide character rendering
- Render non-space characters in tmux cells
- Improve CSI-u handling and scrollback
- Introduce widgets module for interactive overlays
- Implement Winpulse animation for focused panes
- Introduce support for Pokemon sprites
- Pokemon sprites
- Remove blocking read for backlog replay
- Implement layout saving and loading
- Support floating panes within a session
- Enhance keybinds with modes and improve float handling
- Enhance float pane usability and input experience
- Refactor mux input handling and IPC
- Refactor keybinding timing and introduce robust tap/repeat logic
- Improve session management and reattach reliability
- Improve cursor handling and CWD resolution
- Enhance float navigation and CWD handling
- Improve time segment and mux focus navigation
- Enhance keybind configuration and behavior
- Implement configurable exit key for floating panes
- Improve keybind handling with tap/hold and deferral
- Refactor keybind handling for Kitty keyboard protocol
- Support default float attributes
- Add float sizing, positioning, and focus mode
- Add `ses kill` and `ses clear` commands
- Add `env` and `env_not` conditions
- Add pod_name segment
- Improve float handling and layout updates
- Allow local config files and new keybind actions
- Implement local .hexe.lua config merging
- Customize mouse selection color
- Implement session layouts and float definitions
- Enhance mouse click behavior and session management
- Update ghostty dependency and optimize pane swap
- Add pane swapping functionality to pane select mode
- Implement overlay system for UI feedback
- Add JSON output for `ses list` and `pod list`
- Refactor mouse events to forward raw SGR to applications
- Optimize mux loop dead pane tracking
- Reimplement state persistence and reattach logic
- Implement versioned handshakes
- Implement SES client heartbeat
- Refactor CLI and core for improved efficiency
- Improve robustness by adding error logging
- Extract string sanitization into separate module
- Implement a centralized logging system
- Centralize and refactor UUID and float utilities
- Implement Unix socket credential verification
- Refactor config and query for unified 'when' conditions
- Relocate spinner rendering to core animations
- Refactor shared components into core module
- Improve floating pane lifecycle management
- Non-blocking CTL channel and rewrite architecture docs
- Skip polling panes without file descriptors
- Improve pane lifecycle management
- Improve pane info request handling
- Refactor Pod and client communication
- Implement binary wire protocol for MUX-SES communication
- Implement new binary communication protocols
- Send and receive pod metadata from the pod
- Implement SHP to POD direct communication
- Improve detached session persistence and reattach
- Add pod cli commands for management
- Always refresh VT render state on output
- Refactor config loading and improve performance
- Add mouse-driven float pane management
- Add `randomdo` module for dynamic status text
- Add randomdo segment
- Add explicit `when` configuration for status modules
- Document conditional `when` for modules
- Add configurable "when" conditions for status modules
- Implement multi-click selection for mouse
- Trim mouse selection to exclude trailing whitespace
- Add mouse selection auto-scroll and improve copy
- Update mouse selection to use buffer coordinates
- Refactor animated status bar checks
- Implement mux-side mouse selection with copy
- Configure Ghostty scrollback size
- Refactor shell init scripts into separate modules
- Introduce multi-instance support and Lua config improvements
- Add programmatic focus movement and program-specific keybindings
- Move `info` command from `ses` to `mux`
- Refactor `com` subcommand into `ses` and `shp`
- Add Lua configuration for mux, pop, and shp
- Refactor key input handling for cleanliness and robustness
- Sanitize and translate kitty keyboard input
- Add sandboxing and resource isolation for panes
- Add support for resizing split panes
- Improve keybind arbitration logic
- Improve and unify focus navigation
- Implement advanced keybinding infrastructure
- Add initial support for Kitty Keyboard Protocol
- Refactor keybinding configuration
- Enhance float configuration and styling
- Improve `com list` output with tree view and colors
- Enhance shell integration with command info and exit intent
- Remove built-in floating window title rendering
- Add support for custom float pane titles
- BIGGGGGGGER FIX
- Improve mouse event handling to respect alt-screen
- Improve tab switching and mouse support
- SUPER FIXXXXXX
- Improve PTY child process reaping and client handling
- Introduce float attributes and new config structure
- Refactor mux into modular files
- Remove unnecessary stdout capture
- Add option to redirect float pane selection to a file
- Streamline and enhance float pane functionality
- Implement blocking float panes
- Enhance pane info with layout, size, and TTY
- Add base and active process info to `com info`
- Implement ad-hoc floating panes via CLI
- Add timeout for handshake during pod spawn
- Optimize pod protocol reader memory allocation
- Increase maximum frame length and add frame skipping
- Use spawn-safe CWD for pod panes
- Allow respawning remote panes
- Add logging capabilities to core components
- Rename project from Hexa to Hexe
- Add initial configuration files for Hexa
- Enable sending input to panes via CLI
- Improve ses daemon allocator handling and logging
- Enhance CWD tracking for pod panes
- README
- REINIT

### <!-- 1 -->🐛 Bug Fixes

- Parse mode as string not number in array format keybindings
- Support passthrough_only bindings without action in array format
- Migrate SesConfig to ConfigBuilder API, ensure all modules use defaults on error
- Migrate PopConfig to ConfigBuilder API, resolve IOT abort
- Prevent segfault by storing stable ConfigBuilder pointer
- Handle wide characters during rendering
- Update selectWord call for ghostty
- Update ghostty dependency hash

### <!-- 3 -->📚 Documentation

- Fix architecture diagrams with box-drawing characters
- Update float pane documentation and add build info

### <!-- 6 -->🧪 Testing

- Add Phase 5 POP API integration test
- Add Phase 4 SHP API integration test
- Add Phase 3 SES API integration test
- Add Phase 2 MUX API integration test
- Add Phase 1 infrastructure verification test

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Remove double pokemon sprites
- Remove double pokemon sprites
- Improve keycast and mux new behavior
- Update project version and dependencies
- VERSION RESET
- Update release workflow and dependencies
- Pass GITHUB_REF for release builds
- Update project version
- Bump version to 0.1.4
- Add manual workflow_dispatch trigger
- Fetch full history for release tags
- Bump version to 0.1.3
- Bump version to 0.1.2
- Bump version to 0.1.1
- Add GitHub Release workflow for binaries
- Remove Kitty Keyboard Protocol documentation

### <!-- 9 -->◀️ Revert

- Disable perf caches causing freeze

