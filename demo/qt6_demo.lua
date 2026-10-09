-- A tour of the Qt6 bindings. Runs without a display (the widgets are rendered to memory) and
-- without user input: events are produced by the script itself.
--
-- Qt classes live in the `qt6` table; methods are written in snake_case (setWindowTitle is
-- set_window_title), strings are Lua strings, lists and maps are tables, enums and flags are integers.

local qt = qt6

print("=== Qt " .. qt.version() .. " from Lua ===")
print()

-- 1. Values --------------------------------------------------------------------------------------
print("1. Values")

local date = qt.QDate(2026, 10, 9)
print("   - " .. date:to_string("dddd, d MMMM yyyy") .. ", day " .. date:day_of_year() .. " of the year")
print("   - 100 days later: " .. date:add_days(100):to_string("yyyy-MM-dd"))

local url = qt.QUrl("https://user@example.com:8443/docs/index.html?lang=lua#intro")
print(string.format("   - url: host=%s port=%d path=%s query=%s", url:host(), url:port(), url:path(), url:query()))

local color = qt.QColor("steelblue")
print(string.format("   - steelblue is rgb(%d, %d, %d), %s", color:red(), color:green(), color:blue(), color:name()))

local regex = qt.QRegularExpression("(\\w+)@(\\w+)\\.com")
local match = regex:match("write to lua@example.com today")
print("   - regular expression: user=" .. match:captured(1) .. " domain=" .. match:captured(2))

local json = qt.QJsonDocument.from_json('{"name": "Qt", "versions": [5, 6], "lts": true}')
local object = json:object()
print("   - json: " .. object:value("name"):to_string() .. " has " .. object:value("versions"):to_array():size() .. " versions")

-- 2. Objects, properties and signals ---------------------------------------------------------------
print()
print("2. Objects, properties and signals")

local object = qt.QObject()
object:set_object_name("demo-object")
object:set_property("answer", 42)
object:set_property("tags", { "a", "b", "c" })
print("   - " .. object:object_name() .. " answer=" .. object:property("answer") .. " tags=" .. table.concat(object:property("tags"), ","))

local loop = qt.QEventLoop()
local timer = qt.QTimer()
timer:set_interval(5)
local ticks = 0
timer:connect("timeout", function()
    ticks = ticks + 1
    if ticks == 5 then loop:quit() end
end)
timer:start()
loop:exec()
timer:stop()
print("   - a QTimer fired " .. ticks .. " times, driving a QEventLoop")

-- 3. Widgets ---------------------------------------------------------------------------------------
print()
print("3. Widgets")

local window = qt.QWidget()
window:set_window_title("Qt6 from Lua")

local layout = qt.QVBoxLayout(window)
local label = qt.QLabel("Press the button")
local edit = qt.QLineEdit()
edit:set_placeholder_text("your name")
local spin = qt.QSpinBox()
spin:set_range(0, 10)
local button = qt.QPushButton("Greet")
layout:add_widget(label)
layout:add_widget(edit)
layout:add_widget(spin)
layout:add_widget(button)

local greetings = 0
button:connect("clicked", function()
    greetings = greetings + 1
    label:set_text(string.format("Hello, %s! (%d)", edit:text(), spin:value()))
end)
spin:connect("valueChanged(int)", function(value)
    print("   - the spin box is at " .. value)
end)

window:show()
qt.QTest.key_clicks(edit, "Lua")
spin:set_value(7)
qt.QTest.mouse_click(button, qt.Qt.LeftButton)
print("   - label: " .. label:text() .. " (the button was clicked " .. greetings .. " time)")

-- What Qt returns as a QObject or a QWidget arrives as the real class: find_child gives a QPushButton
local found = window:find_child(nil, "QPushButton")
print("   - the layout holds " .. layout:count() .. " widgets, the button in it says '" .. found:text() .. "'")

-- 4. Painting --------------------------------------------------------------------------------------
print()
print("4. Painting")

local image = qt.QImage(160, 80, qt.QImage.Format_ARGB32)
image:fill(qt.QColor("white"))
local painter = qt.QPainter(image)
painter:set_render_hint(qt.QPainter.Antialiasing, true)
painter:set_pen(qt.QPen(qt.QColor("navy"), 3))
painter:set_brush(qt.QBrush(qt.QColor("gold")))
painter:draw_ellipse(10, 10, 60, 60)
painter:draw_text(80, 45, "Lua + Qt")
painter:end_()

local path = qt.QDir.temp_path() .. "/qt6_demo.png"
print("   - " .. image:width() .. "x" .. image:height() .. " image saved: " .. tostring(image:save(path)) .. ", pixel(40, 40) is " .. image:pixel_color(40, 40):name())
qt.QFile.remove(path)

-- the window renders to memory too
local snapshot = window:grab()
print("   - the window grabbed as a " .. snapshot:width() .. "x" .. snapshot:height() .. " pixmap")

-- 5. Models ----------------------------------------------------------------------------------------
print()
print("5. Models")

local model = qt.QStandardItemModel()
for _, name in ipairs({ "pear", "apple", "fig", "banana" }) do
    model:append_row(qt.QStandardItem(name))
end

local proxy = qt.QSortFilterProxyModel()
proxy:set_source_model(model)
proxy:sort(0)
local sorted = {}
for row = 0, proxy:row_count() - 1 do
    sorted[#sorted + 1] = proxy:data(proxy:index(row, 0)) -- a QVariant is a plain Lua value
end
print("   - sorted by a QSortFilterProxyModel: " .. table.concat(sorted, ", "))

-- 6. SQL -------------------------------------------------------------------------------------------
print()
print("6. SQL")

local database = qt.QSqlDatabase.add_database("QSQLITE", "demo")
database:set_database_name(":memory:")
print("   - sqlite opened: " .. tostring(database:open()))
local query = qt.QSqlQuery(database)
query:exec("CREATE TABLE planets (name TEXT, moons INTEGER)")
for _, planet in ipairs({ { "Earth", 1 }, { "Mars", 2 }, { "Jupiter", 95 } }) do
    query:prepare("INSERT INTO planets VALUES (?, ?)")
    query:add_bind_value(planet[1])
    query:add_bind_value(planet[2])
    query:exec()
end
query:exec("SELECT name, moons FROM planets ORDER BY moons DESC")
while query:next() do
    print(string.format("   - %-8s %3d moons", query:value(0), query:value(1)))
end
query:finish()
database:close()

-- 7. XML -------------------------------------------------------------------------------------------
print()
print("7. XML")

local document = qt.QDomDocument()
document:set_content("<library><book year='1999'>Programming in Lua</book><book year='2013'>Qt</book></library>")
local books = document:document_element():elements_by_tag_name("book")
for i = 0, books:count() - 1 do
    local book = books:at(i):to_element()
    print("   - " .. book:attribute("year") .. ": " .. book:text())
end

print()
print("=== Qt6 Demo Complete ===")
