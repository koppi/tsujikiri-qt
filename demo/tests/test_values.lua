-- How Qt values cross into Lua (support/qt6_lua.h): strings, byte arrays, lists, maps,
-- variants, flags and enums. Every one of them is a plain Lua value.

local T = require("testlib")
local qt = qt6

-- QString ------------------------------------------------------------------------------------------

T.test("QString is a Lua string: ASCII round trip", function()
    local object = qt.QObject()
    object:set_object_name("hello")
    T.eq(object:object_name(), "hello")
    T.eq(type(object:object_name()), "string")
end)

T.test("QString is UTF-8 in Lua", function()
    local object = qt.QObject()
    object:set_object_name("héllo wörld ✓ 日本語")
    T.eq(object:object_name(), "héllo wörld ✓ 日本語")
end)

T.test("QString: characters outside the BMP survive", function()
    local object = qt.QObject()
    object:set_object_name("𝄞 clef")
    T.eq(object:object_name(), "𝄞 clef")
end)

T.test("QString: nil is the empty string", function()
    local object = qt.QObject()
    object:set_object_name("something")
    object:set_object_name(nil)
    T.eq(object:object_name(), "")
end)

T.test("QString: a number is converted to text", function()
    local object = qt.QObject()
    object:set_object_name(42)
    T.eq(object:object_name(), "42")
end)

T.test("QString: a table is not text", function()
    local object = qt.QObject()
    T.throws(function() object:set_object_name({}) end)
end)

T.test("QString: embedded zeros are kept", function()
    local object = qt.QObject()
    object:set_object_name("a\0b")
    T.eq(object:object_name(), "a\0b")
end)

-- QByteArray ---------------------------------------------------------------------------------------

T.test("QByteArray is a binary safe Lua string", function()
    local hash = qt.QCryptographicHash.hash("abc", qt.QCryptographicHash.Md5)
    T.eq(#hash, 16)
    T.eq((hash:gsub(".", function(c) return string.format("%02x", c:byte()) end)), "900150983cd24fb0d6963f7d28e17f72")
end)

T.test("QByteArray in: bytes that are not valid UTF-8", function()
    local hash = qt.QCryptographicHash.hash("\xff\xfe\x00\x01", qt.QCryptographicHash.Sha1)
    T.eq(#hash, 20)
end)

-- Lists ----------------------------------------------------------------------------------------------

T.test("QStringList is a sequence of strings", function()
    local dir = qt.QDir(".")
    dir:set_name_filters({ "*.lua", "*.txt", "ünï.*" })
    T.same(dir:name_filters(), { "*.lua", "*.txt", "ünï.*" })
end)

T.test("QStringList: an empty table is an empty list", function()
    local dir = qt.QDir(".")
    dir:set_name_filters({})
    T.same(dir:name_filters(), {})
end)

T.test("QStringList: an element that is no string is an error", function()
    local dir = qt.QDir(".")
    T.throws(function() dir:set_name_filters({ "ok", {} }) end)
end)

T.test("QList of objects is a sequence of userdata", function()
    local parent = qt.QObject()
    local first, second = qt.QObject(parent), qt.QObject(parent)
    first:set_object_name("first")
    second:set_object_name("second")
    local children = parent:children()
    T.eq(#children, 2)
    T.eq(children[1]:object_name(), "first")
    T.eq(children[2]:object_name(), "second")
end)

T.test("QList of values is a sequence of copies", function()
    local polygon = qt.QPolygon()
    polygon:append(qt.QPoint(1, 2))
    polygon:append(qt.QPoint(3, 4))
    T.eq(polygon:size(), 2)
    T.xy(polygon:point(1), 3, 4)
end)

-- Maps -----------------------------------------------------------------------------------------------

T.test("QVariantMap is a table", function()
    local object = qt.QJsonObject.from_variant_map({ name = "Qt", major = 6, lts = true, ratio = 0.5 })
    local map = object:to_variant_map()
    T.eq(map.name, "Qt")
    T.eq(map.major, 6)
    T.eq(map.lts, true)
    T.near(map.ratio, 0.5)
end)

T.test("QHash<int, QByteArray> is a table with integer keys", function()
    local model = qt.QStandardItemModel()
    local roles = model:role_names()
    T.eq(roles[qt.Qt.DisplayRole], "display")
    T.eq(roles[qt.Qt.EditRole], "edit")
end)

-- QVariant ---------------------------------------------------------------------------------------

T.test("QVariant: scalars keep their type", function()
    local object = qt.QObject()
    object:set_property("integer", 7)
    object:set_property("number", 2.5)
    object:set_property("flag", true)
    object:set_property("text", "seven")
    T.eq(object:property("integer"), 7)
    T.eq(math.type(object:property("integer")), "integer")
    T.eq(object:property("number"), 2.5)
    T.eq(object:property("flag"), true)
    T.eq(object:property("text"), "seven")
end)

T.test("QVariant: a big integer does not lose bits", function()
    local object = qt.QObject()
    object:set_property("big", 5000000000)
    T.eq(object:property("big"), 5000000000)
end)

T.test("QVariant: nil is an invalid variant", function()
    local object = qt.QObject()
    T.is_nil(object:property("never set"))
    object:set_property("nothing", nil)
    T.is_nil(object:property("nothing"))
end)

T.test("QVariant: sequences and dictionaries", function()
    local object = qt.QObject()
    object:set_property("list", { 1, "two", 3.5, { 4 } })
    T.same(object:property("list"), { 1, "two", 3.5, { 4 } })

    object:set_property("map", { a = 1, b = { c = "deep" } })
    T.same(object:property("map"), { a = 1, b = { c = "deep" } })
end)

T.test("QVariant: bound value classes travel inside", function()
    local object = qt.QObject()
    object:set_property("where", qt.QPoint(5, 6))
    local point = object:property("where")
    T.xy(point, 5, 6)

    object:set_property("color", qt.QColor("red"))
    T.eq(object:property("color"):name(), "#ff0000")
end)

T.test("QVariant: objects travel inside", function()
    local object, other = qt.QObject(), qt.QObject()
    other:set_object_name("other")
    object:set_property("buddy", other)
    T.eq(object:property("buddy"):object_name(), "other")
end)

-- Enums and flags ------------------------------------------------------------------------------------

T.test("enums are integers, in the class and as a table", function()
    T.eq(math.type(qt.QEvent.KeyPress), "integer")
    T.eq(qt.QEvent.KeyPress, qt.QEvent.Type.KeyPress)
    T.ne(qt.QEvent.KeyPress, qt.QEvent.KeyRelease)
end)

T.test("enums of the Qt namespace", function()
    T.eq(math.type(qt.Qt.AlignLeft), "integer")
    T.eq(qt.Qt.AlignLeft, qt.Qt.AlignmentFlag.AlignLeft)
    T.eq(qt.Qt.Key_A, 0x41)
end)

T.test("flags are integers that combine with | and &", function()
    local flags = qt.Qt.AlignLeft | qt.Qt.AlignTop
    T.ne(flags, qt.Qt.AlignLeft)
    T.ok(flags & qt.Qt.AlignTop ~= 0)
    T.eq(flags & qt.Qt.AlignRight, 0)
end)

T.test("flags go in and come out", function()
    local label = qt.QLabel()
    label:set_alignment(qt.Qt.AlignRight | qt.Qt.AlignBottom)
    T.eq(label:alignment(), qt.Qt.AlignRight | qt.Qt.AlignBottom)
end)

T.test("a scoped enum is passed as a number", function()
    local image = qt.QImage(2, 2, qt.QImage.Format_RGB32)
    T.eq(image:format(), qt.QImage.Format_RGB32)
end)

-- Overloads on the new types ---------------------------------------------------------------------------

T.test("overloads are told apart by the Lua type of the argument", function()
    local point = qt.QPointF(1.5, 2.5)
    T.near(point:x(), 1.5)
    local ints = qt.QPoint(1, 2)
    T.eq(ints:x(), 1)
end)

T.run()
