-- Phase 1 infrastructure test
-- This script tests that all module structures are injected correctly

local hx = require("hexe")

-- Test basic hexe module
assert(hx ~= nil, "hexe module should exist")
assert(hx.version ~= nil, "hexe.version should exist")

-- Test MUX section
assert(hx.mux ~= nil, "hexe.mux should exist")
assert(hx.mux.config ~= nil, "hexe.mux.config should exist")
assert(hx.mux.keymap ~= nil, "hexe.mux.keymap should exist")
assert(hx.mux.float ~= nil, "hexe.mux.float should exist")
assert(hx.mux.tabs ~= nil, "hexe.mux.tabs should exist")
assert(hx.mux.splits ~= nil, "hexe.mux.splits should exist")

-- Test SES section
assert(hx.ses ~= nil, "hexe.ses should exist")
assert(hx.ses.layout ~= nil, "hexe.ses.layout should exist")
assert(hx.ses.session ~= nil, "hexe.ses.session should exist")

-- Test SHP section
assert(hx.shp ~= nil, "hexe.shp should exist")
assert(hx.shp.prompt ~= nil, "hexe.shp.prompt should exist")
assert(hx.shp.segment ~= nil, "hexe.shp.segment should exist")

-- Test POP section
assert(hx.pop ~= nil, "hexe.pop should exist")
assert(hx.pop.notify ~= nil, "hexe.pop.notify should exist")
assert(hx.pop.confirm ~= nil, "hexe.pop.confirm should exist")
assert(hx.pop.choose ~= nil, "hexe.pop.choose should exist")
assert(hx.pop.widgets ~= nil, "hexe.pop.widgets should exist")

-- Test cross-section APIs
assert(hx.autocmd ~= nil, "hexe.autocmd should exist")
assert(hx.api ~= nil, "hexe.api should exist")
assert(hx.plugin ~= nil, "hexe.plugin should exist")

-- Test legacy hx.key, hx.mod, hx.when, hx.action, hx.mode
assert(hx.key ~= nil, "hexe.key should exist")
assert(hx.mod ~= nil, "hexe.mod should exist")
assert(hx.when ~= nil, "hexe.when should exist")
assert(hx.action ~= nil, "hexe.action should exist")
assert(hx.mode ~= nil, "hexe.mode should exist")

print("✓ All Phase 1 module structures exist")
print("✓ hexe.mux.{config,keymap,float,tabs,splits}")
print("✓ hexe.ses.{layout,session}")
print("✓ hexe.shp.{prompt,segment}")
print("✓ hexe.pop.{notify,confirm,choose,widgets}")
print("✓ hexe.{autocmd,api,plugin}")
print("")
print("Phase 1 infrastructure test: PASSED")

return {
    mux = hx.mux,
    ses = hx.ses,
    shp = hx.shp,
    pop = hx.pop,
}
