// Pulled into every Lua source file (-include) when Lua is built for koppi/os. Declares what the
// -D flags of koppios.mk route Lua's formatting and output to; see lua_runtime.cpp.
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The printf of apps/lua/shim: %g, %f and %e are what Lua formats numbers with, and lib/'s snprintf
// is only good enough for diagnostics
int snprintf_(char* buffer, size_t count, const char* format, ...);
int sprintf_(char* buffer, const char* format, ...);

// print() and the interpreter's own messages: straight to the kernel console and serial line
void koppios_lua_write(const char* text, size_t length);
void koppios_lua_errf(const char* format, const char* argument);

#ifdef __cplusplus
}
#endif
