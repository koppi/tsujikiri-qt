build_dir := "demo/build"

# List all targets
default:
    @just --list

# Configure and compile the demo (installs Qt, generates the bindings with tsujikiri)
build:
    cmake -S demo -B {{build_dir}}
    cmake --build {{build_dir}} --parallel 3

# Compile and run the demo (QT_QPA_PLATFORM=offscreen is used when there is no display)
run: build
    {{build_dir}}/qt6_demo

# Build, then run the Lua binding tests (QT6_TEST_VERBOSE=1 lists every test case)
test: build
    ctest --test-dir {{build_dir}} --output-on-failure
