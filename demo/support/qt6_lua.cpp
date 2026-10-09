#include "qt6_lua.h"

#include <QtGui/QtGui>
#include <QtWidgets/QtWidgets>

#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace qt6 {

using luabridge::LuaRef;
using luabridge::Result;
using luabridge::TypeResult;

namespace {

// ------------------------------------------------------------------------------------------
// Per Lua state data: what has to outlive the script and be released with the state
// ------------------------------------------------------------------------------------------

class SlotProxy;
class LuaEventFilter;

struct ApplicationHolder
{
    std::vector<QByteArray> storage;
    std::vector<char*> argv;
    int argc = 0;
    std::unique_ptr<QCoreApplication> application;
};

struct StateData
{
    std::unique_ptr<ApplicationHolder> application;
    std::vector<QPointer<SlotProxy>> proxies;
    std::vector<QPointer<LuaEventFilter>> filters;

    ~StateData();
};

constexpr const char* stateKey = "qt6.state";

int collectStateData(lua_State* L)
{
    static_cast<StateData*>(lua_touserdata(L, 1))->~StateData();
    return 0;
}

StateData& stateData(lua_State* L)
{
    lua_getfield(L, LUA_REGISTRYINDEX, stateKey);
    if (lua_isnil(L, -1))
    {
        lua_pop(L, 1);

        void* memory = lua_newuserdata(L, sizeof(StateData));
        new (memory) StateData();

        lua_newtable(L);
        lua_pushcfunction(L, &collectStateData);
        lua_setfield(L, -2, "__gc");
        lua_setmetatable(L, -2);

        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, stateKey);
    }

    auto* data = static_cast<StateData*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return *data;
}

lua_State* mainThread(lua_State* L)
{
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
    lua_State* main = lua_tothread(L, -1);
    lua_pop(L, 1);
    return main ? main : L;
}

// ------------------------------------------------------------------------------------------
// Dynamic type of QObjects
// ------------------------------------------------------------------------------------------

/** Pushes the class table registered for `className` in qt6, or nil. */
bool pushRegisteredClass(lua_State* L, const char* className)
{
    lua_getglobal(L, "qt6");
    if (!lua_istable(L, -1))
    {
        lua_pop(L, 1);
        return false;
    }

    lua_pushstring(L, className);
    lua_rawget(L, -2); // the static table of the class
    lua_remove(L, -2);

    if (!lua_istable(L, -1) || !lua_getmetatable(L, -1))
    {
        lua_pop(L, 1);
        return false;
    }

    lua_remove(L, -2); // the metatable of the static table refers to the class table
    lua_rawgetp(L, -1, luabridge::detail::getClassKey());
    lua_remove(L, -2);

    if (!lua_istable(L, -1))
    {
        lua_pop(L, 1);
        return false;
    }

    return true;
}

/**
 * Gives the userdata at `index` the metatable of `className` (keeping its constness).
 * Returns false when that class is not registered or the object already is one.
 */
bool rebind(lua_State* L, int index, const char* className)
{
    index = lua_absindex(L, index);
    const int top = lua_gettop(L);

    if (!lua_getmetatable(L, index))
        return false;

    const int current = lua_gettop(L);

    if (!pushRegisteredClass(L, className))
    {
        lua_settop(L, top);
        return false;
    }

    const int target = lua_gettop(L);

    // The metatable of a non-const pointer knows its const twin, the other way round it does not
    lua_rawgetp(L, current, luabridge::detail::getConstKey());
    const bool isConst = lua_isnil(L, -1);
    lua_pop(L, 1);

    if (isConst)
    {
        lua_rawgetp(L, target, luabridge::detail::getConstKey());
        lua_replace(L, target);
    }

    const bool changed = !lua_rawequal(L, current, target);
    if (changed)
    {
        lua_pushvalue(L, target);
        lua_setmetatable(L, index);
    }

    lua_settop(L, top);
    return changed;
}

Result pushObject(lua_State* L, QObject* object)
{
    return luabridge::Stack<QObject*>::push(L, object); // the real class, see PointerStack
}

// ------------------------------------------------------------------------------------------
// QVariant <-> Lua
// ------------------------------------------------------------------------------------------

struct VariantConverter
{
    int typeId;
    Result (*push)(lua_State*, const QVariant&);
    bool (*match)(lua_State*, int, QVariant&);
};

std::vector<VariantConverter>& variantConverters()
{
    static std::vector<VariantConverter> converters;
    return converters;
}

/** Lets QVariant carry an instance of the bound value class T to and from Lua. */
template <class T>
void registerVariantType()
{
    variantConverters().push_back(VariantConverter{
        QMetaType::fromType<T>().id(),
        [](lua_State* L, const QVariant& value) { return luabridge::Stack<T>::push(L, value.value<T>()); },
        [](lua_State* L, int index, QVariant& out)
        {
            if (!luabridge::isInstance<T>(L, index))
                return false;

            auto value = luabridge::Stack<T>::get(L, index);
            if (!value)
                return false;

            out = QVariant::fromValue(*value);
            return true;
        } });
}

bool isSequence(lua_State* L, int table)
{
    const lua_Integer length = static_cast<lua_Integer>(lua_rawlen(L, table));

    lua_Integer count = 0;
    lua_pushnil(L);
    while (lua_next(L, table) != 0)
    {
        lua_pop(L, 1);
        ++count;
    }

    return count == length;
}

} // namespace

Result pushVariant(lua_State* L, const QVariant& value)
{
    switch (value.typeId())
    {
    case QMetaType::UnknownType:
    case QMetaType::Nullptr:
    case QMetaType::Void:
        lua_pushnil(L);
        return {};

    case QMetaType::Bool:
        lua_pushboolean(L, value.toBool());
        return {};

    case QMetaType::Int:
    case QMetaType::UInt:
    case QMetaType::Long:
    case QMetaType::LongLong:
    case QMetaType::Short:
    case QMetaType::Char:
    case QMetaType::SChar:
    case QMetaType::UChar:
    case QMetaType::UShort:
        lua_pushinteger(L, static_cast<lua_Integer>(value.toLongLong()));
        return {};

    case QMetaType::ULong:
    case QMetaType::ULongLong:
        lua_pushinteger(L, static_cast<lua_Integer>(value.toULongLong()));
        return {};

    case QMetaType::Double:
    case QMetaType::Float:
        lua_pushnumber(L, value.toDouble());
        return {};

    case QMetaType::QString:
    case QMetaType::QChar:
    case QMetaType::QByteArray:
        return luabridge::Stack<QString>::push(L, value.toString());

    case QMetaType::QStringList:
        return luabridge::Stack<QStringList>::push(L, value.toStringList());

    case QMetaType::QVariantList:
        return luabridge::Stack<QVariantList>::push(L, value.toList());

    case QMetaType::QVariantMap:
        return luabridge::Stack<QVariantMap>::push(L, value.toMap());

    case QMetaType::QVariantHash:
        return luabridge::Stack<QVariantHash>::push(L, value.toHash());

    case QMetaType::QObjectStar:
        return pushObject(L, value.value<QObject*>());

    default:
        break;
    }

    for (const VariantConverter& converter : variantConverters())
    {
        if (converter.typeId != value.typeId())
            continue;

        const int top = lua_gettop(L);
        if (converter.push(L, value))
            return {};

        lua_settop(L, top);
    }

    // Anything else reads best as text (QUrl, QDate, QColor, ...)
    if (value.canConvert<QString>())
        return luabridge::Stack<QString>::push(L, value.toString());

    lua_pushnil(L);
    return {};
}

TypeResult<QVariant> getVariant(lua_State* L, int index)
{
    switch (lua_type(L, index))
    {
    case LUA_TNIL:
    case LUA_TNONE:
        return QVariant();

    case LUA_TBOOLEAN:
        return QVariant(static_cast<bool>(lua_toboolean(L, index)));

    case LUA_TNUMBER:
    {
        if (lua_isinteger(L, index))
        {
            const lua_Integer integer = lua_tointeger(L, index);
            if (integer >= std::numeric_limits<int>::min() && integer <= std::numeric_limits<int>::max())
                return QVariant(static_cast<int>(integer));

            return QVariant(static_cast<qlonglong>(integer));
        }

        return QVariant(static_cast<double>(lua_tonumber(L, index)));
    }

    case LUA_TSTRING:
    {
        auto text = luabridge::Stack<QString>::get(L, index);
        if (!text)
            return text.error();

        return QVariant(*text);
    }

    case LUA_TTABLE:
    {
        const int table = lua_absindex(L, index);

        if (isSequence(L, table))
        {
            auto list = luabridge::Stack<QVariantList>::get(L, table);
            if (!list)
                return list.error();

            return QVariant(*list);
        }

        auto map = luabridge::Stack<QVariantMap>::get(L, table);
        if (!map)
            return map.error();

        return QVariant(*map);
    }

    case LUA_TUSERDATA:
    {
        QVariant converted;
        for (const VariantConverter& converter : variantConverters())
        {
            if (converter.match(L, index, converted))
                return converted;
        }

        if (luabridge::isInstance<QObject>(L, index))
        {
            auto object = luabridge::Stack<QObject*>::get(L, index);
            if (!object)
                return object.error();

            return QVariant::fromValue(*object);
        }
        break;
    }

    default:
        break;
    }

    return luabridge::makeErrorCode(luabridge::ErrorCode::InvalidTypeCast);
}

const char* dynamicClassName(lua_State* L, const QObject& object)
{
    for (const QMetaObject* meta = object.metaObject(); meta != nullptr; meta = meta->superClass())
    {
        if (pushRegisteredClass(L, meta->className()))
        {
            lua_pop(L, 1);
            return meta->className();
        }
    }

    return nullptr;
}

const char* dynamicClassName(lua_State*, const QEvent& event)
{
    switch (event.type())
    {
    case QEvent::KeyPress:
    case QEvent::KeyRelease:
    case QEvent::ShortcutOverride:
        return "QKeyEvent";
    case QEvent::MouseButtonPress:
    case QEvent::MouseButtonRelease:
    case QEvent::MouseButtonDblClick:
    case QEvent::MouseMove:
        return "QMouseEvent";
    case QEvent::Wheel:
        return "QWheelEvent";
    case QEvent::Resize:
        return "QResizeEvent";
    case QEvent::Move:
        return "QMoveEvent";
    case QEvent::Paint:
        return "QPaintEvent";
    case QEvent::Close:
        return "QCloseEvent";
    case QEvent::Show:
        return "QShowEvent";
    case QEvent::Hide:
        return "QHideEvent";
    case QEvent::Timer:
        return "QTimerEvent";
    case QEvent::FocusIn:
    case QEvent::FocusOut:
        return "QFocusEvent";
    case QEvent::Enter:
        return "QEnterEvent";
    case QEvent::ContextMenu:
        return "QContextMenuEvent";
    case QEvent::HoverEnter:
    case QEvent::HoverLeave:
    case QEvent::HoverMove:
        return "QHoverEvent";
    case QEvent::DragEnter:
        return "QDragEnterEvent";
    case QEvent::DragMove:
        return "QDragMoveEvent";
    case QEvent::Drop:
        return "QDropEvent";
    case QEvent::InputMethod:
        return "QInputMethodEvent";
    case QEvent::TouchBegin:
    case QEvent::TouchUpdate:
    case QEvent::TouchEnd:
    case QEvent::TouchCancel:
        return "QTouchEvent";
    case QEvent::ChildAdded:
    case QEvent::ChildPolished:
    case QEvent::ChildRemoved:
        return "QChildEvent";
    case QEvent::ActionAdded:
    case QEvent::ActionChanged:
    case QEvent::ActionRemoved:
        return "QActionEvent";
    default:
        return nullptr;
    }
}

bool refine(lua_State* L, int index, const char* className)
{
    return rebind(L, index, className);
}

void aliasStatic(lua_State* L, const char* className, const char* name)
{
    const int top = lua_gettop(L);

    lua_getglobal(L, "qt6");
    if (lua_istable(L, -1))
    {
        lua_pushstring(L, className);
        lua_rawget(L, -2); // the static table of the class
        if (lua_istable(L, -1))
        {
            lua_getfield(L, -1, (std::string(name) + "__static").c_str());
            if (lua_isfunction(L, -1))
            {
                lua_pushstring(L, name);
                lua_pushvalue(L, -2);
                lua_rawset(L, -4); // a plain entry is found before the instance methods are looked at
            }
        }
    }

    lua_settop(L, top);
}

namespace {

// ------------------------------------------------------------------------------------------
// Signals
// ------------------------------------------------------------------------------------------

/**
 * A QObject that receives one signal and calls a Lua function. It is connected by index to
 * the first method id after those of QObject and answers in qt_metacall, which is how
 * QSignalSpy works too: a slot that no moc generated.
 */
class SlotProxy final : public QObject
{
public:
    SlotProxy(QObject* sender, const QMetaMethod& signal, lua_State* L, int reference)
        : QObject(sender)
        , m_signal(signal)
        , m_L(mainThread(L))
        , m_reference(reference)
    {
    }

    ~SlotProxy() override { release(); }

    /** The Lua state is going away: the function can no longer be called or released. */
    void detach() { m_L = nullptr; }

    int qt_metacall(QMetaObject::Call call, int id, void** arguments) override
    {
        id = QObject::qt_metacall(call, id, arguments);
        if (id < 0)
            return id;

        if (call == QMetaObject::InvokeMetaMethod)
        {
            if (id == 0)
                invoke(arguments);

            --id;
        }

        return id;
    }

    static int slotId() { return QObject::staticMetaObject.methodCount(); }

private:
    void release()
    {
        if (m_L != nullptr && m_reference != LUA_NOREF)
            luaL_unref(m_L, LUA_REGISTRYINDEX, m_reference);

        m_reference = LUA_NOREF;
    }

    void invoke(void** arguments)
    {
        if (m_L == nullptr)
            return;

        lua_State* L = m_L;
        const int top = lua_gettop(L);

        lua_rawgeti(L, LUA_REGISTRYINDEX, m_reference);
        int count = 0;

        for (int i = 0; i < m_signal.parameterCount(); ++i)
        {
            const QMetaType type = m_signal.parameterMetaType(i);

            Result pushed;
            if (type.flags().testFlag(QMetaType::PointerToQObject))
                pushed = pushObject(L, *static_cast<QObject**>(arguments[i + 1]));
            else
                pushed = pushVariant(L, QVariant(type, arguments[i + 1]));

            if (!pushed)
                lua_pushnil(L);

            ++count;
        }

        if (lua_pcall(L, count, 0, 0) != LUA_OK)
        {
            qWarning("Lua error in the slot of %s: %s", m_signal.methodSignature().constData(), lua_tostring(L, -1));
        }

        lua_settop(L, top);
    }

    QMetaMethod m_signal;
    lua_State* m_L;
    int m_reference;
};

QMetaMethod findSignal(const QObject* sender, QByteArray name)
{
    if (!name.isEmpty() && name.at(0) == '2')
        name.remove(0, 1);

    const QMetaObject* meta = sender->metaObject();

    if (name.contains('('))
    {
        const int index = meta->indexOfSignal(QMetaObject::normalizedSignature(name.constData()));
        return index >= 0 ? meta->method(index) : QMetaMethod();
    }

    // By name: the first declaration, looking at the most derived class first
    for (; meta != nullptr; meta = meta->superClass())
    {
        for (int i = meta->methodOffset(); i < meta->methodCount(); ++i)
        {
            const QMetaMethod method = meta->method(i);
            if (method.methodType() == QMetaMethod::Signal && method.name() == name)
                return method;
        }
    }

    return QMetaMethod();
}

/** What connect() returns; disconnect() undoes it. */
class LuaConnection
{
public:
    LuaConnection() = default;
    explicit LuaConnection(SlotProxy* proxy)
        : m_proxy(proxy)
    {
    }

    bool isConnected() const { return !m_proxy.isNull(); }

    void disconnect()
    {
        if (m_proxy)
            delete m_proxy.data();
    }

private:
    QPointer<SlotProxy> m_proxy;
};

/** (sender, signal, function [, connection type]); errors are reported in `error`, since raising them here would skip destructors. */
LuaConnection connectSignal(lua_State* L, std::string& error)
{
    auto sender = luabridge::Stack<QObject*>::get(L, 1);
    auto signal = luabridge::Stack<QByteArray>::get(L, 2);
    if (!sender || !*sender || !signal)
    {
        error = "connect expects an object and the name of a signal";
        return {};
    }

    if (!lua_isfunction(L, 3))
    {
        error = "connect expects a function as the third argument";
        return {};
    }

    const Qt::ConnectionType type = lua_isnoneornil(L, 4) ? Qt::AutoConnection : static_cast<Qt::ConnectionType>(lua_tointeger(L, 4));

    const QMetaMethod method = findSignal(*sender, *signal);
    if (!method.isValid())
    {
        error = std::string((*sender)->metaObject()->className()) + " has no signal " + signal->constData();
        return {};
    }

    lua_pushvalue(L, 3);
    const int reference = luaL_ref(L, LUA_REGISTRYINDEX);

    auto* proxy = new SlotProxy(*sender, method, L, reference);
    const QMetaObject::Connection connection = QMetaObject::connect(*sender, method.methodIndex(), proxy, SlotProxy::slotId(), type, nullptr);
    if (!connection)
    {
        delete proxy;
        error = std::string("could not connect to ") + signal->constData();
        return {};
    }

    stateData(L).proxies.emplace_back(proxy);
    return LuaConnection(proxy);
}

int connectSignalFunction(lua_State* L)
{
    {
        std::string error;
        LuaConnection connection = connectSignal(L, error);
        if (error.empty())
        {
            (void)luabridge::Stack<LuaConnection>::push(L, connection);
            return 1;
        }

        lua_pushstring(L, error.c_str());
    }

    return lua_error(L);
}

// ------------------------------------------------------------------------------------------
// Events
// ------------------------------------------------------------------------------------------

Result pushEvent(lua_State* L, QEvent* event)
{
    return luabridge::Stack<QEvent*>::push(L, event); // the real class, see PointerStack
}

/** Calls a Lua function for every event of the objects it watches: function(object, event) -> true to swallow the event. */
class LuaEventFilter final : public QObject
{
public:
    explicit LuaEventFilter(const LuaRef& function)
        : m_L(mainThread(function.state()))
    {
        function.push(m_L);
        m_reference = luaL_ref(m_L, LUA_REGISTRYINDEX);
        stateData(m_L).filters.emplace_back(this);
    }

    ~LuaEventFilter() override
    {
        if (m_L != nullptr)
            luaL_unref(m_L, LUA_REGISTRYINDEX, m_reference);
    }

    void detach() { m_L = nullptr; }

    bool eventFilter(QObject* watched, QEvent* event) override
    {
        if (m_L == nullptr)
            return false;

        lua_State* L = m_L;
        const int top = lua_gettop(L);

        lua_rawgeti(L, LUA_REGISTRYINDEX, m_reference);
        pushObject(L, watched);
        pushEvent(L, event);

        bool swallow = false;
        if (lua_pcall(L, 2, 1, 0) == LUA_OK)
            swallow = lua_toboolean(L, -1) != 0;
        else
            qWarning("Lua error in an event filter: %s", lua_tostring(L, -1));

        lua_settop(L, top);
        return swallow;
    }

private:
    lua_State* m_L;
    int m_reference = LUA_NOREF;
};

StateData::~StateData()
{
    for (auto& proxy : proxies)
    {
        if (proxy)
        {
            proxy->detach();
            delete proxy.data();
        }
    }

    for (auto& filter : filters)
    {
        if (filter)
        {
            filter->detach();
            delete filter.data();
        }
    }

    // The application goes last: the widgets of the script are gone by now
    application.reset();
}

// ------------------------------------------------------------------------------------------
// The application
// ------------------------------------------------------------------------------------------

/** QApplication.create({"name", ...}): the instance of the host, or a new one that lives as long as the Lua state. */
template <class Application>
Application* createApplication(lua_State* L, const LuaRef& arguments)
{
    if (QCoreApplication* existing = QCoreApplication::instance())
    {
        if (auto* matching = dynamic_cast<Application*>(existing))
            return matching;

        luaL_error(L, "there already is a %s, it cannot be turned into another kind of application", existing->metaObject()->className());
    }

    auto holder = std::make_unique<ApplicationHolder>();

    if (arguments.isTable())
    {
        for (int i = 1; i <= arguments.length(); ++i)
        {
            auto text = arguments[i].template cast<QByteArray>();
            if (text)
                holder->storage.push_back(*text);
        }
    }

    if (holder->storage.empty())
        holder->storage.push_back("qt6");

    for (QByteArray& text : holder->storage)
        holder->argv.push_back(text.data());
    holder->argv.push_back(nullptr);
    holder->argc = static_cast<int>(holder->storage.size());

    auto* application = new Application(holder->argc, holder->argv.data());
    holder->application.reset(application);
    stateData(L).application = std::move(holder);

    return application;
}

/** QApplication.create([arguments]) for LuaBridge3: the argument is optional. */
template <class Application>
int createApplicationFunction(lua_State* L)
{
    Application* application = nullptr;
    {
        LuaRef arguments = lua_istable(L, 1) ? LuaRef::fromStack(L, 1) : LuaRef(L);
        application = createApplication<Application>(L, arguments);
    }

    auto pushed = luabridge::Stack<Application*>::push(L, application);
    (void)pushed;
    return 1;
}

int castObject(lua_State* L)
{
    // qt6.cast(object, "QPushButton"): the object as that class, or nil
    auto object = luabridge::Stack<QObject*>::get(L, 1);
    if (!object)
        luaL_error(L, "cast expects an object");

    const char* className = luaL_checkstring(L, 2);
    if (*object == nullptr || !(*object)->inherits(className))
    {
        lua_pushnil(L);
        return 1;
    }

    auto pushed = luabridge::Stack<QObject*>::push(L, *object);
    if (!pushed)
        luaL_error(L, "%s", pushed.message().c_str());

    // The object arrives as its real class; qt6.cast asks for a base class on purpose
    rebind(L, -1, className);

    return 1;
}

/** obj:find_child([name [, class_name]]): the first descendant with that object name and class, or nil. findChild is a template. */
int findChild(lua_State* L)
{
    auto object = luabridge::Stack<QObject*>::get(L, 1);
    if (!object || !*object)
        return luaL_error(L, "find_child expects an object");

    const QString name = lua_isnoneornil(L, 2) ? QString() : QString::fromUtf8(luaL_checkstring(L, 2));
    const char* className = lua_isnoneornil(L, 3) ? nullptr : luaL_checkstring(L, 3);

    const QList<QObject*> children = (*object)->findChildren<QObject*>(name, Qt::FindChildrenRecursively);
    for (QObject* child : children)
    {
        if (className == nullptr || child->inherits(className))
        {
            auto pushed = pushObject(L, child);
            (void)pushed;
            return 1;
        }
    }

    lua_pushnil(L);
    return 1;
}

/** obj:find_children([name [, class_name]]): all of them, as a table. */
int findChildren(lua_State* L)
{
    auto object = luabridge::Stack<QObject*>::get(L, 1);
    if (!object || !*object)
        return luaL_error(L, "find_children expects an object");

    const QString name = lua_isnoneornil(L, 2) ? QString() : QString::fromUtf8(luaL_checkstring(L, 2));
    const char* className = lua_isnoneornil(L, 3) ? nullptr : luaL_checkstring(L, 3);

    lua_newtable(L);
    lua_Integer position = 1;
    for (QObject* child : (*object)->findChildren<QObject*>(name, Qt::FindChildrenRecursively))
    {
        if (className != nullptr && !child->inherits(className))
            continue;

        auto pushed = pushObject(L, child);
        (void)pushed;
        lua_rawseti(L, -2, position++);
    }

    return 1;
}

} // namespace

void registerSupport(lua_State* L)
{
    static std::once_flag once;
    std::call_once(once, []
    {
        registerVariantType<QPoint>();
        registerVariantType<QPointF>();
        registerVariantType<QSize>();
        registerVariantType<QSizeF>();
        registerVariantType<QRect>();
        registerVariantType<QRectF>();
        registerVariantType<QLine>();
        registerVariantType<QLineF>();
        registerVariantType<QDate>();
        registerVariantType<QTime>();
        registerVariantType<QDateTime>();
        registerVariantType<QUrl>();
        registerVariantType<QUuid>();
        registerVariantType<QLocale>();
        registerVariantType<QRegularExpression>();
        registerVariantType<QModelIndex>();
        registerVariantType<QJsonValue>();
        registerVariantType<QJsonObject>();
        registerVariantType<QJsonArray>();
        registerVariantType<QJsonDocument>();
        registerVariantType<QColor>();
        registerVariantType<QFont>();
        registerVariantType<QPixmap>();
        registerVariantType<QImage>();
        registerVariantType<QIcon>();
        registerVariantType<QBrush>();
        registerVariantType<QPen>();
        registerVariantType<QPalette>();
        registerVariantType<QCursor>();
        registerVariantType<QKeySequence>();
        registerVariantType<QTransform>();
        registerVariantType<QMatrix4x4>();
        registerVariantType<QVector2D>();
        registerVariantType<QVector3D>();
        registerVariantType<QVector4D>();
        registerVariantType<QQuaternion>();
        registerVariantType<QPolygon>();
        registerVariantType<QPolygonF>();
        registerVariantType<QRegion>();
        registerVariantType<QBitmap>();
    });

    stateData(L); // so the state is released with the Lua state, whatever the script does

    luabridge::getGlobalNamespace(L)
        .beginNamespace("qt6")
            .addFunction("version", +[] { return QString::fromLatin1(qVersion()); })
            .addFunction("connect", &connectSignalFunction)
            .addFunction("cast", &castObject)

            .beginClass<LuaConnection>("LuaConnection")
                .addFunction("disconnect", &LuaConnection::disconnect)
                .addFunction("is_connected", &LuaConnection::isConnected)
            .endClass()

            .deriveClass<LuaEventFilter, QObject>("EventFilter")
                .addConstructorFrom<QtOwned<LuaEventFilter>, void(LuaRef)>()
            .endClass()

            // obj:connect("clicked", function(checked) ... end) -> connection
            .beginClass<QObject>("QObject")
                .addFunction("connect", &connectSignalFunction)
                .addFunction("find_child", &findChild)
                .addFunction("find_children", &findChildren)
            .endClass()

            .beginClass<QCoreApplication>("QCoreApplication")
                .addStaticFunction("create", &createApplicationFunction<QCoreApplication>)
            .endClass()
            .beginClass<QGuiApplication>("QGuiApplication")
                .addStaticFunction("create", &createApplicationFunction<QGuiApplication>)
            .endClass()
            .beginClass<QApplication>("QApplication")
                .addStaticFunction("create", &createApplicationFunction<QApplication>)
            .endClass()
        .endNamespace();
}

} // namespace qt6
