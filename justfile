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

# ---------------------------------------------------------------------------------------------
# koppi/os: the same bindings as a ring-3 program of the operating system, see koppios/README.md
# ---------------------------------------------------------------------------------------------

os := "../os"

# Build qtlua (Lua + the bindings of the Qt 6.8 that koppi/os vendors) into the os checkout
koppios:
    make -C {{os}}/apps/qt-lua -j2

# Boot koppi/os in QEMU with qtlua on the RAM disk; at the shell prompt type `qtlua` (or `qtlua /rd/selftest.lua`)
koppios-run: koppios
    make -C {{os}} iso
    make -C {{os}} qemu-iso

# Boot koppi/os headless and drive qtlua with the keyboard and the mouse
koppios-test: koppios
    make -C {{os}} iso
    make -C {{os}} qemu-qt-lua
