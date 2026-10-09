-- Classes that are easy to get wrong in a binding: the ones Qt takes over (scenes and items, undo
-- commands, mime data), settings, text documents, processes, threads.

local T = require("testlib")
local qt = qt6

-- Objects that Qt adopts -----------------------------------------------------------------------------

T.test("QGraphicsScene owns the items added to it", function()
    local scene = qt.QGraphicsScene()
    local rect = qt.QGraphicsRectItem(0, 0, 10, 20)
    scene:add_item(rect)

    -- the Lua value goes away, the item must not
    rect = nil
    collectgarbage()
    collectgarbage()

    local items = scene:items()
    T.eq(#items, 1)
    T.rect(items[1]:bounding_rect(), 0, 0, 10, 20, 1.5) -- a pen width wider
end)

T.test("QGraphicsScene: the items it creates itself", function()
    local scene = qt.QGraphicsScene()
    local rect = scene:add_rect(5, 5, 30, 40)
    local line = scene:add_line(0, 0, 10, 10)
    T.eq(#scene:items(), 2)
    T.near(rect:rect():width(), 30)
    T.near(line:line():length(), math.sqrt(200))
    rect:set_pos(100, 100)
    T.xy(rect:pos(), 100, 100)
    T.eq(scene:items_bounding_rect():width() > 100, true)
end)

T.test("QGraphicsView renders a scene", function()
    local scene = qt.QGraphicsScene()
    scene:set_scene_rect(0, 0, 64, 64)
    scene:set_background_brush(qt.QColor("white"))
    scene:add_rect(0, 0, 64, 64, qt.QPen(qt.QColor("black")), qt.QBrush(qt.QColor("red")))

    local image = qt.QImage(64, 64, qt.QImage.Format_ARGB32)
    image:fill(qt.QColor("white"))
    local painter = qt.QPainter(image)
    scene:render(painter)
    painter:end_()
    T.eq(image:pixel_color(32, 32):name(), "#ff0000")
end)

T.test("QUndoStack takes the commands it is given", function()
    local stack = qt.QUndoStack()
    do
        local command = qt.QUndoCommand("first")
        stack:push(command)
    end
    stack:push(qt.QUndoCommand("second"))
    collectgarbage()
    collectgarbage()

    T.eq(stack:count(), 2)
    T.eq(stack:undo_text(), "second")
    stack:undo()
    T.eq(stack:index(), 1)
    T.eq(stack:redo_text(), "second")
    T.ok(stack:can_redo())
    stack:redo()
    T.ok(not stack:can_redo())
end)

T.test("QMimeData: text, URLs and formats", function()
    local data = qt.QMimeData()
    data:set_text("hello")
    T.ok(data:has_text())
    T.eq(data:text(), "hello")
    T.contains(data:formats(), "text/plain")

    data:set_urls({ qt.QUrl("http://example.com/a"), qt.QUrl("http://example.com/b") })
    T.ok(data:has_urls())
    T.eq(#data:urls(), 2)
    T.eq(data:urls()[2]:path(), "/b")
end)

T.test("QClipboard: set and get", function()
    local clipboard = qt.QGuiApplication.clipboard()
    clipboard:set_text("from Lua")
    T.eq(clipboard:text(), "from Lua")
end)

-- Settings and command lines ---------------------------------------------------------------------------

T.test("QSettings: an ini file", function()
    local directory = qt.QTemporaryDir()
    local path = directory:path() .. "/settings.ini"

    do
        local settings = qt.QSettings(path, qt.QSettings.IniFormat)
        settings:set_value("window/width", 640)
        settings:set_value("window/title", "Lua")
        settings:set_value("recent", { "a.txt", "b.txt" })
        settings:sync()
        T.eq(settings:status(), qt.QSettings.NoError)
    end

    local settings = qt.QSettings(path, qt.QSettings.IniFormat)
    T.eq(tonumber(settings:value("window/width")), 640)
    T.eq(settings:value("window/title"), "Lua")
    T.same(settings:value("recent"), { "a.txt", "b.txt" })
    T.eq(settings:value("missing", "fallback"), "fallback")
    T.ok(settings:contains("window/title"))
    T.same(settings:child_keys(), { "recent" })
    settings:begin_group("window")
    T.eq(#settings:all_keys(), 2)
    settings:end_group()
end)

T.test("QCommandLineParser", function()
    local parser = qt.QCommandLineParser()
    parser:add_option(qt.QCommandLineOption("v", "verbose output"))
    parser:add_option(qt.QCommandLineOption("name", "a name", "value", "nobody"))
    T.ok(parser:parse({ "program", "-v", "--name", "lua", "file.txt" }))
    T.ok(parser:is_set("v"))
    T.eq(parser:value("name"), "lua")
    T.same(parser:positional_arguments(), { "file.txt" })
end)

-- Text -----------------------------------------------------------------------------------------------

T.test("QTextDocument and QTextCursor", function()
    local document = qt.QTextDocument()
    document:set_plain_text("one\ntwo\nthree")
    T.eq(document:block_count(), 3)
    T.eq(document:to_plain_text(), "one\ntwo\nthree")

    local cursor = qt.QTextCursor(document)
    cursor:move_position(qt.QTextCursor.End)
    cursor:insert_text("\nfour")
    T.eq(document:block_count(), 4)
    T.eq(document:find_block_by_number(3):text(), "four")
end)

T.test("QRegularExpression: all matches", function()
    local matches = qt.QRegularExpression("\\d+"):global_match("a1 b22 c333")
    local found = {}
    while matches:has_next() do
        found[#found + 1] = matches:next():captured(0)
    end
    T.same(found, { "1", "22", "333" })
end)

T.test("QCollator: compares text", function()
    local collator = qt.QCollator(qt.QLocale(qt.QLocale.C))
    T.ok(collator:compare("apple", "banana") < 0)
    T.eq(collator:compare("same", "same"), 0)
end)

-- Processes and threads ---------------------------------------------------------------------------------

T.test("QProcess runs a program", function()
    if qt.QSysInfo.product_type() == "windows" then return end

    local process = qt.QProcess()
    process:start("sh", { "-c", "printf 'hi from sh'" })
    T.ok(process:wait_for_finished(10000))
    T.eq(process:exit_code(), 0)
    T.eq(process:read_all_standard_output(), "hi from sh")
end)

T.test("QThread starts and stops", function()
    local thread = qt.QThread()
    local started = false
    thread:connect("started", function() started = true end)
    thread:start()
    T.ok(T.wait_for(function() return thread:is_running() end))
    thread:quit()
    T.ok(thread:wait(5000))
    T.ok(thread:is_finished())
    T.ok(qt.QThread.ideal_thread_count() >= 1)
end)

T.run()
