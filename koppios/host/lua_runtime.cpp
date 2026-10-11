// What Lua needs from the platform on koppi/os, beyond what lib/ and apps/lua provide.
//
// Lua is built from apps/lua/src (the port's vendored 5.4.8) against the same C library the Qt
// applications use, with the host's glibc headers. That library has no FILE streams that glibc's
// <stdio.h> macros could work on, no strtod and an snprintf that is only good for diagnostics, so
// file loading, number parsing and number formatting are done here, on top of what Qt brings.
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <QtCore/QByteArray>
#include <QtCore/QFile>
#include <QtCore/QString>

#include <double-conversion/double-conversion.h>

#include "lua_koppios.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

extern "C" unsigned _write(const void* buffer, unsigned length);

void qt_koppios_gfx_close();

// ------------------------------------------------------------------------------------------
// Output
// ------------------------------------------------------------------------------------------

extern "C" void koppios_lua_write(const char* text, size_t length)
{
    _write(text, static_cast<unsigned>(length));
}

extern "C" void koppios_lua_errf(const char* format, const char* argument)
{
    char line[512];
    snprintf_(line, sizeof(line), format, argument);
    _write(line, static_cast<unsigned>(strlen(line)));
}

// ------------------------------------------------------------------------------------------
// strtod: Qt's double-conversion, which is exact (a hand written one is a unit in the last place off
// somewhere). Lua only gets here with a decimal number: it parses hexadecimal ones itself and refuses
// "inf" and "nan" before it asks.
// ------------------------------------------------------------------------------------------

extern "C" double koppios_strtod(const char* text, char** end) __asm__("strtod");

extern "C" double koppios_strtod(const char* text, char** end)
{
    using double_conversion::StringToDoubleConverter;
    static const StringToDoubleConverter converter(
        StringToDoubleConverter::ALLOW_LEADING_SPACES | StringToDoubleConverter::ALLOW_TRAILING_JUNK, 0.0, 0.0, nullptr, nullptr);

    int processed = 0;
    const double value = converter.StringToDouble(text, static_cast<int>(strlen(text)), &processed);
    if (end)
        *end = const_cast<char*>(text + processed);

    return value;
}

// ------------------------------------------------------------------------------------------
// Loading files
// ------------------------------------------------------------------------------------------

// lauxlib.c is compiled with luaL_loadfilex renamed, this is the one Lua calls: the file is read
// through Qt's file engine (the kernel's VFS) in one go and handed to luaL_loadbufferx.
extern "C" int luaL_loadfilex(lua_State* L, const char* filename, const char* mode)
{
    if (!filename)
        return luaL_error(L, "cannot read from standard input");

    QFile file(QString::fromUtf8(filename));
    if (!file.open(QIODevice::ReadOnly))
        return lua_pushfstring(L, "cannot open %s", filename), LUA_ERRFILE;

    QByteArray data = file.readAll();
    file.close();

    // What lua.c's loader skips: a byte order mark and a first line that starts with '#'
    qsizetype start = 0;
    if (data.startsWith("\xEF\xBB\xBF"))
        start = 3;
    if (start < data.size() && data.at(start) == '#')
    {
        while (start < data.size() && data.at(start) != '\n')
            ++start;
    }

    const QByteArray name = QByteArray("@") + filename;
    return luaL_loadbufferx(L, data.constData() + start, static_cast<size_t>(data.size() - start), name.constData(), mode);
}

// ------------------------------------------------------------------------------------------
// The os library: the clocks, the environment and a way out. Nothing that touches files.
// ------------------------------------------------------------------------------------------

namespace {

int os_clock(lua_State* L)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    lua_pushnumber(L, static_cast<lua_Number>(now.tv_sec) + static_cast<lua_Number>(now.tv_nsec) / 1e9);
    return 1;
}

int os_time(lua_State* L)
{
    lua_pushinteger(L, static_cast<lua_Integer>(time(nullptr)));
    return 1;
}

int os_difftime(lua_State* L)
{
    lua_pushnumber(L, static_cast<lua_Number>(luaL_checkinteger(L, 1) - luaL_optinteger(L, 2, 0)));
    return 1;
}

int os_getenv(lua_State* L)
{
    const char* value = getenv(luaL_checkstring(L, 1));
    if (value)
        lua_pushstring(L, value);
    else
        lua_pushnil(L);
    return 1;
}

int os_exit(lua_State* L)
{
    const int status = lua_isboolean(L, 1) ? (lua_toboolean(L, 1) ? 0 : 1) : static_cast<int>(luaL_optinteger(L, 1, 0));
    qt_koppios_gfx_close();
    exit(status);
}

const luaL_Reg os_functions[] = {
    {"clock", os_clock}, {"time", os_time}, {"difftime", os_difftime}, {"getenv", os_getenv}, {"exit", os_exit}, {nullptr, nullptr},
};

int luaopen_os_koppios(lua_State* L)
{
    luaL_newlib(L, os_functions);
    return 1;
}

} // namespace

// ------------------------------------------------------------------------------------------
// The libraries: all of them but io and debug (there is no stdio to build io on)
// ------------------------------------------------------------------------------------------

extern "C" void luaL_openlibs(lua_State* L)
{
    static const luaL_Reg libraries[] = {
        {LUA_GNAME, luaopen_base},
        {LUA_LOADLIBNAME, luaopen_package},
        {LUA_COLIBNAME, luaopen_coroutine},
        {LUA_TABLIBNAME, luaopen_table},
        {LUA_STRLIBNAME, luaopen_string},
        {LUA_MATHLIBNAME, luaopen_math},
        {LUA_UTF8LIBNAME, luaopen_utf8},
        {LUA_OSLIBNAME, luaopen_os_koppios},
        {nullptr, nullptr},
    };

    for (const luaL_Reg* library = libraries; library->func; ++library)
    {
        luaL_requiref(L, library->name, library->func, 1);
        lua_pop(L, 1);
    }
}
