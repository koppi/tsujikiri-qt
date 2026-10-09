# Qt6 + LuaBridge3 Demo

This demo shows how to use [tsujikiri](https://github.com/kunitoki/tsujikiri) to generate Lua bindings for the latest Qt 6 (6.12) for LuaBridge3: the classes of qtbase, driven from Lua scripts that build widgets, paint, query a database, parse XML and talk over sockets.

## Features

- **Automatic Binding Generation**: Uses upstream tsujikiri (installed from PyPI) and its `luabridge3` format to analyze the Qt headers and generate LuaBridge3 bindings for 786 classes and about 13,000 functions
- **Latest Qt**: CMake installs the prebuilt Qt 6.12.0 with [aqtinstall](https://github.com/miurahr/aqtinstall) into the build directory (or uses a Qt you point it at)
- **Natural Lua API**: `QString`, `QByteArray`, `QStringList`, `QVariant`, maps, flags and enums are plain Lua values; signals connect to Lua functions; widgets, painting, models, SQL, XML and sockets work as in C++
- **Headless**: widgets render to memory with Qt's `offscreen` platform when there is no display, which is what the demo and the tests use
- **CMake Integration**: Fetches LuaBridge3 and Lua with FetchContent, splits the generated code into translation units that compile in parallel
- **Lua Tests**: Every bound class and function is checked, and Qt is exercised from Lua in about 180 test cases

## Directory Structure

```
demo/
├── CMakeLists.txt             # CMake build configuration
├── main.cpp                   # Demo host: a QApplication that runs a Lua script
├── qt6_demo.lua               # The demo script (loaded at run time)
├── qt6.input.yml.in           # tsujikiri input config, configured once per Qt module
├── qt6_unbindable.txt         # Members the compiler rejects (found by tools/find_unbindable.py)
├── requirements.txt           # Pinned tsujikiri and aqtinstall
├── formats/                   # The qt6 output format: the luabridge3 template plus Qt specifics
├── support/                   # qt6_lua.h/.cpp: how Qt types cross into Lua, signals, ownership
├── tools/                     # qt6_gen.py (tsujikiri driver), qt6_pointers.py, find_unbindable.py
├── tests/                     # Lua tests for the bindings (see "Tests" below)
└── README.md                  # This file
```

The C++ files that bind Qt (`qt6_core_p0.cpp`, ...) are generated into `build/generated` during the build.

## Building and Running

### Prerequisites

- CMake 3.28 or later
- A C++17 compiler (GCC is tested), and plenty of memory: the bindings are template heavy, each of the 30 or so generated translation units needs up to about 3 GB to compile. `--parallel 3` is a good setting for a 16 GB machine; a cold build then takes about 25 minutes on 12 cores
- Python 3.10 or later with `venv` (for tsujikiri and aqtinstall)
- Access to download.qt.io (about 30 MB) and GitHub on the first configure

### Build and Run

```bash
just run
```

or manually:

```bash
cmake -S demo -B demo/build
cmake --build demo/build --parallel 3
demo/build/qt6_demo                 # runs qt6_demo.lua
demo/build/qt6_demo my_script.lua   # runs any script, the bindings are in the `qt6` table
```

CMake will automatically:
1. Create a Python virtual environment and install tsujikiri and aqtinstall from `requirements.txt`
2. Install Qt 6.12.0 (qtbase and ICU) into `build/qt`
3. Fetch LuaBridge3 and Lua
4. Run tsujikiri once per Qt module, then assemble the pointer conversions of all bound classes
5. Compile the bindings into `libqt6_lua_bindings.a` (about 500 MB, nothing is optimized) and link the demo and the tests. A rebuild only compiles the parts whose generated code changed

Options (`-D` on the first configure):

| Option | Default | Meaning |
| --- | --- | --- |
| `QT6_VERSION` | `6.12.0` | The Qt release to install and bind |
| `QT6_USE_SYSTEM` | `OFF` | Use the Qt that `find_package(Qt6)` finds (`CMAKE_PREFIX_PATH`, `Qt6_DIR`, the system) instead of installing one. 6.8 or later |
| `QT6_BUILD_TESTS` | `ON` | Build and register the Lua tests |

Installing Qt with aqtinstall is tested on Linux x86_64. For other platforms, install Qt yourself and use `QT6_USE_SYSTEM=ON`.

## How It Works

1. **Configuration**: `qt6.input.yml.in` tells tsujikiri how to bind one Qt module. CMake configures it into `build/generated/qt6_<module>.input.yml` with the include directories of the Qt it found. The umbrella header of the module (`<QtWidgets/QtWidgets>`) is what gets parsed.

2. **Generation**: for every module `tools/qt6_gen.py` runs tsujikiri with the `qt6` output format (`formats/`, the `luabridge3` format with a few overrides). The script registers the *qt6 transform stage*, which does the Qt specific part:
   - keeps the classes the module's headers declare, and drops internals, templates and what Lua has a better type for (`QString`, `QList`, ...)
   - drops the members that cannot be bound by type (out parameters, callbacks, templates) and truncates the trailing parameters Lua cannot pass (`bool *ok = nullptr`)
   - binds every method through an exact member pointer cast (`&QWidget::addAction` is ambiguous as soon as there is a template overload) or a lambda (`f() const &`)
   - gives `QObject`s a holder that deletes them with their Lua value only while they have no parent, and objects Qt adopts (`QStandardItem`, `QGraphicsItem`, ...) a holder that never deletes
   - fully qualifies the type names (`QDir::Filters` is `QFlags<QDir::Filter>`), which tsujikiri otherwise prints as written in the class
   The output is cut at class boundaries into a few translation units per module so they compile in parallel.

3. **Pointers**: LuaBridge3 treats every `T*` alike. `qt6_pointers.h`, generated from the list of bound classes, specializes `Stack<T*>` for all of them, so that `nil` is a null pointer and a `QObject*` that is really a `QPushButton` arrives as one.

4. **Support**: `support/qt6_lua.h` and `qt6_lua.cpp` are the hand written part: strings, containers, variants, flags, implicit conversions, signals, the event filter, `find_child`, `cast`, `QApplication.create`.

5. **Integration**: the generated `register_qt6(lua_State*)` registers every module; `main.cpp` creates the `QApplication`, registers the bindings and runs the script.

## The Lua API

Everything lives in the `qt6` table. Names are converted from `camelCase` to `snake_case` (`setObjectName` is `set_object_name`); a method named like a Lua keyword gets an underscore (`QPainter:end_()`).

```lua
local qt = qt6
local date = qt.QDate(2026, 10, 9)
print(date:add_days(30):to_string("yyyy-MM-dd"))       --> 2026-11-08
print(qt.QColor("steelblue"):name())                   --> #4682b4
print(qt.QUrl("https://example.com/a?b=1"):host())     --> example.com
```

### Values

| Qt | Lua |
| --- | --- |
| `QString`, `QByteArray`, `QChar`, string views | string (UTF-8; `nil` is the empty string, a number its text) |
| `QStringList`, `QList<T>`, `QSet<T>` | sequence table |
| `QMap<K,V>`, `QHash<K,V>`, `QVariantMap` | table |
| `QVariant` | the closest Lua value: `nil`, boolean, integer, number, string, table, or a bound object (`QPoint`, `QColor`, ...) |
| enums and `QFlags` | integers: `qt.Qt.AlignLeft \| qt.Qt.AlignTop` |
| `QPoint`, `QColor`, `QDate`, ... | userdata with methods; `==`, `<`, `+`, `-`, `*` where Qt defines them |

Classes are in the table of the same name; the enums of a class are its fields, `qt.QEvent.KeyPress` or `qt.QEvent.Type.KeyPress`, and namespace level enums are in the namespace: `qt.Qt.LeftButton`. A nested class `QMetaObject::Connection` is `qt.QMetaObject_Connection`. Implicit conversions work where Qt has them: a `QColor` or the name of one as a `QBrush`, a `QPoint` as a `QPointF`, a string as a `QUrl` or a `QKeySequence`.

### Signals and slots

```lua
local button = qt.QPushButton("Click")
local connection = button:connect("clicked", function(checked) print("clicked", checked) end)
spin:connect("valueChanged(int)", function(value) ... end)     -- by signature, to pick an overload
connection:disconnect()
```

The function is called with the arguments of the signal; an error in it is printed as a warning and does not stop the signal. `qt6.connect(sender, signal, fn)` is the same as the method.

### Events

Virtual methods cannot be overridden from Lua. An event filter does the job for events:

```lua
local filter = qt.EventFilter(function(object, event)
    if event:type() == qt.QEvent.KeyPress and event:key() == qt.Qt.Key_Escape then
        return true     -- swallow it
    end
    return false
end)
window:install_event_filter(filter)
```

### Objects and ownership

- A `QObject` created from Lua is deleted with its Lua value as long as it has no parent; once it has one, the parent owns it. `delete_later()` works as in C++.
- Items that Qt adopts (`QStandardItem`, `QTreeWidgetItem`, `QGraphicsItem`, `QMimeData`, ...) are never deleted by Lua.
- Qt keeps raw pointers: keep a reference to what you give to a function that does not take it over (the model of a view).
- A pointer returned by Qt is the real class of the object (`window:find_child("name")` is a `QLineEdit`), `qt6.cast(object, "QAbstractButton")` asks for a base class. `object:find_child([name [, class]])` and `find_children` replace the templates.

### Application and testing

The demo and the tests run inside a `QApplication` created by the host. A script that is run by something else can call `qt.QApplication.create({"name"})`, which returns the application if there is one. `qt.QTest` has the functions to drive widgets: `mouse_click`, `key_clicks`, `key_click`, ... Under `offscreen`, `widget:grab()` renders a widget to a `QPixmap`.

## Customization

You can customize the binding generation by modifying:

- **qt6.input.yml.in**: class blacklist, what is a "leaked" class, injected code (the operators of the geometry classes)
- **qt6_unbindable.txt**: members that do not compile (see below)
- **tools/qt6_gen.py**: the type rules and the policies of the qt6 stage
- **support/qt6_lua.h**: how a type crosses into Lua
- **CMakeLists.txt**: the modules, and how many translation units each is split into (`QT6_PARTS_<Module>`)

`qt6_demo.lua` is loaded at run time, so changes to it do not need a rebuild.

### Upgrading Qt

Configure with the new `QT6_VERSION` (or a new `Qt6_DIR`) and build. New API that cannot be bound shows up as compile errors; list it and build again:

```bash
cmake --build demo/build -- -k > build.log 2>&1   # keep going: collect all errors
python3 demo/tools/find_unbindable.py build.log --list demo/qt6_unbindable.txt
```

`find_unbindable.py` maps every error back to the generated line (a method, a constructor, a class) and appends it to `qt6_unbindable.txt`. An error that stops a statement from parsing hides the ones after it, so repeat until the build is clean. Classes that are declared in headers but not exported from the library show up as undefined references at link time: add them to the class blacklist in `qt6.input.yml.in`.

## Tests

```bash
just test                                   # build, then run every test through CTest
QT6_TEST_VERBOSE=1 just test                # print one line per test case
QT6_TEST_FILTER=QDate demo/build/tests/qt6_test demo/tests/test_core.lua
                                            # run the matching test cases of a single script
```

The tests are Lua scripts in `demo/tests/`. `qt6_test` runs each one in a fresh Lua state with the generated bindings registered and a `QApplication` on the `offscreen` platform, and every `test_*.lua` file is one CTest test. `testlib.lua` is the small assertion library they share.

| File | What it covers |
| --- | --- |
| `test_api_coverage.lua` | **Every** bound class and function, and every class that can be built without arguments (see below) |
| `test_values.lua` | strings, byte arrays, lists, maps, variants, flags and enums crossing into Lua |
| `test_core.lua` | dates, URLs, regular expressions, JSON, files, objects, signals, timers, the event loop |
| `test_gui.lua` | geometry, colors, fonts, images, painting, 3D math |
| `test_widgets.lua` | widgets, layouts, QTest input, event filters, models and views |
| `test_data_modules.lua` | SQL (sqlite), XML, networking over the loopback interface |
| `test_extras.lua` | what Qt takes over (graphics scenes and items, undo commands, mime data), settings, text documents, processes, threads |
| `test_binding_semantics.lua` | how the generated layer behaves: naming, overloads, defaults, equality, errors, ownership |

### API coverage

`tests/gen_api_manifest.py` reads the generated registration code and writes `qt6_api.lua`, a list of every registered class with its bases, constructor signatures and function names. It runs on every build, so the list follows Qt and the configuration and nothing is checked in that could go stale. `test_api_coverage.lua` then checks that

- the `qt6` table holds exactly those classes,
- every static function, static property and namespace function is reachable,
- a class without a bound constructor cannot be called, and
- every class with a constructor that takes no arguments is built and every own and inherited member function is reachable on the instance (this checks the `deriveClass` wiring across the modules).

Classes that need a graphics context, a bus or a platform integration are listed in the `SKIP` table of that file together with the reason. What each function *does* is covered by the other files; a function in the list but in no behavioural test is only known to exist.

## Limitations

- **Virtual methods cannot be overridden**, so there are no custom widgets, models or delegates written in Lua; use event filters, signals and the ready-made models. There is no `QThread` subclassing either, and a Lua state must not be used from more than one thread.
- **Templates are not bound**: the container and smart pointer classes (`QList`, `QSharedPointer`, ...), `QFuture`/`QtConcurrent`, the functor based `connect`. The converted containers are Lua tables; `QPolygon` and `QPolygonF` have `size`, `append` and `at`.
- **Out parameters and callbacks**: members with `int *`, `QString *`, function pointers, `std::function` ... are not bound; where the pointer is a trailing optional parameter (`bool *ok = nullptr`) the member is bound without it.
- **Public data members are not bound**; read them through the accessors.
- **Deprecated members** are not bound.
- **`QString`, `QByteArray`, `QVariant`, `QStringList` are no classes**: their member functions are not available (use the Lua string library).
- A hierarchy on the `qt6` table is flat: nested classes are `Outer_Inner`.
- Building takes long and the static library is big, because nothing is optimized and every method is a template instantiation.

## Demo Output

```
=== Qt 6.12.0 from Lua ===

1. Values
   - Friday, 9 October 2026, day 282 of the year
   - 100 days later: 2027-01-17
   [...]

3. Widgets
   - the spin box is at 7
   - label: Hello, Lua! (7) (the button was clicked 1 time)
   [...]
```
