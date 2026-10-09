-- How the generated layer behaves: naming, constructors, overloads and defaults, references,
-- errors, ownership and the helpers of support/qt6_lua.cpp. A change in tsujikiri or in the
-- configuration that alters one of these shows up here.

local T = require("testlib")
local qt = qt6

-- Naming -----------------------------------------------------------------------------------------------

T.test("methods are snake_case", function()
    local object = qt.QObject()
    T.type_is(object.set_object_name, "function")
    T.type_is(object.object_name, "function")
    T.is_nil(object.setObjectName)
end)

T.test("static functions live on the class table", function()
    T.type_is(qt.QDate.current_date, "function")
    T.ok(qt.QDate.current_date():is_valid())
    T.type_is(qt.QDir.temp_path(), "string")
end)

T.test("a method named like a Lua keyword gets a trailing underscore", function()
    local image = qt.QImage(2, 2, qt.QImage.Format_RGB32)
    local painter = qt.QPainter(image)
    T.type_is(painter.end_, "function")
    T.is_nil(painter["end"])
    painter:end_()
end)

T.test("nested classes are named Outer_Inner", function()
    T.type_is(qt.QMetaObject_Connection, "table")
    T.type_is(qt.QDomDocument_ParseResult, "table")
end)

T.test("enums: values in the class, the enum as a table, namespace level enums in their namespace", function()
    T.eq(qt.QImage.Format_RGB32, qt.QImage.Format.Format_RGB32)
    T.eq(qt.Qt.LeftButton, qt.Qt.MouseButton.LeftButton)
    T.type_is(qt.QSql.Location, "table")
end)

-- Constructors -----------------------------------------------------------------------------------------

T.test("constructors are chosen by the arguments", function()
    T.xy(qt.QPoint(), 0, 0)
    T.xy(qt.QPoint(3, 4), 3, 4)
    T.eq(qt.QSize(5, 6):width(), 5)
    T.eq(qt.QColor("blue"):name(), "#0000ff")
    T.eq(qt.QColor(0, 0, 255):name(), "#0000ff")
    T.eq(qt.QColor(qt.Qt.blue):name(), "#0000ff")
end)

T.test("copy constructors copy", function()
    local a = qt.QPoint(1, 2)
    local b = qt.QPoint(a)
    b:set_x(10)
    T.eq(a:x(), 1)
    T.eq(b:x(), 10)
end)

T.test("assigning a value class in Lua shares the userdata", function()
    local a = qt.QPoint(1, 2)
    local b = a
    b:set_x(10)
    T.eq(a:x(), 10)
end)

T.test("the wrong arguments are an error", function()
    T.throws(function() return qt.QPoint("a", {}) end)
    T.throws(function() return qt.QPoint(1, 2, 3, 4, 5) end)
end)

T.test("abstract classes cannot be created", function()
    T.throws(function() return qt.QAbstractItemModel() end)
    T.throws(function() return qt.QIODevice() end)
end)

T.test("classes without a bound constructor cannot be called", function()
    T.throws(function() return qt.QCoreApplication() end)
end)

-- Overloads and default arguments ----------------------------------------------------------------------

T.test("trailing arguments with defaults may be left out", function()
    local image = qt.QImage(10, 10, qt.QImage.Format_ARGB32)
    -- QImage::save(fileName, format = nullptr, quality = -1)
    local directory = qt.QTemporaryDir()
    T.ok(image:save(directory:path() .. "/a.png"))
    T.ok(image:save(directory:path() .. "/b.png", "PNG"))
    T.ok(image:save(directory:path() .. "/c.png", "PNG", 50))
end)

T.test("overloads: same name, different parameters", function()
    local rect = qt.QRect(0, 0, 10, 10)
    T.rect(rect:translated(5, 5), 5, 5, 10, 10)
    T.rect(rect:translated(qt.QPoint(2, 3)), 2, 3, 10, 10)
    T.ok(rect:contains(5, 5))
    T.ok(rect:contains(qt.QPoint(5, 5)))
end)

T.test("overloads on QString against numbers", function()
    local date = qt.QDate(2020, 5, 17)
    T.eq(date:to_string("yyyy"), "2020")
    T.eq(date:to_string(qt.Qt.ISODate), "2020-05-17")
end)

-- References and constness ----------------------------------------------------------------------------

T.test("a reference to a number is its value", function()
    local point = qt.QPoint(1, 2)
    T.eq(point:rx(), 1) -- QPoint::rx() returns int&
    T.eq(point:ry(), 2)
end)

T.test("values that Qt hands out are copies that compare by value", function()
    local model = qt.QStandardItemModel()
    model:append_row(qt.QStandardItem("row"))
    local first, second = model:index(0, 0), model:index(0, 0)
    T.ok(first == second)
    T.eq(first:row(), 0)
    T.eq(model:data(first), "row")
    T.ok(first ~= model:index(0, 0):parent())
end)

-- Pointers -----------------------------------------------------------------------------------------------

T.test("nil is a null pointer, in overloaded functions too", function()
    local window = qt.QWidget()
    local child = qt.QWidget(window)
    T.ok(child:parent_widget() == window)
    child:set_parent(nil) -- overloaded: set_parent(parent) and set_parent(parent, flags)
    T.is_nil(child:parent_widget())

    local label = qt.QLabel("x", nil) -- overloaded constructors
    T.is_nil(label:parent_widget())
    T.eq(label:text(), "x")
end)

T.test("a null pointer comes back as nil", function()
    local object = qt.QObject()
    T.is_nil(object:parent())
    T.is_nil(qt.QWidget():parent_widget())
    T.is_nil(qt.QApplication.focus_widget())
end)

T.test("a pointer to a base class arrives as the real class", function()
    local parent = qt.QWidget()
    local button = qt.QPushButton("flat", parent)
    button:set_flat(true)

    local base = parent:children()[1] -- QObject* in the signature
    T.ok(base:is_flat()) -- is_flat() only exists on QPushButton
    T.eq(base:text(), "flat")
end)

-- Equality -----------------------------------------------------------------------------------------------

T.test("value classes compare by value", function()
    T.ok(qt.QRect(1, 2, 3, 4) == qt.QRect(1, 2, 3, 4))
    T.ok(qt.QRect(1, 2, 3, 4) ~= qt.QRect(1, 2, 3, 5))
    T.ok(qt.QColor("red") == qt.QColor(255, 0, 0))
    T.ok(qt.QUrl("http://a.org/") == qt.QUrl("http://a.org/"))
end)

T.test("objects compare by identity, whatever userdata represents them", function()
    local parent = qt.QObject()
    local child = qt.QObject(parent)
    T.ok(parent:children()[1] == child)
    T.ok(parent:children()[1] ~= parent)
    T.ok(child:parent() == parent)
end)

-- Errors -----------------------------------------------------------------------------------------------

T.test("calling a method that does not exist", function()
    local object = qt.QObject()
    T.is_nil(object.no_such_method)
    T.throws(function() object:no_such_method() end)
end)

T.test("calling a method on the wrong kind of value", function()
    T.throws(function() qt.QObject.object_name(42) end)
    T.throws(function() qt.QObject.object_name(qt.QPoint()) end)
end)

T.test("an error in a bound call leaves the state usable", function()
    local object = qt.QObject()
    T.throws(function() object:set_object_name({}) end)
    object:set_object_name("still works")
    T.eq(object:object_name(), "still works")
end)

-- Ownership --------------------------------------------------------------------------------------------

T.test("a widget with a parent survives its Lua value and dies with the parent", function()
    local destroyed = {}
    local window = qt.QWidget()
    window:connect("destroyed", function() destroyed.window = true end)
    do
        local label = qt.QLabel("child", window)
        label:connect("destroyed", function() destroyed.label = true end)
    end
    collectgarbage()
    collectgarbage()
    T.ok(not destroyed.label)
    window = nil
    collectgarbage()
    collectgarbage()
    T.ok(destroyed.window)
    T.ok(destroyed.label)
end)

T.test("Qt adopts items it is given: the Lua value leaves them alone", function()
    local model = qt.QStandardItemModel()
    do
        local item = qt.QStandardItem("adopted")
        model:append_row(item)
    end
    collectgarbage()
    collectgarbage()
    T.eq(model:item(0, 0):text(), "adopted")
end)

T.test("objects created by Qt are not deleted by Lua", function()
    local parent = qt.QObject()
    local child = qt.QObject(parent)
    local again = parent:children()[1]
    again = nil
    collectgarbage()
    collectgarbage()
    T.eq(#parent:children(), 1)
    T.ok(child ~= nil)
end)

-- Support functions --------------------------------------------------------------------------------------

T.test("qt6.version matches the library", function()
    T.eq(qt.version(), qt.QLibraryInfo.version():to_string())
    T.ok(qt.QVersionNumber.from_string(qt.version()) >= qt.QVersionNumber(6, 8))
end)

T.test("QApplication.create returns the application of the host", function()
    T.ok(qt.QApplication.create() == qt.QCoreApplication.instance())
end)

T.test("qt6.cast", function()
    local button = qt.QPushButton("x")
    T.ok(qt.cast(button, "QAbstractButton") ~= nil)
    T.is_nil(qt.cast(button, "QLineEdit"))
    T.throws(function() qt.cast(42, "QObject") end)
end)

T.test("signals that carry no arguments are called without arguments", function()
    local timer = qt.QTimer()
    local count
    timer:connect("timeout", function(...) count = select("#", ...) end)
    timer:set_interval(1)
    timer:start()
    T.ok(T.wait_for(function() return count ~= nil end))
    timer:stop()
    T.eq(count, 0)
end)

-- Known limitations -------------------------------------------------------------------------------------

T.test("limitation: public data members are not bound", function()
    local point = qt.QPoint(1, 2)
    T.is_nil(point.xp)
    T.is_nil(qt.QMetaObject.d)
end)

T.test("limitation: virtual methods cannot be overridden from Lua", function()
    -- there is no subclassing; behaviour is added with signals and event filters instead
    T.throws(function() return qt.QWidget():paint_event(nil) end)
end)

T.test("limitation: templates are not bound, the converted containers are tables", function()
    T.is_nil(qt.QList)
    T.is_nil(qt.QString)
    T.is_nil(qt.QVariant)
end)

T.run()
