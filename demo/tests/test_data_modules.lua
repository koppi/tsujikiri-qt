-- QtSql, QtXml and QtNetwork: everything here works offline and without a server.

local T = require("testlib")
local qt = qt6

-- QtSql (sqlite in memory) ---------------------------------------------------------------------------

local connection_counter = 0
local function open_database()
    connection_counter = connection_counter + 1
    local name = "test" .. connection_counter
    local database = qt.QSqlDatabase.add_database("QSQLITE", name)
    database:set_database_name(":memory:")
    T.ok(database:open(), "sqlite should open")
    return database, name
end

T.test("QSql: the sqlite driver is available", function()
    T.contains(qt.QSqlDatabase.drivers(), "QSQLITE")
end)

T.test("QSqlQuery: create, insert, select", function()
    local database, name = open_database()
    local query = qt.QSqlQuery(database)

    T.ok(query:exec("CREATE TABLE planets (name TEXT, moons INTEGER, radius REAL)"))
    for _, row in ipairs({ { "Earth", 1, 6371.0 }, { "Mars", 2, 3389.5 }, { "Jupiter", 95, 69911.0 } }) do
        T.ok(query:prepare("INSERT INTO planets VALUES (?, ?, ?)"))
        query:add_bind_value(row[1])
        query:add_bind_value(row[2])
        query:add_bind_value(row[3])
        T.ok(query:exec())
    end

    T.ok(query:exec("SELECT name, moons, radius FROM planets ORDER BY moons"))
    local rows = {}
    while query:next() do
        rows[#rows + 1] = { query:value(0), query:value(1), query:value(2) }
    end
    T.same(rows, { { "Earth", 1, 6371.0 }, { "Mars", 2, 3389.5 }, { "Jupiter", 95, 69911.0 } })

    query:finish()
    database:close()
    qt.QSqlDatabase.remove_database(name)
end)

T.test("QSqlQuery: a wrong statement reports its error", function()
    local database, name = open_database()
    local query = qt.QSqlQuery(database)
    T.ok(not query:exec("SELECT * FROM missing_table"))
    T.ok(query:last_error():is_valid())
    T.ok(query:last_error():text():find("missing_table", 1, true))
    query:finish()
    database:close()
    qt.QSqlDatabase.remove_database(name)
end)

T.test("QSqlDatabase: transactions", function()
    local database, name = open_database()
    local query = qt.QSqlQuery(database)
    query:exec("CREATE TABLE t (v INTEGER)")

    T.ok(database:transaction())
    query:exec("INSERT INTO t VALUES (1)")
    T.ok(database:rollback())

    query:exec("SELECT COUNT(*) FROM t")
    query:next()
    T.eq(query:value(0), 0)

    query:finish()
    database:close()
    qt.QSqlDatabase.remove_database(name)
end)

-- QtXml -----------------------------------------------------------------------------------------------

T.test("QDomDocument: read elements and attributes", function()
    local document = qt.QDomDocument()
    local ok = document:set_content("<library><book year='1999'>Programming in Lua</book><book year='2013'>Qt</book></library>")
    T.ok(ok:to_bool())

    local root = document:document_element()
    T.eq(root:tag_name(), "library")
    local books = root:elements_by_tag_name("book")
    T.eq(books:count(), 2)
    T.eq(books:at(0):to_element():attribute("year"), "1999")
    T.eq(books:at(1):to_element():text(), "Qt")
end)

T.test("QDomDocument: build and serialise", function()
    local document = qt.QDomDocument()
    local root = document:create_element("config")
    document:append_child(root)
    local entry = document:create_element("entry")
    entry:set_attribute("key", "volume")
    entry:append_child(document:create_text_node("11"))
    root:append_child(entry)

    local xml = document:to_string(-1)
    T.ok(xml:find("<config><entry key=\"volume\">11</entry></config>", 1, true))
end)

T.test("QDomDocument: malformed input is reported", function()
    local document = qt.QDomDocument()
    local result = document:set_content("<open><never closed></open>")
    T.ok(not result:to_bool())
end)

-- QtNetwork -------------------------------------------------------------------------------------------

T.test("QHostAddress: parsing and classification", function()
    local address = qt.QHostAddress("192.168.1.20")
    T.eq(address:to_string(), "192.168.1.20")
    T.eq(address:protocol(), qt.QAbstractSocket.IPv4Protocol)
    T.ok(not address:is_loopback())
    T.ok(qt.QHostAddress(qt.QHostAddress.LocalHost):is_loopback())
    T.eq(qt.QHostAddress("::1"):protocol(), qt.QAbstractSocket.IPv6Protocol)
    T.ok(qt.QHostAddress("not an address"):is_null())
end)

T.test("QNetworkRequest: url and headers", function()
    local request = qt.QNetworkRequest(qt.QUrl("https://example.com/api?q=1"))
    T.eq(request:url():host(), "example.com")
    request:set_raw_header("X-Token", "secret")
    T.eq(request:raw_header("X-Token"), "secret")
    T.ok(request:has_raw_header("x-token"))
    request:set_header(qt.QNetworkRequest.UserAgentHeader, "qt6-lua")
    T.eq(request:header(qt.QNetworkRequest.UserAgentHeader), "qt6-lua")
end)

T.test("QNetworkInterface: lists something", function()
    T.ok(#qt.QNetworkInterface.all_interfaces() >= 1)
end)

T.test("QTcpServer and QTcpSocket: a loopback conversation", function()
    local server = qt.QTcpServer()
    T.ok(server:listen(qt.QHostAddress(qt.QHostAddress.LocalHost), 0))

    local client, received
    server:connect("newConnection", function()
        client = server:next_pending_connection()
        client:connect("readyRead", function() received = client:read_all() end)
    end)

    local socket = qt.QTcpSocket()
    socket:connect_to_host(qt.QHostAddress(qt.QHostAddress.LocalHost), server:server_port())
    T.ok(socket:wait_for_connected(2000))
    socket:write("ping")
    socket:flush()
    T.ok(T.wait_for(function() return received ~= nil end, 3000))
    T.eq(received, "ping")

    socket:close()
    server:close()
end)

T.run()
