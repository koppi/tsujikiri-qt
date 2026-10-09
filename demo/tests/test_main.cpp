extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <QApplication>

#include <iostream>
#include <string>

// Registers every bound Qt module in the `qt6` Lua namespace (generated)
void register_qt6(lua_State* L);

// Runs each Lua test script given on the command line in a fresh Lua state that has the
// Qt6 bindings registered. Exits non-zero if any script raises an error (the test library
// raises one when a test case fails). The widgets are rendered to memory, so the tests
// need neither a display nor a window system.
int main(int argc, char** argv)
{
    qputenv("QT_QPA_PLATFORM", "offscreen");
    qputenv("QT_LOGGING_RULES", "qt.qpa.*=false");

    QApplication application(argc, argv);

    if (argc < 2)
    {
        std::cerr << "usage: " << argv[0] << " <test.lua>..." << std::endl;
        return 2;
    }

    int failed = 0;
    for (int i = 1; i < argc; ++i)
    {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        register_qt6(L);

        // Let the tests `require` the test library and the generated API manifest
        lua_getglobal(L, "package");
        lua_pushstring(L, (std::string(QT6_TEST_DIR) + "/?.lua;" + QT6_TEST_GENERATED_DIR + "/?.lua;").c_str());
        lua_getfield(L, -2, "path");
        lua_concat(L, 2);
        lua_setfield(L, -2, "path");
        lua_pop(L, 1);

        if (luaL_dofile(L, argv[i]) != LUA_OK)
        {
            std::cerr << "Error: " << lua_tostring(L, -1) << std::endl;
            lua_pop(L, 1);
            ++failed;
        }

        lua_close(L);
    }

    return failed == 0 ? 0 : 1;
}
