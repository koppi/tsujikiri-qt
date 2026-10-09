# tsujikiri-qt
Qt6 Lua bindings generated with [tsujikiri](https://github.com/kunitoki/tsujikiri) 辻斬り and [LuaBridge3](https://github.com/kunitoki/LuaBridge3).

The bindings cover the classes of qtbase (Core, Gui, Widgets, Network, Xml, Sql, Concurrent, Test, PrintSupport, DBus, OpenGL and OpenGLWidgets) of the latest Qt 6 release, currently 6.12. See [demo/README.md](demo/README.md).

```lua
local qt = qt6
qt.QApplication.create()

local window = qt.QWidget()
local layout = qt.QVBoxLayout(window)
local label = qt.QLabel("Hello from Lua")
local button = qt.QPushButton("Click")
layout:add_widget(label)
layout:add_widget(button)

button:connect("clicked", function() label:set_text("Clicked!") end)
window:show()
qt.QApplication.exec()
```

## Building and Running

With [just](https://github.com/casey/just) installed, from the repository root:

```bash
just build   # Install Qt 6.12, generate the bindings with tsujikiri and compile them
just run     # Compile and run the demo
```

Run `just --list` to see all available recipes. The build goes to `demo/build`. The first build downloads Qt (about 30 MB, from download.qt.io) and compiles about 800 classes of bindings, which takes a while and a few GB of memory; see [demo/README.md](demo/README.md#building-and-running).

## Testing

```bash
just test    # build, then run the Lua tests for the bindings
```

The tests check every bound class and function and exercise Qt from Lua (strings, containers, signals, widgets, painting, models, SQL, XML, sockets); see [demo/README.md](demo/README.md#tests).
