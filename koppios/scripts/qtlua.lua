-- The Qt6 bindings on koppi/os: a window of real QtWidgets, written in Lua. Tab, the arrow keys, Space
-- and the mouse work; Esc (or the Quit button) leaves.
--
--     qtlua                  (this script, /rd/qtlua.lua)
--     qtlua /rd/other.lua
--
-- Every state change is also printed to the serial console as "qtlua: ...", which is how
-- test/qt-lua-boot.sh tells that the right widget reacted to the right input.

local qt = qt6

local function say(text)
    print("qtlua: " .. text)
end

local window = qt.QWidget()
window:set_window_title("Qt6 from Lua")

local root = qt.QVBoxLayout(window)

local title = qt.QLabel("Qt " .. qt.version() .. " from Lua")
root:add_widget(title)

local tabs = qt.QTabWidget()
root:add_widget(tabs, 1)

-- Tab 1: input and buttons -----------------------------------------------------------------------
local input = qt.QWidget()
local form = qt.QFormLayout(input)

local name = qt.QLineEdit()
name:set_placeholder_text("your name")
form:add_row("Name", name)

local age = qt.QSpinBox()
age:set_range(0, 120)
age:set_value(30)
form:add_row("Age", age)

local fruit = qt.QComboBox()
fruit:add_items({ "Apple", "Banana", "Cherry" })
form:add_row("Fruit", fruit)

local likes = qt.QCheckBox("I like Lua")
form:add_row("", likes)

local greeting = qt.QLabel("Press the button")
local greet = qt.QPushButton("Greet")
form:add_row(greet, greeting)

tabs:add_tab(input, "Input")

-- Tab 2: a slider drives a dial and a progress bar -------------------------------------------------------
local sliders = qt.QWidget()
local grid = qt.QGridLayout(sliders)

local slider = qt.QSlider(qt.Qt.Horizontal)
slider:set_range(0, 100)
local bar = qt.QProgressBar()
bar:set_range(0, 100)
local dial = qt.QDial()
dial:set_range(0, 100)
grid:add_widget(qt.QLabel("Slider"), 0, 0)
grid:add_widget(slider, 0, 1)
grid:add_widget(qt.QLabel("Progress"), 1, 0)
grid:add_widget(bar, 1, 1)
grid:add_widget(qt.QLabel("Dial"), 2, 0)
grid:add_widget(dial, 2, 1)

tabs:add_tab(sliders, "Sliders")

-- The bottom row ------------------------------------------------------------------------------------
local bottom = qt.QHBoxLayout()
local hint = qt.QLabel("Tab / arrows / Space / mouse   -   Esc quits")
local quit = qt.QPushButton("Quit")
bottom:add_widget(hint, 1)
bottom:add_widget(quit)
root:add_layout(bottom)

-- Behaviour ------------------------------------------------------------------------------------------
local greetings = 0
greet:connect("clicked", function()
    greetings = greetings + 1
    local who = name:text() ~= "" and name:text() or "stranger"
    greeting:set_text(string.format("Hello, %s! (%d, age %d, %s)", who, greetings, age:value(), fruit:current_text()))
    say("greeted " .. greetings .. " " .. greeting:text())
end)

name:connect("textChanged(QString)", function(text) say("name " .. text) end)
age:connect("valueChanged(int)", function(value) say("age " .. value) end)
fruit:connect("currentIndexChanged(int)", function(index) say("fruit " .. fruit:item_text(index)) end)
likes:connect("toggled(bool)", function(on) say("likes " .. tostring(on)) end)
tabs:connect("currentChanged(int)", function(index) say("tab " .. index) end)

slider:connect("valueChanged(int)", function(value)
    bar:set_value(value)
    dial:set_value(value)
    say("slider " .. value)
end)
dial:connect("valueChanged(int)", function(value)
    slider:set_value(value)
    say("dial " .. value)
end)
bar:connect("valueChanged(int)", function(value) say("progress " .. value) end)

-- Which widget has the keyboard
qt.QApplication.instance():connect("focusChanged(QWidget*,QWidget*)", function(_, now)
    if now then
        local what = now:meta_object():class_name()
        if what == "QPushButton" or what == "QCheckBox" then what = what .. " '" .. now:text() .. "'" end
        say("focus " .. what)
    end
end)

quit:connect("clicked", function()
    say("quit")
    qt.QCoreApplication.quit()
end)

-- Esc leaves, unless it is closing a combo box popup. A filter on the application sees the key first.
local escape = qt.EventFilter(function(object, event)
    if event:type() == qt.QEvent.KeyPress and event:key() == qt.Qt.Key_Escape
        and qt.QApplication.active_popup_widget() == nil then
        say("quit")
        qt.QCoreApplication.quit()
        return true
    end
    return false
end)
qt.QApplication.instance():install_event_filter(escape)

-- No window manager: the window fills the screen
window:set_geometry(qt.QRect(qt.QPoint(0, 0), qt.QGuiApplication.primary_screen():size()))
window:show()
say("ready tabs=" .. tabs:count())

qt.QApplication.exec()
