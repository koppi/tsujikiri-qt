// The pieces of libstdc++'s library that LuaBridge3 reaches and lib/ does not have. lib/ is the C++ runtime
// the OS's programs share (cxxabi.cpp, cxx_string.cpp, ...); these are specific enough to stay with qtlua.
//
// * std::error_category and std::system_category(): LuaBridge3 reports errors as a std::error_code with a
//   category of its own, so the base class has to exist at link time. The textbook definitions of the
//   standard, nothing here depends on the platform.
// * std::call_once: its helper and the two thread-local slots the header passes the callable in.
#include <mutex>
#include <stdexcept>
#include <string>
#include <system_error>

namespace std {

// __cow_string stands in for the old copy-on-write string in the ABI of a virtual of error_category (see
// _M_message below). It is a pointer and nothing here ever puts a string in it.
__cow_string::__cow_string()
    : _M_p(nullptr)
{
}

__cow_string::~__cow_string() = default;

inline namespace _V2 {

error_category::~error_category() = default;

// The virtual that hands the message to callers built with the old copy-on-write string ABI. Nothing
// here is (the program and the library are one build), so it only has to exist for the vtable.
__cow_string error_category::_M_message(int) const
{
    return __cow_string();
}

error_condition error_category::default_error_condition(int value) const noexcept
{
    return error_condition(value, *this);
}

bool error_category::equivalent(int value, const error_condition& condition) const noexcept
{
    return default_error_condition(value) == condition;
}

bool error_category::equivalent(const error_code& code, int value) const noexcept
{
    return *this == code.category() && code.value() == value;
}

} // namespace _V2
} // namespace std

// ------------------------------------------------------------------------------------------
// std::system_category()
// ------------------------------------------------------------------------------------------

namespace std {
inline namespace _V2 {
namespace {

// There is no strerror() to describe an errno with, and nothing LuaBridge3 does with the system category
// looks at the text.
class SystemCategory final : public error_category
{
public:
    const char* name() const noexcept override { return "system"; }

    string message(int) const override { return "system error"; }
};

const SystemCategory systemCategory;

} // namespace

const error_category& system_category() noexcept
{
    return systemCategory;
}

} // namespace _V2

// ------------------------------------------------------------------------------------------
// std::call_once
// ------------------------------------------------------------------------------------------

// call_once() puts the callable and a function that calls it where __once_proxy() finds them, and has
// pthread_once() run the proxy (the C library's pthread_once is lib/pthread_glibc.c).
__thread void* __once_callable;
__thread void (*__once_call)();

extern "C" void __once_proxy()
{
    __once_call();
}

} // namespace std
