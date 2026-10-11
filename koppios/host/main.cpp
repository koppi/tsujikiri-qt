// qtlua: runs a Lua script with the Qt6 bindings on koppi/os.
//
//     qtlua [script.lua]          (default: /rd/qtlua.lua)
//
// The same host as demo/main.cpp, for a ring-3 program: a QApplication on the platform glue of
// third_party/qt6-gui/koppios (the kernel framebuffer, the keyboard and the mouse), a Lua state with
// the generated bindings registered, and the script. The application belongs to the host and
// outlives the Lua state; the widgets a script creates are deleted when the state is closed.
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <QtGui/QFont>
#include <QtWidgets/QApplication>

extern "C" unsigned _write(const void* buffer, unsigned length);

// The platform glue (third_party/qt6-gui/koppios)
void qt_koppios_install_file_engine_handler();
void qt_koppios_gfx_close();

// Registers every bound Qt module in the `qt6` Lua namespace (generated)
void register_qt6(lua_State* L);

static void say(const char* text)
{
    unsigned length = 0;
    while (text[length])
        ++length;
    _write(text, length);
}

int main(int argc, char** argv)
{
    qt_koppios_install_file_engine_handler();

    // Qt wants an absolute argv[0] (there is no PATH search); the script is ours to take from the real one
    static char name[] = "/rd/qtlua";
    static char* qtArguments[] = {name, nullptr};
    int qtArgc = 1;
    QApplication application(qtArgc, qtArguments);

    QFont font;
    font.setPixelSize(16); // one cell of Unifont's 16-pixel grid
    application.setFont(font);

    const char* script = argc > 1 ? argv[1] : "/rd/qtlua.lua";

    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    register_qt6(L);

    // arg[0] is the script, arg[1...] what follows it
    lua_createtable(L, argc, 1);
    for (int i = 1; i < argc; ++i)
    {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");

    say("qtlua: running ");
    say(script);
    say("\n");

    const int result = luaL_dofile(L, script);
    if (result != LUA_OK)
    {
        say("qtlua: ");
        say(lua_tostring(L, -1));
        say("\n");
        lua_pop(L, 1);
    }

    lua_close(L);
    qt_koppios_gfx_close();

    say("qtlua: done\n");
    return result == LUA_OK ? 0 : 1;
}
