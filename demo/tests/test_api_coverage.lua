-- Checks every class, constructor and function tsujikiri bound against the manifest that
-- gen_api_manifest.py reads back from the generated bindings (qt6_api.lua):
--
--   * the qt6 namespace holds exactly the bound classes,
--   * every static function and property is reachable from its class table,
--   * a class without bound constructors cannot be called,
--   * every class that can be built without arguments is instantiated, and every own and
--     inherited member function is then reachable on the instance (checks the deriveClass
--     wiring across the modules),
--   * the namespace level enums and functions are there.
--
-- What each function *does* is covered by the behavioural tests in the other test_*.lua files.

local T = require("testlib")
local api = require("qt6_api")
local qt = qt6

local by_name = {}
for _, class in ipairs(api.classes) do
    by_name[class.name] = class
end

-- Classes the test cannot build, and why. They are still checked for registration.
local SKIP = {}
local function skip(reason, ...)
    for _, name in ipairs({ ... }) do SKIP[name] = reason end
end

skip("needs a graphics or printing context", "QOpenGLContext", "QOffscreenSurface", "QPrinter", "QPrinterInfo",
    "QPrintDialog", "QPrintPreviewDialog", "QPrintPreviewWidget", "QPageSetupDialog", "QOpenGLWidget",
    "QOpenGLWindow", "QOpenGLPaintDevice", "QOpenGLDebugLogger", "QOpenGLTimerQuery", "QOpenGLTimeMonitor",
    "QOpenGLVertexArrayObject", "QOpenGLShader", "QOpenGLShaderProgram", "QOpenGLTexture", "QOpenGLBuffer",
    "QOpenGLFramebufferObject", "QOpenGLPixelTransferOptions", "QOpenGLVersionProfile", "QOpenGLTextureBlitter",
    "QOpenGLFunctions", "QOpenGLExtraFunctions", "QOpenGLStaticContext", "QOpenGLWidget", "QOpenGLContextGroup",
    "QOpenGLFunctions_1_0", "QOpenGLFunctions_1_1", "QOpenGLFunctions_1_2", "QOpenGLFunctions_1_3",
    "QOpenGLFunctions_1_4", "QOpenGLFunctions_1_5", "QOpenGLFunctions_2_0", "QOpenGLFunctions_2_1",
    "QOpenGLFunctions_3_0", "QOpenGLFunctions_3_1", "QOpenGLFunctions_3_2_Core", "QOpenGLFunctions_3_2_Compatibility",
    "QOpenGLFunctions_3_3_Core", "QOpenGLFunctions_3_3_Compatibility", "QOpenGLFunctions_4_0_Core",
    "QOpenGLFunctions_4_0_Compatibility", "QOpenGLFunctions_4_1_Core", "QOpenGLFunctions_4_1_Compatibility",
    "QOpenGLFunctions_4_2_Core", "QOpenGLFunctions_4_2_Compatibility", "QOpenGLFunctions_4_3_Core",
    "QOpenGLFunctions_4_3_Compatibility", "QOpenGLFunctions_4_4_Core", "QOpenGLFunctions_4_4_Compatibility",
    "QOpenGLFunctions_4_5_Core", "QOpenGLFunctions_4_5_Compatibility", "QOpenGLFunctions_ES2")
skip("needs a platform integration the offscreen plugin lacks", "QSystemTrayIcon", "QDrag", "QFileSystemWatcher")
skip("is only valid as part of a running test", "QTestEventLoop", "QSignalSpy", "QTest_QBenchmarkIterationController",
    "QTest_ThrowOnFailEnabler", "QTest_ThrowOnSkipEnabler", "QTest_ThrowOnFailDisabler", "QTest_ThrowOnSkipDisabler")
skip("needs a bus or a service", "QDBusInterface", "QDBusServer", "QDBusServiceWatcher", "QDBusPendingCallWatcher")

-- Names of the namespaces in the manifest and of the functions in them
local namespaces = {}
for name in pairs(api.namespaces) do namespaces[name] = true end
for _, fn in ipairs(api.functions) do
    local namespace = fn:match("^(.*)%.[^.]+$")
    if namespace then namespaces[namespace] = true end
end

-- Registered in qt6_lua.cpp, not generated
local HELPERS = { LuaConnection = true, EventFilter = true }

-- Member functions of a class plus everything it inherits. Instances see these, the class
-- table itself only holds the class's own static functions
local function member_functions_of(class)
    local names, seen, pending = {}, {}, { class }
    while #pending > 0 do
        local current = table.remove(pending)
        for _, name in ipairs(current.methods) do
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        for _, base in ipairs(current.bases) do
            if by_name[base] then pending[#pending + 1] = by_name[base] end
        end
    end
    return names
end

local function has_default_constructor(class)
    for _, signature in ipairs(class.ctors) do
        if #signature == 0 then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------------------

T.test("the manifest lists the classes of all modules", function()
    T.ok(#api.classes > 700, "got " .. #api.classes .. " classes")
    for _, name in ipairs({ "QObject", "QWidget", "QApplication", "QImage", "QSqlQuery", "QDomDocument", "QTcpSocket",
        "QProcess", "QStandardItemModel", "QPainter", "QMainWindow", "QSettings", "QListWidget", "QWindow" }) do
        T.ok(by_name[name], name .. " is not bound")
    end
    -- converted to Lua values, not classes
    for _, name in ipairs({ "QString", "QByteArray", "QVariant", "QStringList", "QList", "QMap" }) do
        T.ok(not by_name[name], name .. " must not be a class")
    end
end)

T.test("the qt6 namespace holds exactly the bound classes", function()
    local unexpected = {}
    for name, value in pairs(qt) do
        if type(name) == "string" and type(value) == "table" and not by_name[name] and not namespaces[name] and not HELPERS[name] then
            unexpected[#unexpected + 1] = name
        end
    end
    table.sort(unexpected)
    T.same(unexpected, {}, "tables in qt6 that are not in the manifest")

    local missing = {}
    for _, class in ipairs(api.classes) do
        if type(qt[class.name]) ~= "table" then missing[#missing + 1] = class.name end
    end
    T.same(missing, {}, "classes of the manifest that are not in qt6")
end)

T.test("every static function and property is reachable from its class table", function()
    local missing = {}
    for _, class in ipairs(api.classes) do
        local table_of_class = qt[class.name]
        for _, name in ipairs(class.statics) do
            if table_of_class[name] == nil then missing[#missing + 1] = class.name .. "." .. name end
        end
        for _, name in ipairs(class.properties) do
            if table_of_class[name] == nil then missing[#missing + 1] = class.name .. "." .. name end
        end
    end
    T.same(missing, {})
end)

T.test("namespace level enums and functions", function()
    local missing = {}
    for namespace, content in pairs(api.namespaces) do
        local table_of_namespace = qt[namespace]
        if type(table_of_namespace) ~= "table" then
            missing[#missing + 1] = namespace
        else
            for _, value in ipairs(content.values) do
                if table_of_namespace[value] == nil then missing[#missing + 1] = namespace .. "." .. value end
            end
            for _, enum in ipairs(content.tables) do
                if type(table_of_namespace[enum]) ~= "table" then missing[#missing + 1] = namespace .. "." .. enum end
            end
        end
    end
    for _, fn in ipairs(api.functions) do
        local namespace, name = fn:match("^(.*)%.([^.]+)$")
        local holder = namespace and qt[namespace] or qt
        if type(holder) ~= "table" or type(holder[name or fn]) ~= "function" then
            missing[#missing + 1] = fn
        end
    end
    T.same(missing, {})
end)

T.test("the helpers of the support layer are registered", function()
    for _, name in ipairs({ "version", "connect", "cast" }) do
        T.type_is(qt[name], "function", name)
    end
    for name in pairs(HELPERS) do T.type_is(qt[name], "table", name) end
end)

-- ---------------------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------------------

T.test("a class without bound constructors cannot be called", function()
    local callable = 0
    local failures = {}
    for _, class in ipairs(api.classes) do
        if #class.ctors == 0 then
            local ok = pcall(qt[class.name])
            if ok then failures[#failures + 1] = class.name else callable = callable + 1 end
        end
    end
    T.same(failures, {})
    T.ok(callable > 100, "only " .. callable .. " classes without constructors")
end)

-- ---------------------------------------------------------------------------------------
-- Instances: inherited functions reach the object
-- ---------------------------------------------------------------------------------------

T.test("every class that can be built without arguments is instantiated and carries its functions", function()
    local built, abstract, skipped = 0, 0, 0
    local failures = {}

    for _, class in ipairs(api.classes) do
        if SKIP[class.name] then
            skipped = skipped + 1
        elseif has_default_constructor(class) then
            if T.verbose then io.write("  ...   " .. class.name .. "                    \r") end
            local ok, instance = pcall(qt[class.name])
            if not ok then
                failures[#failures + 1] = class.name .. ": " .. tostring(instance)
            else
                built = built + 1
                for _, method in ipairs(member_functions_of(class)) do
                    -- metamethods (__eq, __lt ...) belong to the metatable, an instance does not show them
                    if method:sub(1, 2) ~= "__" and instance[method] == nil then
                        failures[#failures + 1] = class.name .. ":" .. method .. " is not reachable"
                        break
                    end
                end
            end
        else
            abstract = abstract + 1
        end
        collectgarbage("step")
    end

    T.same(failures, {})
    T.ok(built > 300, "only " .. built .. " classes were built")
end)

T.run()
