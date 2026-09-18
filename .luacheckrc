-- luacheck configuration (https://luacheck.readthedocs.io). `task lint` runs it.
std = "min"          -- Lua 5.1 core, the version VLC 3 embeds
max_line_length = 120

files["src/lua/intf/hushbreak.lua"] = {
    -- Injected by VLC: the API table and the --lua-config entry for this script.
    read_globals = { "vlc", "config" },
}
files["src/lua/extensions/hushbreak_calibrate.lua"] = {
    read_globals = { "vlc" },
    -- VLC looks these up by name in the extension's environment.
    globals = { "descriptor", "activate", "deactivate", "close" },
}
files["tests/run.lua"] = {
    globals = { "test", "assert_eq", "assert_near", "read_fixture" },
}
files["tests/*_test.lua"] = {
    read_globals = { "test", "assert_eq", "assert_near", "read_fixture" },
}
