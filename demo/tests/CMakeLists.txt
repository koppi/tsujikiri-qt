# Lua tests for the generated Qt6 bindings.
#
#   cmake --build <build> && ctest --test-dir <build> --output-on-failure
#
# Each test_*.lua file is one CTest test, run by qt6_test in a fresh Lua state with the
# bindings registered. test_api_coverage.lua checks every bound class and function against
# qt6_api.lua, a manifest regenerated from the generated bindings on every build.

set(API_MANIFEST "${CMAKE_CURRENT_BINARY_DIR}/qt6_api.lua")

# Regenerated on every build: it takes a moment, and the generated files can only be named as
# dependencies in the directory that defines their rule, which is not this one. Depending on the
# bindings library makes sure they exist by the time the script reads them.
add_custom_target(qt6_api_manifest
    COMMAND ${VENV_PYTHON}
        "${CMAKE_CURRENT_SOURCE_DIR}/gen_api_manifest.py"
        "${GENERATED_DIR}"
        "${API_MANIFEST}"
    BYPRODUCTS "${API_MANIFEST}"
    COMMENT "Listing the bound Qt classes and functions for the tests"
    VERBATIM
)
add_dependencies(qt6_api_manifest qt6_lua_bindings)

add_executable(qt6_test test_main.cpp)

target_compile_definitions(qt6_test PRIVATE
    QT6_TEST_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
    QT6_TEST_GENERATED_DIR="${CMAKE_CURRENT_BINARY_DIR}"
)

target_link_libraries(qt6_test PRIVATE qt6_lua_bindings)
add_dependencies(qt6_test qt6_api_manifest)

if(WIN32)
    target_compile_definitions(qt6_test PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# Re-run the configure step when a test file is added or removed
file(GLOB QT6_LUA_TESTS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/test_*.lua")

foreach(test_file IN LISTS QT6_LUA_TESTS)
    get_filename_component(test_name "${test_file}" NAME_WE)
    add_test(NAME ${test_name} COMMAND qt6_test "${test_file}")
    set_tests_properties(${test_name} PROPERTIES TIMEOUT 300)
endforeach()
