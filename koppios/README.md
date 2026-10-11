# tsujikiri-qt on koppi/os

The Qt6 Lua bindings of this repository, as a program of [koppi/os](https://github.com/koppi/os): `qtlua` is Lua 5.4 with `qt6` registered, running in ring 3 on the real Qt 6.8 (QtCore, QtGui, QtWidgets) that the operating system vendors, painting into the kernel framebuffer and reading its keyboard and mouse.

```lua
local qt = qt6
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

The script is the one from the main README; the only difference to the desktop is that the application is created by the host (`qtlua`), as it is in `demo/main.cpp`.

## Building and running

You need a checkout of koppi/os next to this one (or `OS=/path` for `just`, `TSUJIKIRI_QT6=/path` for `make` in the os checkout; it finds this checkout next to it as `tsujikiri-qt` or `tsujikiri-qt6`), with its Qt built (`make -C apps/hello-qt-widgets -j4`, about 4 minutes the first time, shared with the other Qt programs), `g++` with 32-bit support (`g++-multilib`), `mtools` and `qemu-system-i386`. This repository needs Python 3.10+ and git; tsujikiri (a Python virtual environment) and LuaBridge3 (a clone of a pinned commit) are made in `koppios/build` on first use.

```bash
just koppios        # generate the bindings from the headers of that Qt, compile everything, link apps/qt-lua/qtlua
just koppios-run    # boot the OS in QEMU: type `qtlua` at the prompt (or `qtlua /rd/selftest.lua`)
just koppios-test   # boot headless and drive qtlua with the keyboard and the mouse (test/qt-lua-boot.sh)
```

or without `just`, from the os checkout:

```bash
make -C apps/qt-lua -j2     # a translation unit of bindings needs about a gigabyte of memory
make iso && make qemu-iso
```

`hda.sh` puts `qtlua`, `selftest.lua` and `qtlua.lua` (from `koppios/scripts`) on the RAM disk when the binary exists. Needs a framebuffer boot (the ISO), not `-kernel`.

At the shell prompt:

```
qtlua                       # the widgets demo, /rd/qtlua.lua. Tab, arrows, Space, mouse; Esc quits
qtlua /rd/selftest.lua      # checks the values, containers, enums, signals, painting and models
qtlua /rd/my.lua            # any script on the RAM disk (names are 8.3: the FAT driver is)
```

Output of `print` goes to the serial console and the kernel log.

## How it differs from the desktop build

The pipeline is the same, tsujikiri and the `qt6` stage of `demo/tools/qt6_gen.py`, with the same support layer (`demo/support`). What changes follows from "the Qt library is not the whole of Qt, and it is 32-bit":

| | desktop (`demo/`) | koppi/os (`koppios/`) |
| --- | --- | --- |
| Qt | prebuilt 6.12 from download.qt.io | the 6.8.4 source vendored in `third_party/qt6-gui` of koppi/os, built with its own feature set |
| Headers are parsed as | the compiler gets them, `-std=c++17` | `-m32 -std=gnu++20` with the OS's `QT_NO_*` macros and config headers, so what the OS switched off is not bound |
| Modules | 12 (Core, Gui, Widgets, Network, Xml, Sql, ...) | Core, Gui, Widgets: about 370 classes |
| What is bound | every class of the umbrella headers | the classes and members the vendored libraries *define* (`--symbols`, below) |
| Enum values | one lambda and one LuaBridge3 property each | one table per enum (`compact_enums`) |
| Lua | 5.4.8 from GitHub, `onelua.c` | 5.4.8 of `apps/lua` in koppi/os, built for the C library the Qt programs use |
| Size | 160 MB (`qt6_demo`, unstripped, with the Qt shared libraries on top) | 11.7 MB stripped: bindings 4.75 MB, Qt 5.6 MB (the same Qt as `hqtwid`, 6.3 MB), harfbuzz, freetype and pcre2 1.1 MB, Lua 0.13 MB. The RAM disk holds all four of `qtlua`, `hqtwid`, `hqtgui` and the Doom WAD |
| Exceptions, RTTI | on | off (no unwinder or typeinfo runtime on the OS): a Lua error unwinds with `longjmp`, so C++ objects live on the stack of a bound call are not destroyed |

### What keeps it small

The bindings are about 6000 registered members, a kilobyte of code each, so how they are compiled matters more than anything else: `-DNDEBUG` (LuaBridge3's `assert`s carry the condition, the file and the pretty name of a class template member as strings: 40% of a translation unit before), no unwind tables (nothing here unwinds; a sixth of the code), enum values as data tables (`compact_enums`) and the symbol filter below. Together they took `qtlua` from 14.6 to 11.7 MB without leaving a class out.

### Only what links

koppi/os vendors the part of Qt that its programs need, not all of it: `QUrl`, `QDir`, `QJsonDocument`, `QTimer`, `QPainter`, `QImage`, the item model classes and about 50 widgets are in; `QSettings`, `QProcess`, `QSqlDatabase`, dialogs, tool bars, tree and table views are not. The headers of many of those classes are on disk all the same, so the bindings are generated against what is *defined*:

`koppios/koppios.mk` lists the functions the vendored archives define (`nm`), `tools/generate.py` passes the list to the qt6 stage (`--symbols`), and the stage asks libclang for the mangled name of each declared member:

* a member that is declared but not defined (`QWidget::foo()` whose source file was not compiled in) is not bound;
* a class none of whose out-of-line members is defined is not in the library at all: it is not bound, nor is any member that has it in its signature (`QList<QFoo>`, `const QFoo &`);
* inline members, virtual members (called through the vtable) and nested enums need no symbol and stay.

So the bindings follow the library: vendor more of Qt in koppi/os and the next `make -C apps/qt-lua` binds it. `koppios_unbindable.txt` lists the rest (members the compiler rejects, as in the desktop build's `qt6_unbindable.txt`, which is read first).

### The host and the runtime

`koppios/host` is what `demo/main.cpp` and the platform are on the desktop:

* `main.cpp`: the `QApplication` on koppi/os's platform glue, a Lua state, the script (`argv[1]`, default `/rd/qtlua.lua`), `arg`.
* `lua_runtime.cpp`: what Lua needs that the OS's C library does not have. Files are read through Qt's file engine (the kernel's VFS) in one piece, `strtod` is Qt's double-conversion (exact), `print` writes to the console, `os` has the clocks, `getenv` and `exit`. No `io` and `debug` libraries: there is no stdio to build them on. Number formatting is `apps/lua/shim/printf.c`.
* `error_category.cpp`: the out-of-line members of `std::error_category`, which LuaBridge3's error codes derive from, as libstdc++ has them.
* `patches/luabridge3-no-iostreams.patch`: LuaBridge3 builds the text of `tostring(userdata)` with a `std::stringstream`, which would pull libstdc++'s iostreams into a program that has none. `snprintf` does the same.

Not in the OS C library, added to koppi/os `lib/` for this: `ldexp`, `frexp`, `strspn`, `strpbrk`, `time`.

## Scripts

`koppios/scripts/`:

| File | What it does |
| --- | --- |
| `qtlua.lua` | the widgets demo: two tabs, form widgets, a slider driving a progress bar and a dial. Logs every state change to the serial console as `qtlua: ...` |
| `selftest.lua` | runs 17 checks of the bindings (values, containers, enums, signals, painting, models, widgets) without opening a window and prints `selftest: N passed, M failed` |

## Limitations

Those of the desktop bindings (README of `demo/`: no virtual overrides, templates are not bound, no public data members), and those of the OS's Qt port (`third_party/qt6-gui/README.md` there): one top-level window plus popups, no menu bar, dialogs, tree or table views, 8-bit palette output, no image format plugins, no clipboard. A `QThread` subclass cannot be written in Lua, and a Lua state must not be used from more than one thread.
