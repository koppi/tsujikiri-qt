// Runs a Lua script with the Qt6 bindings registered:  qt6_demo [script.lua] [Qt options]
//
// The QApplication belongs to the host and outlives the Lua state, the widgets a script
// creates are deleted when the state is closed. Qt consumes its own options
// (-platform offscreen, ...), the first argument left is the script.
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <QApplication>

#include <iostream>

// Registers every bound Qt module in the `qt6` Lua namespace (generated)
void register_qt6(lua_State* L);

int main(int argc, char** argv)
{
    // Without a display the widgets are rendered to memory, so scripts run on a server too
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM") && qEnvironmentVariableIsEmpty("DISPLAY")
        && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY"))
        qputenv("QT_QPA_PLATFORM", "offscreen");

    QApplication application(argc, argv);

    const QStringList arguments = QCoreApplication::arguments();
    const QByteArray script = arguments.size() > 1 ? arguments.at(1).toLocal8Bit() : QByteArray(QT6_DEMO_SCRIPT);

    lua_State* L = luaL_newstate();
    luaL_openlibs(L);
    register_qt6(L);

    const int result = luaL_dofile(L, script.constData());
    if (result != LUA_OK)
    {
        std::cerr << "Error: " << lua_tostring(L, -1) << std::endl;
        lua_pop(L, 1);
    }

    lua_close(L);

    return result == LUA_OK ? 0 : 1;
}
