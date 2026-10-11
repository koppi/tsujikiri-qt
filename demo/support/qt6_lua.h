// Glue between Qt and LuaBridge3 that the generated bindings rely on.
//
// Everything the generated code needs to see before it names a Qt type lives here: how
// QString, QList, QFlags, QVariant ... cross into Lua (Stack<> specializations), who owns the
// QObjects created from Lua (qt6::QtOwned) and the runtime helpers shared by all modules.
#pragma once

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include <LuaBridge/LuaBridge.h>

#include <QtCore/QtCore>
#include <QtGui/QtGui>

#include <type_traits>
#include <typeinfo>

namespace qt6 {

// ------------------------------------------------------------------------------------------
// Ownership
// ------------------------------------------------------------------------------------------

/**
 * The container of a QObject derived object that was created from Lua.
 *
 * A QObject is deleted by its parent, so the Lua userdata can neither always delete it nor
 * never. The rule: whoever holds the last reference deletes, a parentless object belongs to
 * the Lua value that created it, an object that was given a parent belongs to the parent.
 * The guard keeps the destructor from touching an object its parent already deleted.
 */
template <class T>
class QtOwned
{
public:
    explicit QtOwned(T* object) noexcept
        : m_object(object)
    {
    }

    // Copies (Lua userdata made from the container) never own
    QtOwned(const QtOwned& other) noexcept
        : m_object(other.m_object)
        , m_owner(false)
    {
    }

    QtOwned& operator=(const QtOwned&) = delete;

    ~QtOwned()
    {
        if (m_owner && m_object && static_cast<QObject*>(m_object.data())->parent() == nullptr)
            delete m_object.data();
    }

    T* get() const noexcept { return m_object.data(); }

private:
    QPointer<T> m_object;
    bool m_owner = true;
};

/**
 * The container of objects that Qt takes over when they are handed to it (a QStandardItem
 * appended to a model, a QGraphicsItem added to a scene, a QMimeData given to the clipboard ...)
 * without any way to ask whether that happened. Deleting them from Lua would delete them twice,
 * so Lua never does: they are released with their owner, or not at all.
 */
template <class T>
class QtLeaked
{
public:
    explicit QtLeaked(T* object) noexcept
        : m_object(object)
    {
    }

    T* get() const noexcept { return m_object; }

private:
    T* m_object;
};

// ------------------------------------------------------------------------------------------
// Equality
// ------------------------------------------------------------------------------------------

template <class T, class = void>
struct IsEqualityComparable : std::false_type
{
};

template <class T>
struct IsEqualityComparable<T, std::void_t<decltype(std::declval<const T&>() == std::declval<const T&>())>> : std::true_type
{
};

/**
 * `a == b` in Lua. Qt declares most comparison operators as friends inside the class, where
 * tsujikiri does not see them, so every class gets this: the value comparison where Qt has one,
 * the identity of the C++ objects (two userdata for one QObject are equal) where it has not.
 */
template <class T>
bool equals(const T& a, const T& b)
{
    if constexpr (IsEqualityComparable<T>::value)
        return a == b;
    else
        return &a == &b;
}

// ------------------------------------------------------------------------------------------
// Runtime helpers (qt6_lua.cpp)
// ------------------------------------------------------------------------------------------

/** Pushes a QVariant as the closest Lua value (nil, boolean, number, string, table or userdata). */
luabridge::Result pushVariant(lua_State* L, const QVariant& value);

/** Converts the Lua value at `index` to a QVariant. */
luabridge::TypeResult<QVariant> getVariant(lua_State* L, int index);

/**
 * The most derived class of `object` that is bound, or nullptr. A pointer to a QWidget that is
 * really a QPushButton has to reach Lua as a QPushButton.
 */
const char* dynamicClassName(lua_State* L, const QObject& object);
const char* dynamicClassName(lua_State* L, const QEvent& event);

/** Gives the userdata at `index` the class `className` (keeping its constness). False if it is that class already, or the class is not bound. */
bool refine(lua_State* L, int index, const char* className);

/**
 * Pointers to a bound class: `nil` is a null pointer, also where the function is overloaded
 * (LuaBridge3 only accepts userdata there), and a QObject or QEvent arrives as its real class.
 * The generated qt6_pointers.h specializes Stack<T*> and Stack<const T*> with this for every
 * bound class.
 */
template <class T>
struct PointerStack
{
    using Plain = std::remove_const_t<T>;

    [[nodiscard]] static luabridge::Result push(lua_State* L, T* object)
    {
        auto result = luabridge::detail::UserdataPtr::push(L, object);
        if (!result || object == nullptr)
            return result;

        if constexpr (std::is_base_of_v<QObject, Plain>)
        {
            if (const char* name = dynamicClassName(L, static_cast<const QObject&>(*object)))
                refine(L, -1, name);
        }
        else if constexpr (std::is_base_of_v<QEvent, Plain>)
        {
            if (const char* name = dynamicClassName(L, static_cast<const QEvent&>(*object)))
                refine(L, -1, name);
        }

        return result;
    }

    [[nodiscard]] static luabridge::TypeResult<T*> get(lua_State* L, int index)
    {
        if (lua_isnil(L, index) || lua_isnone(L, index))
            return static_cast<T*>(nullptr);

        auto result = luabridge::detail::Userdata::get<Plain>(L, index, std::is_const_v<T>);
        if (!result)
            return result.error();

        return static_cast<T*>(*result);
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index)
    {
        return lua_isnil(L, index) || luabridge::detail::Userdata::isInstance<Plain>(L, index);
    }
};

/** Makes `className.name` the static function registered as `name__static`, which an instance method named `name` hides otherwise. */
void aliasStatic(lua_State* L, const char* className, const char* name);

/** One enumerator, as the generated code lists them (compact_enums in the qt6 stage). */
struct EnumValue
{
    const char* name;
    lua_Integer value;
};

/** qt6.<ns>.<enum> = { name = value, ... }, and the values themselves as qt6.<ns>.<name> (a namespace level enum such as Qt::AlignLeft); without a namespace only qt6.<enum>. */
void addNamespaceEnum(lua_State* L, const char* ns, const char* enumName, const EnumValue* values, std::size_t count);

/** qt6.<class>.<enum> = { name = value, ... }, and for an unscoped enum the values as qt6.<class>.<name> too, as in C++. */
void addClassEnum(lua_State* L, const char* className, const char* enumName, bool unscoped, const EnumValue* values, std::size_t count);

/** Registers the helpers that are not generated (connect, casts, application, variants). Call after the modules. */
void registerSupport(lua_State* L);

} // namespace qt6

namespace luabridge {

// ------------------------------------------------------------------------------------------
// Enums are integers in Lua
// ------------------------------------------------------------------------------------------

template <class T>
struct Stack<T, std::enable_if_t<std::is_enum_v<T>>> : Enum<T>
{
};

// ------------------------------------------------------------------------------------------
// Strings are Lua strings (UTF-8)
// ------------------------------------------------------------------------------------------

template <>
struct Stack<QString>
{
    [[nodiscard]] static Result push(lua_State* L, const QString& value)
    {
        const QByteArray utf8 = value.toUtf8();
        lua_pushlstring(L, utf8.constData(), static_cast<std::size_t>(utf8.size()));
        return {};
    }

    [[nodiscard]] static TypeResult<QString> get(lua_State* L, int index)
    {
        switch (lua_type(L, index))
        {
        case LUA_TSTRING:
        {
            std::size_t length = 0;
            const char* text = lua_tolstring(L, index, &length);
            return QString::fromUtf8(text, static_cast<qsizetype>(length));
        }

        case LUA_TNUMBER:
        {
            // lua_tolstring converts a number in place, which would confuse lua_next
            lua_pushvalue(L, index);
            std::size_t length = 0;
            const char* text = lua_tolstring(L, -1, &length);
            QString result = QString::fromUtf8(text, static_cast<qsizetype>(length));
            lua_pop(L, 1);
            return result;
        }

        case LUA_TNIL:
        case LUA_TNONE:
            return QString();

        default:
            return makeErrorCode(ErrorCode::InvalidTypeCast);
        }
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TSTRING; }
};

template <>
struct Stack<QByteArray>
{
    [[nodiscard]] static Result push(lua_State* L, const QByteArray& value)
    {
        lua_pushlstring(L, value.constData(), static_cast<std::size_t>(value.size()));
        return {};
    }

    [[nodiscard]] static TypeResult<QByteArray> get(lua_State* L, int index)
    {
        switch (lua_type(L, index))
        {
        case LUA_TSTRING:
        {
            std::size_t length = 0;
            const char* data = lua_tolstring(L, index, &length);
            return QByteArray(data, static_cast<qsizetype>(length));
        }

        case LUA_TNIL:
        case LUA_TNONE:
            return QByteArray();

        default:
            return makeErrorCode(ErrorCode::InvalidTypeCast);
        }
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TSTRING; }
};

/** A QChar is a string of one character, or its code unit as a number. */
template <>
struct Stack<QChar>
{
    [[nodiscard]] static Result push(lua_State* L, QChar value) { return Stack<QString>::push(L, QString(value)); }

    [[nodiscard]] static TypeResult<QChar> get(lua_State* L, int index)
    {
        if (lua_type(L, index) == LUA_TNUMBER)
            return QChar(static_cast<char16_t>(lua_tointeger(L, index)));

        auto text = Stack<QString>::get(L, index);
        if (!text)
            return text.error();

        return text->isEmpty() ? QChar() : text->at(0);
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index)
    {
        const int type = lua_type(L, index);
        return type == LUA_TSTRING || type == LUA_TNUMBER;
    }
};

/**
 * Views are read-only: they point into the Lua string, which stays alive on the Lua stack
 * for the duration of the call.
 */
template <>
struct Stack<QByteArrayView>
{
    [[nodiscard]] static Result push(lua_State* L, QByteArrayView value)
    {
        lua_pushlstring(L, value.data(), static_cast<std::size_t>(value.size()));
        return {};
    }

    [[nodiscard]] static TypeResult<QByteArrayView> get(lua_State* L, int index)
    {
        if (lua_type(L, index) == LUA_TNIL || lua_type(L, index) == LUA_TNONE)
            return QByteArrayView();

        // A number is converted in place, the string it becomes lives as long as the argument
        if (lua_type(L, index) != LUA_TSTRING && lua_type(L, index) != LUA_TNUMBER)
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        std::size_t length = 0;
        const char* data = lua_tolstring(L, index, &length);
        return QByteArrayView(data, static_cast<qsizetype>(length));
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TSTRING; }
};

template <>
struct Stack<QUtf8StringView>
{
    [[nodiscard]] static Result push(lua_State* L, QUtf8StringView value)
    {
        lua_pushlstring(L, reinterpret_cast<const char*>(value.data()), static_cast<std::size_t>(value.size()));
        return {};
    }

    [[nodiscard]] static TypeResult<QUtf8StringView> get(lua_State* L, int index)
    {
        if (lua_type(L, index) == LUA_TNIL || lua_type(L, index) == LUA_TNONE)
            return QUtf8StringView();

        if (lua_type(L, index) != LUA_TSTRING && lua_type(L, index) != LUA_TNUMBER)
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        std::size_t length = 0;
        const char* data = lua_tolstring(L, index, &length);
        return QUtf8StringView(data, static_cast<qsizetype>(length));
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TSTRING; }
};

template <>
struct Stack<QAnyStringView>
{
    [[nodiscard]] static Result push(lua_State* L, QAnyStringView value) { return Stack<QString>::push(L, value.toString()); }

    [[nodiscard]] static TypeResult<QAnyStringView> get(lua_State* L, int index)
    {
        if (lua_type(L, index) == LUA_TNIL || lua_type(L, index) == LUA_TNONE)
            return QAnyStringView();

        if (lua_type(L, index) != LUA_TSTRING && lua_type(L, index) != LUA_TNUMBER)
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        std::size_t length = 0;
        const char* data = lua_tolstring(L, index, &length);
        return QAnyStringView(data, static_cast<qsizetype>(length));
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TSTRING; }
};

// ------------------------------------------------------------------------------------------
// Flags are integers
// ------------------------------------------------------------------------------------------

template <class E>
struct Stack<QFlags<E>>
{
    using Int = typename QFlags<E>::Int;

    [[nodiscard]] static Result push(lua_State* L, QFlags<E> value)
    {
        lua_pushinteger(L, static_cast<lua_Integer>(static_cast<Int>(value)));
        return {};
    }

    [[nodiscard]] static TypeResult<QFlags<E>> get(lua_State* L, int index)
    {
        if (lua_type(L, index) == LUA_TNIL || lua_type(L, index) == LUA_TNONE)
            return QFlags<E>();

        if (lua_type(L, index) != LUA_TNUMBER)
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        return QFlags<E>::fromInt(static_cast<Int>(lua_tointeger(L, index)));
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TNUMBER; }
};

/** QUrl's formatting options are two flag enums in one (QUrlTwoFlags), an integer all the same. */
template <class E1, class E2>
struct Stack<QUrlTwoFlags<E1, E2>>
{
    [[nodiscard]] static Result push(lua_State* L, QUrlTwoFlags<E1, E2> value)
    {
        lua_pushinteger(L, static_cast<lua_Integer>(static_cast<int>(value)));
        return {};
    }

    [[nodiscard]] static TypeResult<QUrlTwoFlags<E1, E2>> get(lua_State* L, int index)
    {
        if (lua_type(L, index) == LUA_TNIL || lua_type(L, index) == LUA_TNONE)
            return QUrlTwoFlags<E1, E2>();

        if (lua_type(L, index) != LUA_TNUMBER)
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        return QUrlTwoFlags<E1, E2>(QFlag(static_cast<int>(lua_tointeger(L, index))));
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TNUMBER; }
};

// ------------------------------------------------------------------------------------------
// Containers are Lua tables: sequences for QList and QSet, dictionaries for QMap and QHash
// ------------------------------------------------------------------------------------------

namespace detail {

template <class T>
void appendTo(QList<T>& container, T&& value)
{
    container.append(std::move(value));
}

template <class T>
void appendTo(QSet<T>& container, T&& value)
{
    container.insert(std::move(value));
}

template <class Container, class T>
Result pushSequence(lua_State* L, const Container& container)
{
    const int top = lua_gettop(L);
    lua_createtable(L, static_cast<int>(container.size()), 0);

    lua_Integer position = 1;
    for (const auto& element : container)
    {
        auto result = Stack<T>::push(L, element);
        if (!result)
        {
            lua_settop(L, top);
            return result;
        }

        lua_rawseti(L, -2, position++);
    }

    return {};
}

template <class Container, class T>
TypeResult<Container> getSequence(lua_State* L, int index)
{
    if (lua_type(L, index) == LUA_TNIL || lua_type(L, index) == LUA_TNONE)
        return Container();

    if (lua_type(L, index) != LUA_TTABLE)
        return makeErrorCode(ErrorCode::InvalidTypeCast);

    const int table = lua_absindex(L, index);
    const lua_Integer length = static_cast<lua_Integer>(lua_rawlen(L, table));

    Container result;
    for (lua_Integer i = 1; i <= length; ++i)
    {
        lua_rawgeti(L, table, i);
        auto element = Stack<T>::get(L, -1);
        lua_pop(L, 1);

        if (!element)
            return element.error();

        appendTo(result, std::move(*element));
    }

    return result;
}

template <class Container, class K, class V>
Result pushDictionary(lua_State* L, const Container& container)
{
    const int top = lua_gettop(L);
    lua_createtable(L, 0, static_cast<int>(container.size()));

    for (auto it = container.cbegin(); it != container.cend(); ++it)
    {
        auto key = Stack<K>::push(L, it.key());
        if (!key)
        {
            lua_settop(L, top);
            return key;
        }

        auto value = Stack<V>::push(L, it.value());
        if (!value)
        {
            lua_settop(L, top);
            return value;
        }

        lua_rawset(L, -3);
    }

    return {};
}

template <class Container, class K, class V>
TypeResult<Container> getDictionary(lua_State* L, int index)
{
    if (lua_type(L, index) == LUA_TNIL || lua_type(L, index) == LUA_TNONE)
        return Container();

    if (lua_type(L, index) != LUA_TTABLE)
        return makeErrorCode(ErrorCode::InvalidTypeCast);

    const int table = lua_absindex(L, index);

    Container result;
    lua_pushnil(L);
    while (lua_next(L, table) != 0)
    {
        auto key = Stack<K>::get(L, -2);
        auto value = Stack<V>::get(L, -1);
        if (!key || !value)
        {
            lua_pop(L, 2);
            return makeErrorCode(ErrorCode::InvalidTypeCast);
        }

        result.insert(std::move(*key), std::move(*value));
        lua_pop(L, 1);
    }

    return result;
}

} // namespace detail

template <class T>
struct Stack<QList<T>>
{
    [[nodiscard]] static Result push(lua_State* L, const QList<T>& value) { return detail::pushSequence<QList<T>, T>(L, value); }

    [[nodiscard]] static TypeResult<QList<T>> get(lua_State* L, int index) { return detail::getSequence<QList<T>, T>(L, index); }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TTABLE; }
};

template <class T>
struct Stack<QSet<T>>
{
    [[nodiscard]] static Result push(lua_State* L, const QSet<T>& value) { return detail::pushSequence<QSet<T>, T>(L, value); }

    [[nodiscard]] static TypeResult<QSet<T>> get(lua_State* L, int index) { return detail::getSequence<QSet<T>, T>(L, index); }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TTABLE; }
};

template <class K, class V>
struct Stack<QMap<K, V>>
{
    [[nodiscard]] static Result push(lua_State* L, const QMap<K, V>& value) { return detail::pushDictionary<QMap<K, V>, K, V>(L, value); }

    [[nodiscard]] static TypeResult<QMap<K, V>> get(lua_State* L, int index) { return detail::getDictionary<QMap<K, V>, K, V>(L, index); }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TTABLE; }
};

template <class K, class V>
struct Stack<QHash<K, V>>
{
    [[nodiscard]] static Result push(lua_State* L, const QHash<K, V>& value) { return detail::pushDictionary<QHash<K, V>, K, V>(L, value); }

    [[nodiscard]] static TypeResult<QHash<K, V>> get(lua_State* L, int index) { return detail::getDictionary<QHash<K, V>, K, V>(L, index); }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return lua_type(L, index) == LUA_TTABLE; }
};

// ------------------------------------------------------------------------------------------
// QVariant holds whatever Lua passes
// ------------------------------------------------------------------------------------------

template <>
struct Stack<QVariant>
{
    [[nodiscard]] static Result push(lua_State* L, const QVariant& value) { return qt6::pushVariant(L, value); }

    [[nodiscard]] static TypeResult<QVariant> get(lua_State* L, int index) { return qt6::getVariant(L, index); }

    [[nodiscard]] static bool isInstance(lua_State*, int) { return true; }
};

// ------------------------------------------------------------------------------------------
// QObjects created from Lua are held by qt6::QtOwned
// ------------------------------------------------------------------------------------------

template <class T>
struct ContainerTraits<qt6::QtOwned<T>>
{
    using Type = T;

    static T* get(const qt6::QtOwned<T>& container) { return container.get(); }
};

template <class T>
struct ContainerTraits<qt6::QtLeaked<T>>
{
    using Type = T;

    static T* get(const qt6::QtLeaked<T>& container) { return container.get(); }
};

// ------------------------------------------------------------------------------------------
// Implicit conversions: what C++ converts silently, Lua has to be told
//
// A function taking `const QBrush &` is called with a QColor in C++, and with "red" for a
// QUrl, a QColor or a QKeySequence it reads naturally in Lua too. A bound value class opts in
// to the conversions it accepts besides its own instances.
// ------------------------------------------------------------------------------------------

namespace detail {

/** Values of the bound class T, or whatever Convert makes a T of. */
template <class T, class Convert>
struct ValueStack
{
    // Not IsUserdata: that would make references to T userdata only, and a `const QBrush &`
    // could not be given a color. Pointers to T are PointerStack's.

    [[nodiscard]] static Result push(lua_State* L, const T& value) { return StackHelper<T, false>::push(L, value); }

    [[nodiscard]] static Result push(lua_State* L, T&& value) { return StackHelper<T, false>::push(L, std::move(value)); }

    [[nodiscard]] static TypeResult<T> get(lua_State* L, int index)
    {
        if (Userdata::isInstance<T>(L, index))
        {
            auto result = Userdata::get<T>(L, index, true);
            if (!result)
                return result.error();

            if (T* pointer = *result)
                return *pointer;

            return makeErrorCode(ErrorCode::InvalidTypeCast);
        }

        return Convert::get(L, index);
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index) { return Userdata::isInstance<T>(L, index) || Convert::accepts(L, index); }
};

/** A T from the first of the converters that accepts the value. */
template <class T, class... Converters>
struct AnyOf
{
    static bool accepts(lua_State* L, int index) { return (Converters::accepts(L, index) || ...); }

    static TypeResult<T> get(lua_State* L, int index)
    {
        TypeResult<T> result = makeErrorCode(ErrorCode::InvalidTypeCast);
        (void)((Converters::accepts(L, index) ? (result = Converters::get(L, index), true) : false) || ...);
        return result;
    }
};

/** T(text), for classes that can be written as a string: "red", "Ctrl+S", "http://...". */
template <class T>
struct FromString
{
    static bool accepts(lua_State* L, int index) { return lua_type(L, index) == LUA_TSTRING; }

    static TypeResult<T> get(lua_State* L, int index)
    {
        auto text = Stack<QString>::get(L, index);
        if (!text)
            return text.error();

        return T(*text);
    }
};

/** To(from), for the instances of another bound class that C++ converts implicitly. */
template <class To, class From>
struct FromClass
{
    static bool accepts(lua_State* L, int index) { return Userdata::isInstance<From>(L, index); }

    static TypeResult<To> get(lua_State* L, int index)
    {
        auto result = Userdata::get<From>(L, index, true);
        if (!result)
            return result.error();

        if (From* pointer = *result)
            return To(*pointer);

        return makeErrorCode(ErrorCode::InvalidTypeCast);
    }
};

/** A brush from the name of a color. */
struct BrushFromColorName
{
    static bool accepts(lua_State* L, int index) { return lua_type(L, index) == LUA_TSTRING; }

    static TypeResult<QBrush> get(lua_State* L, int index)
    {
        auto text = Stack<QString>::get(L, index);
        if (!text)
            return text.error();

        return QBrush(QColor(*text));
    }
};

/** Any plain Lua value (nil, boolean, number, string, table) as JSON. */
struct JsonFromValue
{
    static bool accepts(lua_State* L, int index)
    {
        const int type = lua_type(L, index);
        return type == LUA_TNIL || type == LUA_TBOOLEAN || type == LUA_TNUMBER || type == LUA_TSTRING || type == LUA_TTABLE;
    }

    static TypeResult<QJsonValue> get(lua_State* L, int index)
    {
        auto value = qt6::getVariant(L, index);
        if (!value)
            return value.error();

        return QJsonValue::fromVariant(*value);
    }
};

} // namespace detail

template <>
struct Stack<QColor> : detail::ValueStack<QColor, detail::AnyOf<QColor, detail::FromString<QColor>>>
{
};

template <>
struct Stack<QUrl> : detail::ValueStack<QUrl, detail::AnyOf<QUrl, detail::FromString<QUrl>>>
{
};

template <>
struct Stack<QKeySequence> : detail::ValueStack<QKeySequence, detail::AnyOf<QKeySequence, detail::FromString<QKeySequence>>>
{
};

template <>
struct Stack<QRegularExpression> : detail::ValueStack<QRegularExpression, detail::AnyOf<QRegularExpression, detail::FromString<QRegularExpression>>>
{
};

template <>
struct Stack<QIcon> : detail::ValueStack<QIcon, detail::AnyOf<QIcon, detail::FromString<QIcon>, detail::FromClass<QIcon, QPixmap>>>
{
};

template <>
struct Stack<QBrush> : detail::ValueStack<QBrush, detail::AnyOf<QBrush, detail::FromClass<QBrush, QColor>, detail::BrushFromColorName>>
{
};

template <>
struct Stack<QPen> : detail::ValueStack<QPen, detail::AnyOf<QPen, detail::FromClass<QPen, QColor>>>
{
};

template <>
struct Stack<QPointF> : detail::ValueStack<QPointF, detail::AnyOf<QPointF, detail::FromClass<QPointF, QPoint>>>
{
};

template <>
struct Stack<QSizeF> : detail::ValueStack<QSizeF, detail::AnyOf<QSizeF, detail::FromClass<QSizeF, QSize>>>
{
};

template <>
struct Stack<QRectF> : detail::ValueStack<QRectF, detail::AnyOf<QRectF, detail::FromClass<QRectF, QRect>>>
{
};

template <>
struct Stack<QLineF> : detail::ValueStack<QLineF, detail::AnyOf<QLineF, detail::FromClass<QLineF, QLine>>>
{
};

template <>
struct Stack<QRegion> : detail::ValueStack<QRegion, detail::AnyOf<QRegion, detail::FromClass<QRegion, QRect>>>
{
};

template <>
struct Stack<QJsonValue> : detail::ValueStack<QJsonValue, detail::AnyOf<QJsonValue, detail::JsonFromValue>>
{
};

} // namespace luabridge

// The pointer conversions of all bound classes (generated), after everything they build on
#include "qt6_pointers.h"
