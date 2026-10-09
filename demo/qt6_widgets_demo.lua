-- A showcase of the Qt6 widgets from Lua: buttons, sliders, knobs (QDial), tabs, inputs, item views,
-- containers, dialogs, menus, toolbars, docks and more, wired together with signals.
--
--   demo/build/qt6_demo demo/qt6_widgets_demo.lua
--
-- With a display the window opens and stays until closed. Without one (QT_QPA_PLATFORM=offscreen) the
-- script drives the widgets itself with QTest, prints what happened and saves a screenshot of every tab.

local qt = qt6
local Qt = qt.Qt

local headless = os.getenv("QT_QPA_PLATFORM") == "offscreen"
local checks, failures = 0, 0

local function check(what, ok)
    checks = checks + 1
    if not ok then failures = failures + 1 end
    print(string.format("   [%s] %s", ok and "ok" or "FAIL", what))
end

-- Layout helpers ---------------------------------------------------------------------------------

local function page(parent_tabs, title)
    local widget = qt.QWidget()
    local layout = qt.QGridLayout(widget)
    parent_tabs:add_tab(widget, title)
    return widget, layout
end

local function group(title, layout_class)
    local box = qt.QGroupBox(title)
    local layout = (layout_class or qt.QVBoxLayout)(box)
    return box, layout
end

local function hline()
    local line = qt.QFrame()
    line:set_frame_shape(qt.QFrame.HLine)
    line:set_frame_shadow(qt.QFrame.Sunken)
    return line
end

-- Everything the self-test needs to reach later
local ui = {}

-- Main window with menus, toolbar, status bar -------------------------------------------------------

local window = qt.QMainWindow()
window:set_window_title("Qt6 widgets from Lua")
window:resize(980, 720)

local status = window:status_bar()
status:show_message("Ready", 2000)

local tabs = qt.QTabWidget()
tabs:set_movable(true)
tabs:set_document_mode(false)
tabs:set_tabs_closable(false)
window:set_central_widget(tabs)

-- Tab 1: buttons -----------------------------------------------------------------------------------------

do
    local _, grid = page(tabs, "Buttons")

    -- push buttons
    local box, v = group("QPushButton")
    local normal = qt.QPushButton("Normal")
    local default = qt.QPushButton("Default")
    default:set_default(true)
    local flat = qt.QPushButton("Flat")
    flat:set_flat(true)
    local toggle = qt.QPushButton("Toggle me")
    toggle:set_checkable(true)
    local disabled = qt.QPushButton("Disabled")
    disabled:set_enabled(false)
    local menu_button = qt.QPushButton("With menu")
    local menu = qt.QMenu()
    menu:add_action("First entry")
    menu:add_action("Second entry")
    menu:add_separator()
    menu:add_action("Third entry")
    menu_button:set_menu(menu)
    for _, b in ipairs({ normal, default, flat, toggle, disabled, menu_button }) do v:add_widget(b) end
    v:add_stretch()
    grid:add_widget(box, 0, 0)

    local clicks = 0
    normal:connect("clicked", function()
        clicks = clicks + 1
        status:show_message("Normal clicked " .. clicks .. " times", 3000)
    end)
    toggle:connect("toggled", function(on) toggle:set_text(on and "Toggled ON" or "Toggled OFF") end)
    ui.normal, ui.toggle = normal, toggle
    ui.get_clicks = function() return clicks end

    -- tool buttons
    local box2, v2 = group("QToolButton")
    local row = qt.QHBoxLayout()
    local styles = {
        { "Icon only", Qt.ToolButtonIconOnly }, { "Text only", Qt.ToolButtonTextOnly },
        { "Text beside icon", Qt.ToolButtonTextBesideIcon }, { "Text under icon", Qt.ToolButtonTextUnderIcon },
    }
    local style = window:style()
    local icon = style:standard_icon(qt.QStyle.SP_DirOpenIcon)
    for _, s in ipairs(styles) do
        local tb = qt.QToolButton()
        tb:set_text(s[1])
        tb:set_icon(icon)
        tb:set_tool_button_style(s[2])
        row:add_widget(tb)
    end
    v2:add_layout(row)
    local popup = qt.QToolButton()
    popup:set_text("Instant popup")
    popup:set_popup_mode(qt.QToolButton.InstantPopup)
    popup:set_menu(menu)
    v2:add_widget(popup)
    local arrows = qt.QHBoxLayout()
    for _, a in ipairs({ Qt.UpArrow, Qt.DownArrow, Qt.LeftArrow, Qt.RightArrow }) do
        local tb = qt.QToolButton()
        tb:set_arrow_type(a)
        arrows:add_widget(tb)
    end
    v2:add_layout(arrows)
    local link = qt.QCommandLinkButton("QCommandLinkButton", "Descriptive text below the title")
    v2:add_widget(link)
    grid:add_widget(box2, 0, 1)

    -- check boxes and radio buttons
    local box3, v3 = group("QCheckBox")
    local c1 = qt.QCheckBox("Two states")
    local c2 = qt.QCheckBox("Three states")
    c2:set_tristate(true)
    c2:set_check_state(Qt.PartiallyChecked)
    local c3 = qt.QCheckBox("Checked and disabled")
    c3:set_checked(true)
    c3:set_enabled(false)
    local summary = qt.QLabel("-")
    c1:connect("toggled", function(on) summary:set_text("two states: " .. tostring(on)) end)
    c2:connect("stateChanged", function(state)
        summary:set_text("three states: " .. ({ [0] = "unchecked", [1] = "partial", [2] = "checked" })[state])
    end)
    for _, c in ipairs({ c1, c2, c3 }) do v3:add_widget(c) end
    v3:add_widget(summary)
    grid:add_widget(box3, 1, 0)
    ui.check1, ui.check_summary = c1, summary

    local box4, v4 = group("QRadioButton in a QButtonGroup")
    local radios = qt.QButtonGroup(box4)
    local picked = qt.QLabel("nothing picked")
    for i, name in ipairs({ "Small", "Medium", "Large" }) do
        local r = qt.QRadioButton(name)
        radios:add_button(r, i)
        v4:add_widget(r)
        r:connect("toggled", function(on) if on then picked:set_text("picked " .. name) end end)
        if i == 2 then r:set_checked(true) end
        ui["radio" .. i] = r
    end
    v4:add_widget(picked)
    grid:add_widget(box4, 1, 1)
    ui.picked = picked

    -- dialog button box
    local buttons = qt.QDialogButtonBox(qt.QDialogButtonBox.Ok | qt.QDialogButtonBox.Cancel
        | qt.QDialogButtonBox.Apply | qt.QDialogButtonBox.Help)
    grid:add_widget(buttons, 2, 0, 1, 2)
    grid:set_row_stretch(3, 1)
end

-- Tab 2: sliders, knobs and numbers ------------------------------------------------------------------------

do
    local _, grid = page(tabs, "Sliders && Knobs")

    local box, v = group("QSlider")
    local h = qt.QSlider(Qt.Horizontal)
    h:set_range(0, 100)
    h:set_tick_position(qt.QSlider.TicksBelow)
    h:set_tick_interval(10)
    local h_label = qt.QLabel("0")
    h:connect("valueChanged", function(val) h_label:set_text(tostring(val)) end)
    v:add_widget(h)
    v:add_widget(h_label)
    local vs_row = qt.QHBoxLayout()
    for i = 1, 4 do
        local vs = qt.QSlider(Qt.Vertical)
        vs:set_range(0, 100)
        vs:set_value(20 * i)
        vs:set_tick_position(qt.QSlider.TicksBothSides)
        vs_row:add_widget(vs)
    end
    v:add_layout(vs_row)
    grid:add_widget(box, 0, 0, 2, 1)
    ui.slider = h

    -- knobs
    local box2, v2 = group("QDial (knobs)", qt.QGridLayout)
    local dial = qt.QDial()
    dial:set_range(0, 100)
    dial:set_notches_visible(true)
    dial:set_minimum_size(120, 120)
    local wrap = qt.QDial()
    wrap:set_range(0, 359)
    wrap:set_wrapping(true)
    wrap:set_notch_target(30)
    wrap:set_notches_visible(true)
    wrap:set_minimum_size(120, 120)
    local dial_label = qt.QLabel("0")
    dial_label:set_alignment(Qt.AlignCenter)
    local wrap_label = qt.QLabel("0°")
    wrap_label:set_alignment(Qt.AlignCenter)
    dial:connect("valueChanged", function(val) dial_label:set_text(tostring(val)) end)
    wrap:connect("valueChanged", function(val) wrap_label:set_text(val .. "°") end)
    v2:add_widget(dial, 0, 0)
    v2:add_widget(wrap, 0, 1)
    v2:add_widget(dial_label, 1, 0)
    v2:add_widget(wrap_label, 1, 1)
    grid:add_widget(box2, 0, 1)
    ui.dial, ui.dial_label = dial, dial_label

    -- LCD tied to the knob and the slider
    local box3, v3 = group("QLCDNumber")
    local lcd = qt.QLCDNumber(5)
    lcd:set_segment_style(qt.QLCDNumber.Filled)
    lcd:set_minimum_height(60)
    v3:add_widget(lcd)
    local mode = qt.QComboBox()
    mode:add_items({ "Decimal", "Hex", "Binary", "Octal" })
    local modes = { qt.QLCDNumber.Dec, qt.QLCDNumber.Hex, qt.QLCDNumber.Bin, qt.QLCDNumber.Oct }
    mode:connect("currentIndexChanged(int)", function(i) lcd:set_mode(modes[i + 1]) end)
    v3:add_widget(mode)
    dial:connect("valueChanged", function(val) lcd:display(val) end)
    grid:add_widget(box3, 1, 1)
    ui.lcd, ui.lcd_mode = lcd, mode

    -- progress, scroll bar, spin boxes
    local box4, v4 = group("QProgressBar, QScrollBar")
    local bar = qt.QProgressBar()
    bar:set_range(0, 100)
    local busy = qt.QProgressBar()
    busy:set_range(0, 0)
    local scroll = qt.QScrollBar(Qt.Horizontal)
    scroll:set_range(0, 100)
    scroll:connect("valueChanged", function(val) bar:set_value(val) end)
    h:connect("valueChanged", function(val) scroll:set_value(val) end)
    v4:add_widget(bar)
    v4:add_widget(busy)
    v4:add_widget(scroll)
    grid:add_widget(box4, 2, 0)
    ui.bar = bar

    local box5, form = group("QSpinBox, QDoubleSpinBox", qt.QFormLayout)
    local spin = qt.QSpinBox()
    spin:set_range(-50, 50)
    spin:set_prefix("T ")
    spin:set_suffix(" °C")
    spin:set_special_value_text("freezing")
    local dspin = qt.QDoubleSpinBox()
    dspin:set_range(0, 1)
    dspin:set_decimals(3)
    dspin:set_single_step(0.005)
    local spin_out = qt.QLabel("-")
    -- the double overload hands the signal text over as a string; ask the widget for the number
    spin:connect("valueChanged(int)", function() spin_out:set_text("int " .. spin:value()) end)
    dspin:connect("valueChanged(double)", function() spin_out:set_text((string.format("double %.3f", dspin:value()):gsub(",", "."))) end)
    form:add_row("Integer:", spin)
    form:add_row("Double:", dspin)
    form:add_row("Last:", spin_out)
    grid:add_widget(box5, 2, 1)
    ui.spin, ui.dspin, ui.spin_out = spin, dspin, spin_out
end

-- Tab 3: inputs --------------------------------------------------------------------------------------------

do
    local _, grid = page(tabs, "Inputs")

    local box, form = group("Line edits", qt.QFormLayout)
    local plain = qt.QLineEdit()
    plain:set_placeholder_text("plain text")
    plain:set_clear_button_enabled(true)
    local password = qt.QLineEdit()
    password:set_echo_mode(qt.QLineEdit.Password)
    password:set_placeholder_text("password")
    local number = qt.QLineEdit()
    number:set_validator(qt.QIntValidator(0, 999, number))
    number:set_placeholder_text("0 - 999 only")
    local masked = qt.QLineEdit()
    masked:set_input_mask("999.999.999.999;_")
    local completer = qt.QLineEdit()
    local words = qt.QCompleter({ "apple", "apricot", "banana", "blueberry", "cherry" }, completer)
    words:set_case_sensitivity(Qt.CaseInsensitive)
    completer:set_completer(words)
    completer:set_placeholder_text("type 'a' or 'b'")
    local echo = qt.QLabel("-")
    plain:connect("textChanged", function(text) echo:set_text("typed: " .. text) end)
    form:add_row("Plain:", plain)
    form:add_row("Password:", password)
    form:add_row("Validated:", number)
    form:add_row("Masked:", masked)
    form:add_row("Completer:", completer)
    form:add_row("Echo:", echo)
    grid:add_widget(box, 0, 0)
    ui.plain, ui.number, ui.echo = plain, number, echo

    local box2, form2 = group("Choices", qt.QFormLayout)
    local combo = qt.QComboBox()
    combo:add_items({ "Red", "Green", "Blue" })
    local editable = qt.QComboBox()
    editable:set_editable(true)
    editable:add_items({ "One", "Two", "Three" })
    local fonts = qt.QFontComboBox()
    local combo_out = qt.QLabel("Red")
    combo:connect("currentTextChanged", function(text) combo_out:set_text(text) end)
    form2:add_row("QComboBox:", combo)
    form2:add_row("Editable:", editable)
    form2:add_row("Fonts:", fonts)
    form2:add_row("Selected:", combo_out)
    grid:add_widget(box2, 0, 1)
    ui.combo, ui.combo_out = combo, combo_out

    local box3, form3 = group("Date and time", qt.QFormLayout)
    local date = qt.QDateEdit(qt.QDate(2026, 10, 9))
    date:set_calendar_popup(true)
    date:set_display_format("dddd, d MMMM yyyy")
    local time = qt.QTimeEdit(qt.QTime(13, 37, 0))
    local both = qt.QDateTimeEdit(qt.QDateTime.current_date_time())
    both:set_calendar_popup(true)
    local keys = qt.QKeySequenceEdit()
    form3:add_row("QDateEdit:", date)
    form3:add_row("QTimeEdit:", time)
    form3:add_row("QDateTimeEdit:", both)
    form3:add_row("Shortcut:", keys)
    grid:add_widget(box3, 1, 0)
    ui.date = date

    local box4, v4 = group("Text editors")
    local text = qt.QTextEdit()
    text:set_html("<h3>Rich text</h3><p>This is <b>bold</b>, <i>italic</i> and <span style='color:#c0392b'>colored</span>.</p>")
    local source = qt.QPlainTextEdit()
    source:set_plain_text("-- plain text\nprint('hello')")
    source:set_line_wrap_mode(qt.QPlainTextEdit.NoWrap)
    local counter = qt.QLabel("")
    local function update_counter()
        counter:set_text(string.format("%d characters, %d lines", #source:to_plain_text(), source:block_count()))
    end
    source:connect("textChanged", update_counter)
    update_counter()
    v4:add_widget(text)
    v4:add_widget(source)
    v4:add_widget(counter)
    grid:add_widget(box4, 1, 1)
    ui.source, ui.counter = source, counter
end

-- Tab 4: item views -----------------------------------------------------------------------------------------

do
    local _, grid = page(tabs, "Item views")

    local list = qt.QListWidget()
    for _, name in ipairs({ "Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune" }) do
        local item = qt.QListWidgetItem(name)
        item:set_flags(item:flags() | Qt.ItemIsUserCheckable)
        item:set_check_state(Qt.Unchecked)
        list:add_item(item)
    end
    list:set_alternating_row_colors(true)
    local list_out = qt.QLabel("select a planet")
    list:connect("currentTextChanged", function(text) list_out:set_text("selected " .. text) end)
    local lbox, lv = group("QListWidget")
    lv:add_widget(list)
    lv:add_widget(list_out)
    grid:add_widget(lbox, 0, 0)
    ui.list, ui.list_out = list, list_out

    local tree = qt.QTreeWidget()
    tree:set_header_labels({ "Name", "Kind" })
    local function node(parent, name, kind)
        local item = qt.QTreeWidgetItem(parent)
        item:set_text(0, name)
        item:set_text(1, kind)
        return item
    end
    local root = qt.QTreeWidgetItem(tree)
    root:set_text(0, "Widgets")
    root:set_text(1, "root")
    for _, group_def in ipairs({
        { "Buttons", { "QPushButton", "QToolButton", "QRadioButton", "QCheckBox" } },
        { "Inputs", { "QLineEdit", "QSpinBox", "QSlider", "QDial" } },
        { "Containers", { "QTabWidget", "QToolBox", "QSplitter" } },
    }) do
        local g = node(root, group_def[1], "group")
        for _, w in ipairs(group_def[2]) do node(g, w, "class") end
    end
    tree:expand_all()
    local tbox, tv = group("QTreeWidget")
    tv:add_widget(tree)
    grid:add_widget(tbox, 0, 1)
    ui.tree = tree

    local table_widget = qt.QTableWidget(4, 3)
    table_widget:set_horizontal_header_labels({ "Item", "Qty", "Price" })
    local rows = { { "Lua", 1, 0.0 }, { "Qt", 2, 9.5 }, { "Bridge", 3, 4.25 }, { "Moon", 4, 3.14 } }
    for r, row in ipairs(rows) do
        for c, value in ipairs(row) do
            table_widget:set_item(r - 1, c - 1, qt.QTableWidgetItem(tostring(value)))
        end
    end
    table_widget:horizontal_header():set_stretch_last_section(true)
    local tabbox, tabv = group("QTableWidget")
    tabv:add_widget(table_widget)
    grid:add_widget(tabbox, 1, 0)
    ui.table = table_widget

    -- model + proxy + view, with a live filter
    local model = qt.QStandardItemModel()
    for _, name in ipairs({ "pear", "apple", "fig", "banana", "cherry", "grape", "kiwi" }) do
        model:append_row(qt.QStandardItem(name))
    end
    local proxy = qt.QSortFilterProxyModel()
    proxy:set_source_model(model)
    proxy:set_filter_case_sensitivity(Qt.CaseInsensitive)
    proxy:sort(0)
    local view = qt.QListView()
    view:set_model(proxy)
    local filter = qt.QLineEdit()
    filter:set_placeholder_text("filter the model")
    filter:connect("textChanged", function(text) proxy:set_filter_fixed_string(text) end)
    local mbox, mv = group("QStandardItemModel + QSortFilterProxyModel")
    mv:add_widget(filter)
    mv:add_widget(view)
    grid:add_widget(mbox, 1, 1)
    ui.model, ui.proxy, ui.view, ui.filter = model, proxy, view, filter
end

-- Tab 5: containers ------------------------------------------------------------------------------------------

do
    local _, grid = page(tabs, "Containers")

    local toolbox = qt.QToolBox()
    for _, title in ipairs({ "First section", "Second section", "Third section" }) do
        local label = qt.QLabel("Contents of the " .. title:lower())
        label:set_alignment(Qt.AlignCenter)
        toolbox:add_item(label, title)
    end
    local tbox, tv = group("QToolBox")
    tv:add_widget(toolbox)
    grid:add_widget(tbox, 0, 0)
    ui.toolbox = toolbox

    local stack = qt.QStackedWidget()
    for _, color in ipairs({ "#e74c3c", "#27ae60", "#2980b9" }) do
        local label = qt.QLabel(color)
        label:set_alignment(Qt.AlignCenter)
        label:set_auto_fill_background(true)
        label:set_style_sheet("background-color: " .. color .. "; color: white; font-size: 20px;")
        stack:add_widget(label)
    end
    local flip = qt.QComboBox()
    flip:add_items({ "Red page", "Green page", "Blue page" })
    flip:connect("currentIndexChanged(int)", function(i) stack:set_current_index(i) end)
    local sbox, sv = group("QStackedWidget")
    sv:add_widget(flip)
    sv:add_widget(stack)
    grid:add_widget(sbox, 0, 1)
    ui.stack, ui.flip = stack, flip

    local splitter = qt.QSplitter(Qt.Horizontal)
    splitter:add_widget(qt.QTextEdit("left pane"))
    local inner = qt.QSplitter(Qt.Vertical)
    inner:add_widget(qt.QTextEdit("top right"))
    inner:add_widget(qt.QTextEdit("bottom right"))
    splitter:add_widget(inner)
    local spbox, spv = group("QSplitter (drag the handles)")
    spv:add_widget(splitter)
    grid:add_widget(spbox, 1, 0)

    local scroll = qt.QScrollArea()
    local content = qt.QWidget()
    local cl = qt.QVBoxLayout(content)
    for i = 1, 20 do cl:add_widget(qt.QCheckBox("Scrollable entry " .. i)) end
    scroll:set_widget(content)
    local scbox, scv = group("QScrollArea")
    scv:add_widget(scroll)
    grid:add_widget(scbox, 1, 1)

    local calendar = qt.QCalendarWidget()
    calendar:set_grid_visible(true)
    local cal_out = qt.QLabel("")
    calendar:connect("selectionChanged", function()
        cal_out:set_text(calendar:selected_date():to_string("yyyy-MM-dd"))
    end)
    local cbox, cv = group("QCalendarWidget")
    cv:add_widget(calendar)
    cv:add_widget(cal_out)
    grid:add_widget(cbox, 0, 2, 2, 1)
    ui.calendar, ui.cal_out = calendar, cal_out
end

-- Tab 6: tab bar variants and MDI --------------------------------------------------------------------------

do
    local _, grid = page(tabs, "Tabs && MDI")

    local function sample(shape, position, closable)
        local t = qt.QTabWidget()
        t:set_tab_position(position)
        t:set_tab_shape(shape)
        t:set_tabs_closable(closable)
        for i = 1, 3 do t:add_tab(qt.QLabel("page " .. i), "Tab " .. i) end
        return t
    end
    local north, nv = group("QTabWidget North, closable")
    nv:add_widget(sample(qt.QTabWidget.Rounded, qt.QTabWidget.North, true))
    local south, sv = group("South, triangular")
    sv:add_widget(sample(qt.QTabWidget.Triangular, qt.QTabWidget.South, false))
    local west, wv = group("West")
    wv:add_widget(sample(qt.QTabWidget.Rounded, qt.QTabWidget.West, false))
    local east, ev = group("East")
    ev:add_widget(sample(qt.QTabWidget.Rounded, qt.QTabWidget.East, false))
    grid:add_widget(north, 0, 0)
    grid:add_widget(south, 0, 1)
    grid:add_widget(west, 1, 0)
    grid:add_widget(east, 1, 1)

    local mdi = qt.QMdiArea()
    for i = 1, 2 do
        local sub = qt.QMdiSubWindow()
        sub:set_window_title("Sub window " .. i)
        sub:set_widget(qt.QTextEdit("MDI child " .. i))
        mdi:add_sub_window(sub)
        sub:resize(220, 120)
        sub:show()
    end
    mdi:tile_sub_windows()
    local mbox, mv = group("QMdiArea")
    mv:add_widget(mdi)
    grid:add_widget(mbox, 2, 0, 1, 2)
    ui.mdi = mdi
end

-- Tab 7: dialogs and misc ----------------------------------------------------------------------------------------

do
    local _, grid = page(tabs, "Dialogs && Misc")

    local box, v = group("Standard dialogs (open interactively)")
    local dialogs = {
        { "QMessageBox", function()
            return qt.QMessageBox.information(window, "Hello", "A QMessageBox from Lua") end },
        { "QInputDialog (text)", function()
            return qt.QInputDialog.get_text(window, "Input", "Your name:") end },
        { "QInputDialog (int)", function()
            return qt.QInputDialog.get_int(window, "Input", "A number:", 5, 0, 10) end },
        { "QColorDialog", function() return qt.QColorDialog.get_color(qt.QColor("orange"), window) end },
        { "QFontDialog", function() return qt.QFontDialog.get_font(window) end },
        { "QFileDialog", function() return qt.QFileDialog.get_open_file_name(window, "Open") end },
    }
    for _, d in ipairs(dialogs) do
        local b = qt.QPushButton(d[1])
        b:connect("clicked", function()
            if headless then
                status:show_message(d[1] .. " needs a display", 2000)
            else
                d[2]()
            end
        end)
        v:add_widget(b)
    end
    v:add_stretch()
    grid:add_widget(box, 0, 0)

    local box2, v2 = group("QLabel, QFrame, QTextBrowser")
    local rich = qt.QLabel("<a href='https://doc.qt.io/qt-6/'>Qt 6 documentation</a> with <b>rich</b> text")
    rich:set_open_external_links(false)
    rich:set_text_format(Qt.RichText)
    local pixmap = qt.QPixmap(200, 40)
    pixmap:fill(qt.QColor("transparent"))
    local painter = qt.QPainter(pixmap)
    painter:set_render_hint(qt.QPainter.Antialiasing, true)
    local gradient = qt.QLinearGradient(0, 0, 200, 0)
    gradient:set_color_at(0, qt.QColor("#e74c3c"))
    gradient:set_color_at(0.5, qt.QColor("#f1c40f"))
    gradient:set_color_at(1, qt.QColor("#2980b9"))
    painter:fill_rect(0, 0, 200, 40, qt.QBrush(gradient))
    painter:set_pen(qt.QColor("white"))
    painter:draw_text(10, 26, "QPixmap painted in Lua")
    painter:end_()
    local image_label = qt.QLabel()
    image_label:set_pixmap(pixmap)
    local frame = qt.QFrame()
    frame:set_frame_style(qt.QFrame.Box | qt.QFrame.Raised)
    frame:set_line_width(3)
    local fl = qt.QVBoxLayout(frame)
    fl:add_widget(qt.QLabel("A raised QFrame"))
    local browser = qt.QTextBrowser()
    browser:set_html("<h4>QTextBrowser</h4><ul><li>read-only</li><li>follows links</li></ul>")
    v2:add_widget(rich)
    v2:add_widget(image_label)
    v2:add_widget(frame)
    v2:add_widget(browser)
    grid:add_widget(box2, 0, 1)

    local box3, v3 = group("Tool tips, status tips, focus")
    local tip = qt.QPushButton("Hover me")
    tip:set_tool_tip("This is a tooltip")
    tip:set_status_tip("This is a status tip shown in the status bar")
    tip:set_whats_this("What's this help text")
    local group_edit = qt.QLineEdit()
    group_edit:set_placeholder_text("Tab order: this is first")
    local second = qt.QLineEdit()
    second:set_placeholder_text("second")
    local progress = qt.QProgressBar()
    progress:set_range(0, 100)
    local timer = qt.QTimer()
    timer:set_interval(80)
    timer:connect("timeout", function()
        progress:set_value((progress:value() + 1) % 101)
    end)
    local run = qt.QPushButton("Animate progress with QTimer")
    run:set_checkable(true)
    run:connect("toggled", function(on) if on then timer:start() else timer:stop() end end)
    v3:add_widget(tip)
    v3:add_widget(group_edit)
    v3:add_widget(second)
    v3:add_widget(progress)
    v3:add_widget(run)
    v3:add_stretch()
    grid:add_widget(box3, 1, 0, 1, 2)
    qt.QWidget.set_tab_order(group_edit, second) -- both must be in the same window by now
    ui.timer, ui.run, ui.progress = timer, run, progress
end

-- Actions, menus and toolbar ----------------------------------------------------------------------------------

local menubar = window:menu_bar()
local file_menu = menubar:add_menu("&File")
local view_menu = menubar:add_menu("&View")
local help_menu = menubar:add_menu("&Help")

local action_log = {}
local function action(menu, text, shortcut, fn)
    local a = qt.QAction(text, window)
    if shortcut then a:set_shortcut(qt.QKeySequence(shortcut)) end
    a:connect("triggered", function() fn(a) end)
    menu:add_action(a)
    return a
end

local new_action = action(file_menu, "&New", "Ctrl+N", function() action_log[#action_log + 1] = "new" end)
local open_action = action(file_menu, "&Open...", "Ctrl+O", function() action_log[#action_log + 1] = "open" end)
file_menu:add_separator()
action(file_menu, "&Quit", "Ctrl+Q", function() qt.QApplication.quit() end)

local dark = action(view_menu, "&Dark theme", nil, function(a)
    if a:is_checked() then
        window:set_style_sheet("QMainWindow, QWidget { background: #2b2b2b; color: #dddddd; } "
            .. "QGroupBox { border: 1px solid #555; margin-top: 8px; padding-top: 8px; } "
            .. "QGroupBox::title { subcontrol-origin: margin; left: 8px; }")
    else
        window:set_style_sheet("")
    end
end)
dark:set_checkable(true)
local styles_menu = view_menu:add_menu("&Style")
local style_group = qt.QActionGroup(window)
style_group:set_exclusive(true)
for _, name in ipairs(qt.QStyleFactory.keys()) do
    local a = styles_menu:add_action(name)
    a:set_checkable(true)
    style_group:add_action(a)
    a:connect("triggered", function() qt.QApplication.set_style(name) end)
end
action(help_menu, "&About Qt", nil, function()
    if not headless then qt.QMessageBox.about_qt(window) end
end)

local toolbar = window:add_tool_bar("Main")
toolbar:add_action(new_action)
toolbar:add_action(open_action)
toolbar:add_separator()
local zoom = qt.QSpinBox()
zoom:set_range(10, 400)
zoom:set_value(100)
zoom:set_suffix("%")
toolbar:add_widget(qt.QLabel(" Zoom: "))
toolbar:add_widget(zoom)

-- Dock widget with a live "signal log" ---------------------------------------------------------------------------

local dock = qt.QDockWidget("Signal log", window)
local log = qt.QPlainTextEdit()
log:set_read_only(true)
log:set_maximum_block_count(200)
dock:set_widget(log)
window:add_dock_widget(Qt.RightDockWidgetArea, dock)
view_menu:add_action(dock:toggle_view_action())

local function note(text) log:append_plain_text(text) end
ui.slider:connect("valueChanged", function(v) note("slider -> " .. v) end)
ui.dial:connect("valueChanged", function(v) note("dial -> " .. v) end)
ui.normal:connect("clicked", function() note("push button clicked") end)
tabs:connect("currentChanged", function(i) note("tab -> " .. tabs:tab_text(i)) end)
status:add_permanent_widget(qt.QLabel("Qt " .. qt.version()))

-- Run --------------------------------------------------------------------------------------------------------

window:show()

if not headless then
    qt.QApplication.exec()
    return
end

-- Headless: drive the widgets with QTest and check what the signals did -----------------------------------

print("=== Qt6 widgets showcase (headless self-test) ===")
print(string.format("   %d tabs: %s", tabs:count(), (function()
    local names = {}
    for i = 0, tabs:count() - 1 do names[#names + 1] = tabs:tab_text(i) end
    return table.concat(names, ", ")
end)()))

print()
print("Buttons")
qt.QTest.mouse_click(ui.normal, Qt.LeftButton)
qt.QTest.mouse_click(ui.normal, Qt.LeftButton)
check("push button clicked twice", ui.get_clicks() == 2)
qt.QTest.mouse_click(ui.toggle, Qt.LeftButton)
check("toggle button is checked and relabelled", ui.toggle:is_checked() and ui.toggle:text() == "Toggled ON")
ui.check1:set_checked(true)
check("check box updates its label", ui.check_summary:text() == "two states: true")
ui.radio3:set_checked(true)
check("radio group follows the selection", ui.picked:text() == "picked Large" and not ui.radio2:is_checked())

print()
print("Sliders and knobs")
ui.slider:set_value(42)
check("slider drives the progress bar", ui.bar:value() == 42)
qt.QTest.key_click(ui.slider, Qt.Key_Right)
check("slider reacts to the keyboard", ui.slider:value() == 43)
ui.dial:set_value(77)
check("knob drives its label and the LCD", ui.dial_label:text() == "77" and ui.lcd:int_value() == 77)
ui.lcd_mode:set_current_index(1)
check("LCD switches to hexadecimal", ui.lcd:mode() == qt.QLCDNumber.Hex)
ui.spin:set_value(-12)
ui.dspin:set_value(0.125)
check("spin boxes report through signals", ui.spin_out:text() == "double 0.125" and ui.spin:value() == -12)
ui.spin:set_value(-50)
check("spin box clamps and keeps the range", ui.spin:minimum() == -50 and ui.spin:value() == -50)

print()
print("Inputs")
qt.QTest.key_clicks(ui.plain, "hello")
check("line edit echoes typed text", ui.echo:text() == "typed: hello")
qt.QTest.key_clicks(ui.number, "12ab3")
check("validator rejects letters", ui.number:text() == "123")
ui.combo:set_current_index(2)
check("combo box reports its text", ui.combo_out:text() == "Blue")
ui.source:set_plain_text("a\nb\nc")
check("plain text edit counter", ui.counter:text() == "5 characters, 3 lines")
check("date edit holds the date", ui.date:date():to_string("yyyy-MM-dd") == "2026-10-09")

print()
print("Item views")
ui.list:set_current_row(2)
check("list widget selection", ui.list_out:text() == "selected Earth")
check("tree widget has the top level item", ui.tree:top_level_item_count() == 1)
check("table widget keeps its cells", ui.table:item(1, 0):text() == "Qt")
ui.filter:set_text("an")
check("filter proxy keeps matching rows", ui.proxy:row_count() == 1 and ui.proxy:data(ui.proxy:index(0, 0)) == "banana")
ui.filter:set_text("")
check("filter proxy shows all rows again", ui.proxy:row_count() == 7)

print()
print("Containers")
ui.flip:set_current_index(2)
check("stacked widget flips page", ui.stack:current_index() == 2)
ui.toolbox:set_current_index(1)
check("tool box opens section", ui.toolbox:current_index() == 1)
ui.calendar:set_selected_date(qt.QDate(2027, 1, 17))
check("calendar reports selection", ui.cal_out:text() == "2027-01-17")
check("mdi area holds two windows", #ui.mdi:sub_window_list() == 2)

print()
print("Misc")
ui.run:toggle()
check("timer starts with its button", ui.timer:is_active())
local loop = qt.QEventLoop()
local wait = qt.QTimer()
wait:set_single_shot(true)
wait:connect("timeout", function() loop:quit() end)
wait:start(400)
loop:exec()
check("timer advanced the progress bar", ui.progress:value() > 0)
ui.run:toggle()
check("timer stops with its button", not ui.timer:is_active())
new_action:trigger()
check("menu action triggers", action_log[1] == "new")
dark:trigger()
check("dark theme action applies a style sheet", window:style_sheet() ~= "")
dark:trigger()
check("... and removes it again", window:style_sheet() == "")
check("signal log collected events", log:block_count() >= 5)

-- A screenshot of every tab
print()
print("Screenshots")
local dir = qt.QDir.temp_path()
for i = 0, tabs:count() - 1 do
    tabs:set_current_index(i)
    local name = tabs:tab_text(i):gsub("[^%w]+", "_"):lower()
    local path = string.format("%s/qt6_widgets_%d_%s.png", dir, i + 1, name)
    check("saved " .. path, window:grab():save(path))
end

print()
print(string.format("=== %d checks, %d failed ===", checks, failures))
if failures > 0 then error(failures .. " checks failed") end
