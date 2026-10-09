-- QtCore: value classes, text and data formats, files, objects, signals and the event loop.

local T = require("testlib")
local qt = qt6

-- Dates and times --------------------------------------------------------------------------------

T.test("QDate: components and validity", function()
    local date = qt.QDate(2024, 2, 29)
    T.ok(date:is_valid())
    T.eq(date:year(), 2024)
    T.eq(date:month(), 2)
    T.eq(date:day(), 29)
    T.eq(date:day_of_week(), 4) -- a Thursday
    T.eq(date:days_in_month(), 29)
    T.ok(qt.QDate.is_leap_year(2024))
    T.ok(not qt.QDate(2023, 2, 29):is_valid())
end)

T.test("QDate: arithmetic and formatting", function()
    local date = qt.QDate(2026, 10, 9)
    T.eq(date:add_days(30):to_string("yyyy-MM-dd"), "2026-11-08")
    T.eq(date:add_months(4):to_string("yyyy-MM-dd"), "2027-02-09")
    T.eq(date:days_to(qt.QDate(2026, 12, 25)), 77)
    T.eq(date:to_string("dd/MM/yy"), "09/10/26")
    T.eq(date:to_string(qt.Qt.ISODate), "2026-10-09")
end)

T.test("QDate: comparison operators", function()
    local a, b = qt.QDate(2020, 1, 1), qt.QDate(2021, 1, 1)
    T.ok(a < b)
    T.ok(a <= b)
    T.ok(not (b < a))
    T.ok(a == qt.QDate(2020, 1, 1))
    T.ok(a ~= b)
end)

T.test("QTime: components and arithmetic", function()
    local time = qt.QTime(13, 45, 30, 250)
    T.eq(time:hour(), 13)
    T.eq(time:minute(), 45)
    T.eq(time:second(), 30)
    T.eq(time:msec(), 250)
    T.eq(time:add_secs(3600):to_string("HH:mm:ss.zzz"), "14:45:30.250")
    T.eq(time:msecs_since_start_of_day(), ((13 * 60 + 45) * 60 + 30) * 1000 + 250)
end)

T.test("QDateTime: epoch and ISO format", function()
    local utc = qt.QTimeZone.utc()
    local moment = qt.QDateTime.from_secs_since_epoch(86400 * 365, utc)
    T.eq(moment:to_string(qt.Qt.ISODate), "1971-01-01T00:00:00+00:00")
    T.eq(moment:to_secs_since_epoch(), 86400 * 365)
    T.eq(moment:date():year(), 1971)
    T.ok(moment < qt.QDateTime.from_secs_since_epoch(86400 * 366, utc))
end)

-- URLs, patterns and documents ------------------------------------------------------------------

T.test("QUrl: parts", function()
    local url = qt.QUrl("https://user@example.com:8443/docs/index.html?lang=lua&v=6#intro")
    T.ok(url:is_valid())
    T.eq(url:scheme(), "https")
    T.eq(url:user_name(), "user")
    T.eq(url:host(), "example.com")
    T.eq(url:port(), 8443)
    T.eq(url:path(), "/docs/index.html")
    T.eq(url:query(), "lang=lua&v=6")
    T.eq(url:fragment(), "intro")
    T.eq(url:file_name(), "index.html")
end)

T.test("QUrl: building and resolving", function()
    local base = qt.QUrl("http://example.com/a/b/c.html")
    T.eq(base:resolved(qt.QUrl("../d.html")):to_string(), "http://example.com/a/d.html")

    local url = qt.QUrl()
    url:set_scheme("ftp")
    url:set_host("files.example.com")
    url:set_path("/pub")
    T.eq(url:to_string(), "ftp://files.example.com/pub")
end)

T.test("QUrl: local files", function()
    local url = qt.QUrl.from_local_file("/tmp/some file.txt")
    T.eq(url:to_local_file(), "/tmp/some file.txt")
    T.ok(url:is_local_file())
end)

T.test("QRegularExpression: captures", function()
    local regex = qt.QRegularExpression("(?<user>\\w+)@(?<host>[\\w.]+)")
    T.ok(regex:is_valid())
    local match = regex:match("write to lua@example.com today")
    T.ok(match:has_match())
    T.eq(match:captured(0), "lua@example.com")
    T.eq(match:captured("user"), "lua")
    T.eq(match:captured("host"), "example.com")
    T.eq(match:captured_start(0), 9)
end)

T.test("QRegularExpression: no match and invalid patterns", function()
    T.ok(not qt.QRegularExpression("x+"):match("abc"):has_match())
    local broken = qt.QRegularExpression("(unclosed")
    T.ok(not broken:is_valid())
    T.ne(broken:error_string(), "")
end)

T.test("QJsonDocument: parse and read", function()
    local document = qt.QJsonDocument.from_json('{"name": "Qt", "versions": [5, 6], "nested": {"ok": true}}')
    T.ok(document:is_object())
    local object = document:object()
    T.eq(object:value("name"):to_string(), "Qt")
    T.eq(object:value("versions"):to_array():size(), 2)
    T.eq(object:value("versions"):to_array():at(1):to_int(), 6)
    T.eq(object:value("nested"):to_object():value("ok"):to_bool(), true)
    T.ok(object:contains("name"))
    T.ok(not object:contains("missing"))
end)

T.test("QJsonDocument: write", function()
    local object = qt.QJsonObject()
    object:insert("answer", qt.QJsonValue(42))
    object:insert("name", qt.QJsonValue("Qt"))
    local text = qt.QJsonDocument(object):to_json(qt.QJsonDocument.Compact)
    T.ok(text:find('"answer":42', 1, true))
    T.ok(text:find('"name":"Qt"', 1, true))
end)

T.test("QJsonDocument: invalid input is a null document", function()
    T.ok(qt.QJsonDocument.from_json("{not json"):is_null())
end)

T.test("QVersionNumber: ordering", function()
    local a, b = qt.QVersionNumber.from_string("6.8.1"), qt.QVersionNumber.from_string("6.12.0")
    T.ok(a < b)
    T.eq(b:major_version(), 6)
    T.eq(b:minor_version(), 12)
    T.ok(qt.QVersionNumber.compare(a, b) < 0)
end)

T.test("QUuid: parse and format", function()
    local id = qt.QUuid("{67C8770B-44F1-410A-AB9A-F9B5446F13EE}")
    T.ok(not id:is_null())
    T.eq(id:to_string(qt.QUuid.WithoutBraces), "67c8770b-44f1-410a-ab9a-f9b5446f13ee")
    T.ok(qt.QUuid.create_uuid() ~= qt.QUuid.create_uuid())
end)

T.test("QCryptographicHash: well known digests", function()
    local function hex(bytes) return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
    T.eq(hex(qt.QCryptographicHash.hash("abc", qt.QCryptographicHash.Sha256)),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
end)

T.test("QLocale: C locale", function()
    local locale = qt.QLocale(qt.QLocale.C)
    T.eq(locale:to_string(1234.5, "f", 1), "1234.5")
    T.eq(locale:decimal_point(), ".")
end)

-- Files ----------------------------------------------------------------------------------------------

T.test("QTemporaryDir, QFile and QFileInfo", function()
    local directory = qt.QTemporaryDir()
    T.ok(directory:is_valid())

    local path = directory:path() .. "/notes.txt"
    local file = qt.QFile(path)
    T.ok(file:open(qt.QIODevice.WriteOnly | qt.QIODevice.Text))
    file:write("first line\nsecond line\n")
    file:close()

    T.ok(qt.QFile.exists(path))
    local info = qt.QFileInfo(path)
    T.eq(info:file_name(), "notes.txt")
    T.eq(info:suffix(), "txt")
    T.eq(info:size(), 23)
    T.ok(info:is_file())

    T.ok(file:open(qt.QIODevice.ReadOnly))
    T.eq(file:read_all(), "first line\nsecond line\n")
    file:close()
end)

T.test("QFile: a missing file does not open", function()
    local file = qt.QFile("/definitely/not/here.txt")
    T.ok(not file:open(qt.QIODevice.ReadOnly))
    T.ne(file:error_string(), "")
end)

T.test("QDir: listing", function()
    local directory = qt.QTemporaryDir()
    for _, name in ipairs({ "b.txt", "a.txt", "c.log" }) do
        local file = qt.QFile(directory:path() .. "/" .. name)
        file:open(qt.QIODevice.WriteOnly)
        file:close()
    end

    local listing = qt.QDir(directory:path())
    T.same(listing:entry_list({ "*.txt" }, qt.QDir.Files, qt.QDir.Name), { "a.txt", "b.txt" })
    T.eq(listing:count(), 5) -- . and .. as well
end)

T.test("QStandardPaths: the temp directory exists", function()
    T.ok(qt.QDir(qt.QDir.temp_path()):exists())
end)

-- Objects --------------------------------------------------------------------------------------------

T.test("QObject: names and the parent tree", function()
    local parent = qt.QObject()
    parent:set_object_name("parent")
    local child = qt.QObject(parent)
    child:set_object_name("child")
    T.eq(child:parent():object_name(), "parent")
    T.eq(#parent:children(), 1)
    T.eq(parent:children()[1]:object_name(), "child")
end)

T.test("QObject: dynamic properties", function()
    local object = qt.QObject()
    object:set_property("level", 3)
    T.eq(object:property("level"), 3)
    T.contains(object:dynamic_property_names(), "level")
end)

T.test("QObject: the meta object describes the class", function()
    local timer = qt.QTimer()
    local meta = timer:meta_object()
    T.eq(meta:class_name(), "QTimer")
    T.eq(meta:super_class():class_name(), "QObject")
    T.ok(timer:inherits("QObject"))
    T.ok(not timer:inherits("QWidget"))
    T.ok(meta:index_of_signal("timeout()") >= 0)
end)

T.test("QObject: a parentless object is deleted with its Lua value", function()
    local destroyed = false
    do
        local object = qt.QObject()
        object:connect("destroyed", function() destroyed = true end)
    end
    collectgarbage()
    collectgarbage()
    T.ok(destroyed)
end)

T.test("QObject: a child belongs to its parent, not to Lua", function()
    local destroyed = false
    local parent = qt.QObject()
    do
        local child = qt.QObject(parent)
        child:connect("destroyed", function() destroyed = true end)
    end
    collectgarbage()
    collectgarbage()
    T.ok(not destroyed, "the child must survive the collection of its Lua value")
    T.eq(#parent:children(), 1)

    parent = nil
    collectgarbage()
    collectgarbage()
    T.ok(destroyed, "deleting the parent deletes the child")
end)

T.test("QObject: delete_later is a deferred delete", function()
    local destroyed = false
    local object = qt.QObject()
    object:connect("destroyed", function() destroyed = true end)
    object:delete_later()
    T.ok(not destroyed)
    qt.QCoreApplication.send_posted_events(nil, qt.QEvent.DeferredDelete)
    T.ok(destroyed)
end)

-- Signals --------------------------------------------------------------------------------------------

T.test("signals: connect by name calls the function with the arguments", function()
    local object = qt.QObject()
    local seen = {}
    object:connect("objectNameChanged", function(name) seen[#seen + 1] = name end)
    object:set_object_name("one")
    object:set_object_name("two")
    T.same(seen, { "one", "two" })
end)

T.test("signals: the signature and the SIGNAL() form select the signal", function()
    local object = qt.QObject()
    local calls = 0
    object:connect("objectNameChanged(QString)", function() calls = calls + 1 end)
    object:connect("2objectNameChanged(QString)", function() calls = calls + 10 end)
    object:set_object_name("x")
    T.eq(calls, 11)
end)

T.test("signals: connect returns a connection that disconnects", function()
    local object = qt.QObject()
    local calls = 0
    local connection = object:connect("objectNameChanged", function() calls = calls + 1 end)
    T.ok(connection:is_connected())
    object:set_object_name("a")
    connection:disconnect()
    T.ok(not connection:is_connected())
    object:set_object_name("b")
    T.eq(calls, 1)
end)

T.test("signals: QObject arguments arrive as objects", function()
    local received
    local object = qt.QObject()
    object:set_object_name("doomed")
    -- the sender is on its way out: read what is needed while the signal is emitted
    object:connect("destroyed", function(sender) received = sender:object_name() end)
    object = nil
    collectgarbage()
    collectgarbage()
    T.eq(received, "doomed")
end)

T.test("signals: a connection ends with its sender", function()
    local object = qt.QObject()
    local connection = object:connect("objectNameChanged", function() end)
    T.ok(connection:is_connected())
    object = nil
    collectgarbage()
    collectgarbage()
    T.ok(not connection:is_connected())
    connection:disconnect() -- harmless
end)

T.test("signals: unknown signals and bad arguments are errors", function()
    local object = qt.QObject()
    T.throws(function() object:connect("noSuchSignal", function() end) end, "has no signal")
    T.throws(function() object:connect("destroyed", 42) end, "function")
    T.throws(function() qt.connect(nil, "destroyed", function() end) end)
end)

-- (the error of the function is reported on stderr as a warning, which is expected in the output of this test)
T.test("signals: an error in the function does not break the signal", function()
    local object = qt.QObject()
    local calls = 0
    object:connect("objectNameChanged", function() calls = calls + 1; error("boom") end)
    object:set_object_name("a")
    object:set_object_name("b")
    T.eq(calls, 2)
end)

T.test("signals: qt6.connect is the same as the method", function()
    local object = qt.QObject()
    local seen
    qt.connect(object, "objectNameChanged", function(name) seen = name end)
    object:set_object_name("function form")
    T.eq(seen, "function form")
end)

-- The event loop -------------------------------------------------------------------------------------

T.test("QTimer: fires through the event loop", function()
    local loop = qt.QEventLoop()
    local timer = qt.QTimer()
    timer:set_single_shot(true)
    timer:set_interval(5)
    local fired = false
    timer:connect("timeout", function() fired = true; loop:quit() end)
    timer:start()
    loop:exec()
    T.ok(fired)
    T.ok(not timer:is_active())
end)

T.test("QTimer: repeats until stopped", function()
    local timer = qt.QTimer()
    timer:set_interval(1)
    local count = 0
    timer:connect("timeout", function() count = count + 1 end)
    timer:start()
    T.ok(T.wait_for(function() return count >= 3 end))
    timer:stop()
    T.ok(count >= 3)
end)

T.test("QElapsedTimer measures time", function()
    local clock = qt.QElapsedTimer()
    clock:start()
    qt.QThread.msleep(20)
    T.ok(clock:elapsed() >= 15)
    T.ok(clock:has_expired(1))
end)

T.test("QCoreApplication: the host application", function()
    local application = qt.QCoreApplication.instance()
    T.ok(application ~= nil)
    T.eq(application:meta_object():class_name(), "QApplication")
    qt.QCoreApplication.set_application_name("qt6-lua-tests")
    T.eq(qt.QCoreApplication.application_name(), "qt6-lua-tests")
end)

T.run()
