-- A self-check of the Qt6 bindings on koppi/os: the values, containers, enums and signals that cross
-- between Lua and the Qt 6.8 that is linked into qtlua, and a little painting. No window is shown, so it
-- runs anywhere, from the serial console as well:
--
--     qtlua /rd/selftest.lua
--
-- Every case prints "selftest: ok <name>" or "selftest: FAIL <name>: <why>", the last line is the
-- verdict (test/qt-lua-boot.sh reads these).

local qt = qt6
local passed, failed = 0, 0

local function case(name, fn)
    local ok, err = pcall(fn)
    if ok and err == nil then
        passed = passed + 1
        print("selftest: ok " .. name)
    else
        failed = failed + 1
        print("selftest: FAIL " .. name .. ": " .. tostring(err == nil and "false" or err))
    end
end

local function equal(a, b)
    if a ~= b then error(string.format("%s ~= %s", tostring(a), tostring(b)), 2) end
end

local function near(a, b, eps)
    if math.abs(a - b) > (eps or 1e-6) then error(string.format("%s is not near %s", tostring(a), tostring(b)), 2) end
end

-- Lua itself: this is the C library the interpreter shares with Qt
case("lua numbers", function()
    equal(tostring(0.1), "0.1")
    equal(tostring(1 / 3), "0.33333333333333")
    equal(tostring(2 ^ 0.5), "1.4142135623731")
    equal(tostring(1e15), "1e+15")
    equal(string.format("%5.2f|%d|%s|%x", 3.14159, 42, "hi", 255), " 3.14|42|hi|ff")
    equal(tonumber("0x10"), 16)
    equal(tonumber("1e3"), 1000.0)
    equal(math.floor(-2.5), -3)
    equal(("x"):rep(3), "xxx")
end)

-- Strings, lists, maps and variants are Lua values
case("strings", function()
    equal(qt.QDir.clean_path("/a/b/../c//d"), "/a/c/d")
    equal(qt.QDir.separator(), "/")
end)

case("geometry", function()
    local r = qt.QRect(10, 20, 100, 50)
    equal(r:width(), 100)
    equal(r:right(), 109)
    equal(r:center():x(), 59)
    local p = qt.QPoint(3, 4) + qt.QPoint(1, 1)
    equal(p:x(), 4)
    equal(p:y(), 5)
    equal(qt.QPoint(3, 4):manhattan_length(), 7)
    equal(qt.QSize(4, 3) * 2.0 == qt.QSize(8, 6), true)
    equal(r:contains(qt.QPoint(15, 25)), true)
    equal(r:united(qt.QRect(0, 0, 5, 5)):left(), 0)
    local f = qt.QRectF(0.5, 0.5, 2.0, 1.0)
    near(f:center():x(), 1.5)
end)

case("dates and times", function()
    local d = qt.QDate(2026, 10, 9)
    equal(d:day_of_year(), 282)
    equal(d:add_days(30):to_string("yyyy-MM-dd"), "2026-11-08")
    equal(d:day_of_week(), 5)
    equal(qt.QDate(2024, 2, 1):days_in_month(), 29)
    local t = qt.QTime(13, 45, 30)
    equal(t:add_secs(30):to_string("hh:mm:ss"), "13:46:00")
    local dt = qt.QDateTime(d, t)
    equal(dt:to_string("yyyy-MM-dd hh:mm"), "2026-10-09 13:45")
    equal(qt.QDate(2026, 1, 1) < qt.QDate(2026, 1, 2), true)
end)

case("colors", function()
    local c = qt.QColor("steelblue")
    equal(c:red(), 70)
    equal(c:name(), "#4682b4")
    equal(qt.QColor(255, 128, 0):name(), "#ff8000")
    local hsv = qt.QColor(255, 0, 0)
    equal(hsv:hue(), 0)
    equal(qt.QColor("#102030"):green(), 0x20)
end)

case("url", function()
    local u = qt.QUrl("https://user@example.com:8443/docs/index.html?lang=lua#intro")
    equal(u:host(), "example.com")
    equal(u:port(), 8443)
    equal(u:path(), "/docs/index.html")
    equal(u:query(), "lang=lua")
    equal(u:fragment(), "intro")
end)

case("regular expression", function()
    local re = qt.QRegularExpression("(\\w+)@(\\w+)\\.com")
    local m = re:match("write to lua@example.com today")
    equal(m:has_match(), true)
    equal(m:captured(1), "lua")
    equal(m:captured(2), "example")
end)

case("json", function()
    local doc = qt.QJsonDocument.from_json('{"name": "Qt", "versions": [5, 6], "lts": true}')
    local obj = doc:object()
    equal(obj:value("name"):to_string(), "Qt")
    equal(obj:value("versions"):to_array():size(), 2)
    equal(obj:value("lts"):to_bool(), true)
end)

case("enums and flags", function()
    equal(qt.QEvent.KeyPress, qt.QEvent.Type.KeyPress)
    equal(qt.Qt.AlignLeft, qt.Qt.AlignmentFlag.AlignLeft)
    equal(qt.Qt.AlignLeft | qt.Qt.AlignTop, 0x21)
    equal(qt.Qt.Key_Escape, 0x01000000)
    equal(qt.Qt.LeftButton, 1)
end)

case("objects and properties", function()
    local o = qt.QObject()
    o:set_object_name("demo")
    o:set_property("answer", 42)
    o:set_property("tags", { "a", "b", "c" })
    equal(o:object_name(), "demo")
    equal(o:property("answer"), 42)
    equal(table.concat(o:property("tags"), ","), "a,b,c")
    local child = qt.QObject(o)
    child:set_object_name("kid")
    equal(o:find_child("kid"):object_name(), "kid")
end)

case("timers and the event loop", function()
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
    equal(ticks, 5)
end)

case("single shot timer", function()
    local loop = qt.QEventLoop()
    local timer = qt.QTimer()
    timer:set_single_shot(true)
    timer:set_interval(10)
    local fired = 0
    timer:connect("timeout", function() fired = fired + 1; loop:quit() end)
    timer:start()
    loop:exec()
    equal(fired, 1)
    equal(timer:is_active(), false)
end)

case("painting", function()
    local image = qt.QImage(64, 32, qt.QImage.Format_ARGB32)
    image:fill(qt.QColor("white"))
    local painter = qt.QPainter(image)
    painter:set_pen(qt.QPen(qt.QColor("navy"), 1))
    painter:set_brush(qt.QBrush(qt.QColor("gold")))
    painter:draw_rect(4, 4, 24, 24)
    painter:end_()
    equal(image:width(), 64)
    equal(image:pixel_color(10, 10):name(), "#ffd700")
    equal(image:pixel_color(50, 10):name(), "#ffffff")
end)

case("transform", function()
    local t = qt.QTransform():translate(10, 20):scale(2, 2)
    local mapped = t:map(qt.QPointF(1, 1))
    near(mapped:x(), 12)
    near(mapped:y(), 22)
end)

case("model", function()
    local model = qt.QStandardItemModel()
    for _, name in ipairs({ "pear", "apple", "fig" }) do
        model:append_row(qt.QStandardItem(name))
    end
    equal(model:row_count(), 3)
    equal(model:data(model:index(1, 0)), "apple")
end)

case("files", function()
    equal(qt.QFile.exists("/rd/selftest.lua"), true)
    equal(qt.QFile.exists("/rd/no-such-file"), false)
    equal(qt.QFileInfo("/rd/selftest.lua"):file_name(), "selftest.lua")
end)

case("widgets exist without a window", function()
    local button = qt.QPushButton("Hello")
    equal(button:text(), "Hello")
    local layout = qt.QVBoxLayout()
    layout:add_widget(qt.QLabel("one"))
    layout:add_widget(qt.QLabel("two"))
    equal(layout:count(), 2)
    local spin = qt.QSpinBox()
    spin:set_range(0, 10)
    spin:set_value(7)
    equal(spin:value(), 7)
    spin:set_value(70)
    equal(spin:value(), 10)
end)

print(string.format("selftest: %d passed, %d failed", passed, failed))
