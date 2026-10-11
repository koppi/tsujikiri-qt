cmake_minimum_required(VERSION 3.28)
project(qt6_luabridge_demo C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)

# ----------------------------------------------------------------------------------------------
# Options
# ----------------------------------------------------------------------------------------------

# The Qt release the bindings are generated for and built against
set(QT6_VERSION "6.12.0" CACHE STRING "Qt version to install and bind (QT6_USE_SYSTEM=OFF)")
option(QT6_USE_SYSTEM "Use the Qt that find_package finds (CMAKE_PREFIX_PATH, Qt6_DIR, the system) instead of installing QT6_VERSION" OFF)
option(QT6_BUILD_TESTS "Build and register the Lua binding tests" ON)

# The modules of qtbase and how many translation units their bindings are split into. The
# split only keeps the compiler's memory and wall time in check; Core and Gui come first
# because the other modules derive from their classes.
set(QT6_MODULES Core Gui Widgets Network Xml Sql Concurrent Test PrintSupport DBus OpenGL OpenGLWidgets)
set(QT6_PARTS_Core 8)
set(QT6_PARTS_Gui 6)
set(QT6_PARTS_Widgets 6)
set(QT6_PARTS_Network 2)
set(QT6_PARTS_Xml 1)
set(QT6_PARTS_Sql 1)
set(QT6_PARTS_Concurrent 1)
set(QT6_PARTS_Test 1)
set(QT6_PARTS_PrintSupport 1)
set(QT6_PARTS_DBus 1)
set(QT6_PARTS_OpenGL 2)
set(QT6_PARTS_OpenGLWidgets 1)

# Namespace level enums, functions and namespaces with bound classes of each module (regular
# expressions on the qualified name, in YAML flow syntax). Everything else is global.
set(QT6_ENUMS_Core "\"Qt::.*\", \"QtMsgType\"")
set(QT6_FUNCTIONS_Core "")
set(QT6_ENUMS_Sql "\"QSql::.*\"")
set(QT6_ENUMS_DBus "\"QDBus::.*\"")
set(QT6_ENUMS_Concurrent "\"QtConcurrent::.*\"")
set(QT6_ENUMS_Test "\"QTest::.*\"")
set(QT6_FUNCTIONS_Test "\"QTest::(mouse.*|key.*|wheel.*|sendKeyEvent|simulateEvent|qWait|qSleep)\"")
# Headers the module umbrella does not include (QTest::mouseClick, keyClick, ...)
set(QT6_HEADERS_Test QtTest/qtestmouse.h QtTest/qtestkeyboard.h QtTest/qtestevent.h QtTest/qtestwheel.h)
set(QT6_NAMESPACES_Test "\"\", \"QTest\"")

# ----------------------------------------------------------------------------------------------
# Python environment: tsujikiri (and aqtinstall to get Qt)
# ----------------------------------------------------------------------------------------------

find_package(Python3 3.10 COMPONENTS Interpreter REQUIRED)

set(VENV_DIR "${CMAKE_CURRENT_BINARY_DIR}/venv")
set(VENV_STAMP "${VENV_DIR}/requirements.stamp")
set(REQUIREMENTS_FILE "${CMAKE_CURRENT_SOURCE_DIR}/requirements.txt")

if(WIN32 AND NOT MINGW)
    set(VENV_BIN_DIR "${VENV_DIR}/Scripts")
else()
    set(VENV_BIN_DIR "${VENV_DIR}/bin")
endif()
set(VENV_PYTHON "${VENV_BIN_DIR}/python${CMAKE_EXECUTABLE_SUFFIX}")

# Qt has to be known when CMake configures, so the environment is created right here and not
# by a build rule. It is redone whenever requirements.txt changes.
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${REQUIREMENTS_FILE}")
if(NOT EXISTS "${VENV_STAMP}" OR "${REQUIREMENTS_FILE}" IS_NEWER_THAN "${VENV_STAMP}")
    message(STATUS "Creating the Python virtual environment with tsujikiri and aqtinstall")
    execute_process(COMMAND ${Python3_EXECUTABLE} -m venv "${VENV_DIR}" COMMAND_ERROR_IS_FATAL ANY)
    execute_process(COMMAND ${VENV_PYTHON} -m pip install --quiet --upgrade pip COMMAND_ERROR_IS_FATAL ANY)
    execute_process(COMMAND ${VENV_PYTHON} -m pip install --quiet -r "${REQUIREMENTS_FILE}" COMMAND_ERROR_IS_FATAL ANY)
    file(TOUCH "${VENV_STAMP}")
endif()

# ----------------------------------------------------------------------------------------------
# Qt
# ----------------------------------------------------------------------------------------------

if(NOT QT6_USE_SYSTEM)
    # Prebuilt Qt from download.qt.io, installed once into the build directory
    if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux" AND CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64)$")
        set(aqt_host linux)
        set(aqt_arch linux_gcc_64)
        set(aqt_dir gcc_64)
        set(aqt_archives qtbase icu)
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
        set(aqt_host mac)
        set(aqt_arch clang_64)
        set(aqt_dir macos)
        set(aqt_archives qtbase)
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
        set(aqt_host windows)
        set(aqt_arch win64_msvc2022_64)
        set(aqt_dir msvc2022_64)
        set(aqt_archives qtbase)
    else()
        message(FATAL_ERROR "No prebuilt Qt for ${CMAKE_HOST_SYSTEM_NAME} ${CMAKE_HOST_SYSTEM_PROCESSOR}, "
                            "install Qt ${QT6_VERSION} and configure with -DQT6_USE_SYSTEM=ON")
    endif()

    set(QT6_INSTALL_ROOT "${CMAKE_CURRENT_BINARY_DIR}/qt")
    set(QT6_INSTALL_PREFIX "${QT6_INSTALL_ROOT}/${QT6_VERSION}/${aqt_dir}")

    if(NOT EXISTS "${QT6_INSTALL_PREFIX}/lib/cmake/Qt6/Qt6Config.cmake")
        message(STATUS "Installing Qt ${QT6_VERSION} (${aqt_arch}) into ${QT6_INSTALL_ROOT}")
        execute_process(
            COMMAND ${VENV_BIN_DIR}/aqt install-qt ${aqt_host} desktop ${QT6_VERSION} ${aqt_arch}
                    --outputdir "${QT6_INSTALL_ROOT}" --archives ${aqt_archives}
            WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
            RESULT_VARIABLE aqt_result
        )
        if(NOT aqt_result EQUAL 0)
            message(FATAL_ERROR "Installing Qt ${QT6_VERSION} failed. Install Qt yourself and configure with -DQT6_USE_SYSTEM=ON")
        endif()
    endif()

    set(CMAKE_PREFIX_PATH "${QT6_INSTALL_PREFIX}" ${CMAKE_PREFIX_PATH})
    set(Qt6_DIR "${QT6_INSTALL_PREFIX}/lib/cmake/Qt6" CACHE PATH "" FORCE)
    set(QT6_FIND_VERSION ${QT6_VERSION})
else()
    set(QT6_FIND_VERSION 6.8)
endif()

set(QT6_COMPONENTS ${QT6_MODULES})
find_package(Qt6 ${QT6_FIND_VERSION} REQUIRED COMPONENTS ${QT6_COMPONENTS})
message(STATUS "Binding Qt ${Qt6_VERSION} from ${Qt6_DIR}")

# ----------------------------------------------------------------------------------------------
# Dependencies: LuaBridge3 and Lua
# ----------------------------------------------------------------------------------------------

FetchContent_Declare(
    luabridge3
    GIT_REPOSITORY https://github.com/kunitoki/LuaBridge3.git
    GIT_TAG master
    GIT_SHALLOW TRUE
)

FetchContent_Declare(
    lua
    GIT_REPOSITORY https://github.com/lua/lua.git
    GIT_TAG v5.4.8
    GIT_SHALLOW TRUE
)

FetchContent_MakeAvailable(luabridge3 lua)

# Build Lua as a library
add_library(lua_lib STATIC ${lua_SOURCE_DIR}/onelua.c)
target_include_directories(lua_lib PUBLIC ${lua_SOURCE_DIR})
target_compile_definitions(lua_lib PRIVATE MAKE_LIB=1)
if(UNIX AND NOT APPLE)
    target_link_libraries(lua_lib PUBLIC m)
endif()

# ----------------------------------------------------------------------------------------------
# Generate the bindings with tsujikiri, one input file and one set of sources per Qt module
# ----------------------------------------------------------------------------------------------

set(GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${GENERATED_DIR}")

# What tsujikiri has to know to parse the headers: the include directories and definitions
# of all modules, the way the compiler gets them
set(qt6_include_dirs)
set(qt6_defines)
foreach(module IN LISTS QT6_MODULES)
    get_target_property(dirs Qt6::${module} INTERFACE_INCLUDE_DIRECTORIES)
    get_target_property(defs Qt6::${module} INTERFACE_COMPILE_DEFINITIONS)
    if(dirs)
        list(APPEND qt6_include_dirs ${dirs})
    endif()
    if(defs)
        # Qt adds conditions to some of its definitions (generator expressions), only the module marks matter
        list(FILTER defs INCLUDE REGEX "^QT_[A-Z0-9_]+_LIB$")
        list(APPEND qt6_defines ${defs})
    endif()
endforeach()
list(REMOVE_DUPLICATES qt6_include_dirs)
list(APPEND qt6_defines QT_NO_DEBUG NDEBUG=1)
list(REMOVE_DUPLICATES qt6_defines)
list(JOIN qt6_include_dirs "\", \"" qt6_include_dirs_joined)
list(JOIN qt6_defines "\", \"" qt6_defines_joined)
set(QT6_INCLUDE_PATHS "\"${qt6_include_dirs_joined}\"")
set(QT6_DEFINES "\"${qt6_defines_joined}\"")

set(QT6_UNBINDABLE_FILE "${CMAKE_CURRENT_SOURCE_DIR}/qt6_unbindable.txt")
set(QT6_UNBINDABLE_FILES "\"${QT6_UNBINDABLE_FILE}\"")
set(QT6_COMPACT_ENUMS false)
set(QT6_PARSE_ARGS "\"-x\", \"c++\", \"-std=c++17\", \"-fPIC\"")
set(QT6_GEN_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/tools/qt6_gen.py")
set(QT6_GEN_DEPENDS
    "${QT6_GEN_SCRIPT}"
    "${CMAKE_CURRENT_SOURCE_DIR}/formats/qt6.output.yml"
    "${CMAKE_CURRENT_SOURCE_DIR}/formats/qt6.output.tpl"
    "${QT6_UNBINDABLE_FILE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/support/qt6_lua.h"
)

set(QT6_GENERATED_SOURCES)
set(QT6_CLASS_LISTS)
set(QT6_REGISTER_DECLARATIONS)
set(QT6_REGISTER_CALLS)

foreach(module IN LISTS QT6_MODULES)
    string(TOLOWER "${module}" module_lower)
    set(name "qt6_${module_lower}")

    set(QT6_MODULE "${module}")
    set(QT6_MODULE_HEADER "${GENERATED_DIR}/${name}_headers.h")
    set(header_content "#pragma once\n#include <Qt${module}/Qt${module}>\n")
    foreach(extra IN LISTS QT6_HEADERS_${module})
        string(APPEND header_content "#include <${extra}>\n")
    endforeach()
    file(CONFIGURE OUTPUT "${QT6_MODULE_HEADER}" CONTENT "${header_content}" @ONLY NEWLINE_STYLE UNIX)

    if(DEFINED QT6_NAMESPACES_${module})
        set(QT6_NAMESPACES "${QT6_NAMESPACES_${module}}")
    else()
        set(QT6_NAMESPACES "\"\"")
    endif()
    set(QT6_ENUMS "${QT6_ENUMS_${module}}")
    set(QT6_FUNCTIONS "${QT6_FUNCTIONS_${module}}")

    set(input_config "${GENERATED_DIR}/${name}.input.yml")
    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/qt6.input.yml.in" "${input_config}" @ONLY)

    set(parts ${QT6_PARTS_${module}})
    set(outputs "${GENERATED_DIR}/${name}.cpp" "${GENERATED_DIR}/${name}.classes")
    list(APPEND QT6_CLASS_LISTS "${GENERATED_DIR}/${name}.classes")
    math(EXPR last_part "${parts} - 1")
    foreach(i RANGE ${last_part})
        list(APPEND outputs "${GENERATED_DIR}/${name}_p${i}.cpp")
    endforeach()

    add_custom_command(
        OUTPUT ${outputs}
        COMMAND ${VENV_PYTHON} "${QT6_GEN_SCRIPT}"
            --input "${input_config}"
            --parts ${parts}
            --outdir "${GENERATED_DIR}"
            --formats-dir "${CMAKE_CURRENT_SOURCE_DIR}/formats"
            --classes-file "${GENERATED_DIR}/${name}.classes"
        DEPENDS "${input_config}" "${QT6_MODULE_HEADER}" ${QT6_GEN_DEPENDS}
        COMMENT "Generating the Qt${module} bindings using tsujikiri"
        VERBATIM
    )

    list(APPEND QT6_GENERATED_SOURCES ${outputs})
    string(APPEND QT6_REGISTER_DECLARATIONS "void register_${name}(lua_State* L);\n")
    string(APPEND QT6_REGISTER_CALLS "    register_${name}(L);\n")
endforeach()

# Pointers to the bound classes have to be converted in a way of their own (nil, the real class of
# an object), and the compiler has to know that wherever such a pointer is used: qt6_pointers.h
# lists every bound class of all modules and is included by support/qt6_lua.h.
set(QT6_POINTERS_HEADER "${GENERATED_DIR}/qt6_pointers.h")
set(qt6_pointer_includes)
foreach(module IN LISTS QT6_MODULES)
    list(APPEND qt6_pointer_includes --include Qt${module}/Qt${module})
endforeach()
foreach(extra IN LISTS QT6_HEADERS_Test)
    list(APPEND qt6_pointer_includes --include ${extra})
endforeach()

add_custom_command(
    OUTPUT "${QT6_POINTERS_HEADER}"
    COMMAND ${VENV_PYTHON} "${CMAKE_CURRENT_SOURCE_DIR}/tools/qt6_pointers.py"
        --output "${QT6_POINTERS_HEADER}" ${qt6_pointer_includes} ${QT6_CLASS_LISTS}
    DEPENDS ${QT6_CLASS_LISTS} "${CMAKE_CURRENT_SOURCE_DIR}/tools/qt6_pointers.py"
    COMMENT "Listing the pointers to the bound classes"
    VERBATIM
)

# Everything that is generated, before anything is compiled (the precompiled header already needs qt6_pointers.h)
add_custom_target(qt6_generate DEPENDS ${QT6_GENERATED_SOURCES} "${QT6_POINTERS_HEADER}")

# register_qt6(): all modules in the order of their dependencies, then the hand written parts
set(QT6_REGISTER_FILE "${GENERATED_DIR}/qt6_register.cpp")
file(CONFIGURE OUTPUT "${QT6_REGISTER_FILE}" CONTENT [[
// DO NOT EDIT - generated by CMake
#include "qt6_lua.h"

@QT6_REGISTER_DECLARATIONS@
void register_qt6(lua_State* L)
{
@QT6_REGISTER_CALLS@    qt6::registerSupport(L);
}
]] @ONLY)

# The generated code is compiled once and shared by the demo and the tests
add_library(qt6_lua_bindings STATIC
    ${QT6_GENERATED_SOURCES}
    "${QT6_REGISTER_FILE}"
    support/qt6_lua.cpp
)

# tsujikiri's output and Qt's deprecated corners are not ours to fix
set_source_files_properties(${QT6_GENERATED_SOURCES} PROPERTIES GENERATED TRUE)
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    set_source_files_properties(${QT6_GENERATED_SOURCES} PROPERTIES COMPILE_OPTIONS "-w")
elseif(MSVC)
    set_source_files_properties(${QT6_GENERATED_SOURCES} PROPERTIES COMPILE_OPTIONS "/w;/bigobj")
endif()

target_include_directories(qt6_lua_bindings PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/support
    ${luabridge3_SOURCE_DIR}/Source
    ${GENERATED_DIR}
)
add_dependencies(qt6_lua_bindings qt6_generate)

target_link_libraries(qt6_lua_bindings PUBLIC
    lua_lib
)
foreach(module IN LISTS QT6_MODULES)
    target_link_libraries(qt6_lua_bindings PUBLIC Qt6::${module})
endforeach()

target_precompile_headers(qt6_lua_bindings PRIVATE support/qt6_lua.h)

# Create the demo executable
add_executable(qt6_demo main.cpp)

target_compile_definitions(qt6_demo PRIVATE
    QT6_DEMO_SCRIPT="${CMAKE_CURRENT_SOURCE_DIR}/qt6_demo.lua"
)

target_link_libraries(qt6_demo PRIVATE qt6_lua_bindings)

if(WIN32)
    target_compile_definitions(qt6_lua_bindings PRIVATE _CRT_SECURE_NO_WARNINGS)
    target_compile_definitions(qt6_demo PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# Lua tests for the generated bindings (run with `ctest`, or `just test`)
if(QT6_BUILD_TESTS AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/CMakeLists.txt")
    enable_testing()
    add_subdirectory(tests)
endif()
