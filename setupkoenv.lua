-- Set search path for `require()`.
local is_ios = os.getenv("KO_IOS_RESOURCE_PATH") ~= nil
    or os.getenv("KO_IOS_BUNDLE_PATH") ~= nil
    or os.getenv("KO_IOS_DOCUMENTS_PATH") ~= nil
local lua_module_path = "common/?.lua;frontend/?.lua;plugins/exporter.koplugin/?.lua;"
local native_module_path = "common/?.so;common/?.dll;/usr/lib/lua/?.so;"
if is_ios then
    lua_module_path = lua_module_path .. "?.lua;"
    native_module_path = "common/?.dylib;libs/?.dylib;" .. native_module_path
end
package.path = lua_module_path .. package.path
package.cpath = native_module_path .. package.cpath
-- Setup `ffi.load` override and 'loadlib' helper.
require("ffi/loadlib")
