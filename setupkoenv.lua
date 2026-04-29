-- Set search path for `require()`.
package.path =
    "?.lua;common/?.lua;frontend/?.lua;plugins/exporter.koplugin/?.lua;" ..
    package.path
package.cpath =
    "common/?.so;common/?.dylib;common/?.dll;libs/?.so;libs/?.dylib;/usr/lib/lua/?.so;" ..
    package.cpath
-- Setup `ffi.load` override and 'loadlib' helper.
require("ffi/loadlib")
