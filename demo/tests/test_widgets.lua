-- QtWidgets and the model/view classes, driven with QTest events. The widgets are rendered to
-- memory (the offscreen platform), so nothing appears on a screen.

local T = require("testlib")
local qt = qt6

-- Basic widgets ----------------------------------------------------------------------------------------

T.test("QLabel: text and alignment", function()
    local label = qt.QLabel("hello")
    T.eq(label:text(), "hello")
    label:set_text("changed")
    T.eq(label:text(), "changed")
    label:set_alignment(qt.Qt.AlignCenter)
    T.eq(label:alignment(), qt.Qt.AlignCenter)
end)

T.test("QLineEdit: text, selection and signals", function()
    local edit = qt.QLineEdit()
    local changes = {}
    edit:connect("textChanged", function(text) changes[#changes + 1] = text end)
    edit:set_text("abc")
    edit:set_text("abcd")
    T.same(changes, { "abc", "abcd" })
    edit:select_all()
    T.eq(edit:selected_text(), "abcd")
    edit:set_max_length(2)
    edit:clear()
    T.eq(edit:text(), "")
end)

T.test("QSpinBox: range, value and signal", function()
    local spin = qt.QSpinBox()
    spin:set_range(0, 10)
    local seen = {}
    spin:connect("valueChanged(int)", function(value) seen[#seen + 1] = value end)
    spin:set_value(4)
    spin:set_value(100) -- clamped
    spin:set_value(-5)
    T.same(seen, { 4, 10, 0 })
    T.eq(spin:minimum(), 0)
    T.eq(spin:maximum(), 10)
end)

T.test("QCheckBox and QRadioButton: toggling", function()
    local box = qt.QCheckBox("option")
    local states = {}
    box:connect("toggled", function(checked) states[#states + 1] = checked end)
    box:set_checked(true)
    box:toggle()
    T.same(states, { true, false })
    T.eq(box:text(), "option")
end)

T.test("QComboBox: items and current index", function()
    local combo = qt.QComboBox()
    combo:add_items({ "red", "green", "blue" })
    T.eq(combo:count(), 3)
    T.eq(combo:current_text(), "red")
    local indices = {}
    combo:connect("currentIndexChanged(int)", function(index) indices[#indices + 1] = index end)
    combo:set_current_index(2)
    T.eq(combo:current_text(), "blue")
    T.same(indices, { 2 })
    T.eq(combo:find_text("green"), 1)
end)

T.test("QSlider and QProgressBar", function()
    local slider = qt.QSlider(qt.Qt.Horizontal)
    slider:set_range(0, 100)
    slider:set_value(40)
    T.eq(slider:value(), 40)

    local bar = qt.QProgressBar()
    bar:set_range(0, 10)
    bar:set_value(5)
    T.eq(bar:value(), 5)
    T.eq(bar:text(), "50%")
end)

T.test("QTextEdit: plain text and cursor", function()
    local edit = qt.QTextEdit()
    edit:set_plain_text("one\ntwo")
    T.eq(edit:to_plain_text(), "one\ntwo")
    T.eq(edit:document():block_count(), 2)
    edit:append("three")
    T.eq(edit:document():block_count(), 3)
end)

-- Layouts and the widget tree ----------------------------------------------------------------------------

T.test("layouts: widgets are laid out in the window", function()
    local window = qt.QWidget()
    window:resize(300, 200)
    local layout = qt.QVBoxLayout(window)
    local first, second = qt.QPushButton("first"), qt.QPushButton("second")
    layout:add_widget(first)
    layout:add_widget(second)
    window:show()

    T.eq(layout:count(), 2)
    T.ok(first:geometry():y() < second:geometry():y())
    T.eq(first:parent_widget():width(), 300)
    T.ok(window:is_visible())
    window:hide()
    T.ok(not window:is_visible())
end)

T.test("layouts: grid and form", function()
    local window = qt.QWidget()
    local grid = qt.QGridLayout(window)
    grid:add_widget(qt.QLabel("a"), 0, 0)
    grid:add_widget(qt.QLabel("b"), 0, 1)
    grid:add_widget(qt.QLabel("c"), 1, 0, 1, 2)
    T.eq(grid:count(), 3)
    T.eq(grid:row_count(), 2)
    T.eq(grid:column_count(), 2)

    local other = qt.QWidget()
    local form = qt.QFormLayout(other)
    form:add_row("Name:", qt.QLineEdit())
    T.eq(form:row_count(), 1)
end)

T.test("the widget tree: parents own their children", function()
    local window = qt.QWidget()
    local button = qt.QPushButton("child", window)
    T.eq(button:parent_widget():object_name(), window:object_name())
    T.eq(#window:children(), 1)
    window:delete_later()
end)

T.test("find_child returns the real class", function()
    local window = qt.QWidget()
    local edit = qt.QLineEdit(window)
    edit:set_object_name("name_edit")
    edit:set_text("found")

    local found = window:find_child("name_edit")
    T.ok(found ~= nil)
    T.eq(found:text(), "found") -- text() only exists on QLineEdit
    T.eq(window:find_child("name_edit", "QPushButton"), nil)
    T.eq(#window:find_children(nil, "QLineEdit"), 1)
end)

T.test("a base class pointer is the real class once it is used", function()
    local window = qt.QWidget()
    local button = qt.QPushButton("hi", window)
    local back = window:children()[1] -- a QObject as far as Qt's signature goes
    T.eq(back:text(), "hi")
    T.eq(qt.cast(window:children()[1], "QPushButton"):text(), "hi")
    T.is_nil(qt.cast(window:children()[1], "QLineEdit"))
end)

-- Signals from events --------------------------------------------------------------------------------

T.test("QTest: mouse clicks reach the signals", function()
    local window = qt.QWidget()
    local layout = qt.QVBoxLayout(window)
    local button = qt.QPushButton("press")
    layout:add_widget(button)
    window:show()

    local clicks = 0
    button:connect("clicked", function() clicks = clicks + 1 end)
    qt.QTest.mouse_click(button, qt.Qt.LeftButton)
    qt.QTest.mouse_click(button, qt.Qt.LeftButton)
    T.eq(clicks, 2)
end)

T.test("QTest: key clicks edit text", function()
    local edit = qt.QLineEdit()
    edit:show()
    qt.QTest.key_clicks(edit, "Lua 5.4")
    T.eq(edit:text(), "Lua 5.4")
    qt.QTest.key_click(edit, qt.Qt.Key_Backspace)
    T.eq(edit:text(), "Lua 5.")
end)

T.test("events: a filter written in Lua sees them and can swallow them", function()
    local edit = qt.QLineEdit()
    edit:show()

    local seen = 0
    local filter = qt.EventFilter(function(object, event)
        if event:type() == qt.QEvent.KeyPress then
            seen = seen + 1
            return event:key() == qt.Qt.Key_X -- swallow x
        end
        return false
    end)
    edit:install_event_filter(filter)

    qt.QTest.key_clicks(edit, "axb")
    T.eq(edit:text(), "ab")
    T.eq(seen, 3)
end)

T.test("signal arguments that are objects arrive as the real class", function()
    local window = qt.QWidget()
    local layout = qt.QVBoxLayout(window)
    local first, second = qt.QPushButton("first"), qt.QPushButton("second")
    second:set_flat(true)
    layout:add_widget(first)
    layout:add_widget(second)
    window:show()

    local group = qt.QButtonGroup(window)
    group:add_button(first)
    group:add_button(second)

    local seen = {}
    group:connect("buttonClicked(QAbstractButton*)", function(button)
        seen[#seen + 1] = button:text() .. (button:is_flat() and " (flat)" or "")
    end)
    qt.QTest.mouse_click(first, qt.Qt.LeftButton)
    qt.QTest.mouse_click(second, qt.Qt.LeftButton)
    T.same(seen, { "first", "second (flat)" })
end)

T.test("QAction: triggering", function()
    local action = qt.QAction("Do it")
    action:set_checkable(true)
    local triggered = {}
    action:connect("triggered", function(checked) triggered[#triggered + 1] = checked end)
    action:trigger()
    action:trigger()
    T.same(triggered, { true, false })
    T.eq(action:text(), "Do it")
end)

-- Models and views --------------------------------------------------------------------------------------

T.test("QStandardItemModel: rows, columns and data", function()
    local model = qt.QStandardItemModel(0, 2)
    for _, pair in ipairs({ { "pear", "5" }, { "apple", "3" } }) do
        model:append_row({ qt.QStandardItem(pair[1]), qt.QStandardItem(pair[2]) })
    end
    T.eq(model:row_count(), 2)
    T.eq(model:column_count(), 2)
    T.eq(model:data(model:index(0, 0)), "pear")
    T.eq(model:data(model:index(1, 1)), "3")
    T.eq(model:item(1, 0):text(), "apple")
end)

T.test("QStringListModel and QSortFilterProxyModel", function()
    local model = qt.QStringListModel({ "pear", "apple", "fig", "banana" })
    T.eq(model:row_count(), 4)
    T.same(model:string_list(), { "pear", "apple", "fig", "banana" })

    local proxy = qt.QSortFilterProxyModel()
    proxy:set_source_model(model)
    proxy:sort(0)
    local sorted = {}
    for row = 0, proxy:row_count() - 1 do sorted[#sorted + 1] = proxy:data(proxy:index(row, 0)) end
    T.same(sorted, { "apple", "banana", "fig", "pear" })

    proxy:set_filter_fixed_string("an")
    T.eq(proxy:row_count(), 1)
    T.eq(proxy:data(proxy:index(0, 0)), "banana")
end)

T.test("model signals", function()
    local model = qt.QStringListModel({ "a" })
    local inserted = 0
    model:connect("rowsInserted", function() inserted = inserted + 1 end)
    model:insert_rows(1, 2)
    T.eq(inserted, 1)
    T.eq(model:row_count(), 3)
end)

T.test("QListView with a model and a selection", function()
    local model = qt.QStringListModel({ "one", "two", "three" })
    local view = qt.QListView()
    view:set_model(model)
    view:set_current_index(model:index(1, 0))
    T.eq(view:current_index():row(), 1)
    T.eq(model:data(view:current_index()), "two")
    T.eq(view:selection_model():current_index():row(), 1)
end)

T.test("QTableWidget and QTreeWidget items", function()
    local grid = qt.QTableWidget(2, 2)
    grid:set_item(0, 1, qt.QTableWidgetItem("cell"))
    T.eq(grid:item(0, 1):text(), "cell")
    T.eq(grid:row_count(), 2)

    local tree = qt.QTreeWidget()
    local root = qt.QTreeWidgetItem(tree)
    root:set_text(0, "root")
    local child = qt.QTreeWidgetItem(root)
    child:set_text(0, "child")
    T.eq(tree:top_level_item_count(), 1)
    T.eq(root:child_count(), 1)
    T.eq(root:child(0):text(0), "child")
end)

T.test("QListWidget: items", function()
    local list = qt.QListWidget()
    list:add_items({ "x", "y", "z" })
    T.eq(list:count(), 3)
    list:set_current_row(2)
    T.eq(list:current_item():text(), "z")
    list:add_item(qt.QListWidgetItem("w"))
    T.eq(list:count(), 4)
end)

-- Grabbing ------------------------------------------------------------------------------------------

T.test("QWidget: grab renders the widget", function()
    local label = qt.QLabel("grab me")
    label:resize(120, 40)
    label:set_style_sheet("background-color: #ff0000;")
    label:show()
    local pixmap = label:grab()
    T.eq(pixmap:width(), 120)
    T.eq(pixmap:height(), 40)
end)

T.test("QApplication: screens and style", function()
    T.ok(qt.QApplication.style() ~= nil)
    T.ok(qt.QGuiApplication.primary_screen() ~= nil)
end)

T.run()
