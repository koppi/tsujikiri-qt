# Builds qtlua: Lua 5.4 with the Qt6 Lua bindings of tsujikiri, as a ring-3 program of koppi/os.
#
# Included by apps/qt-lua/Makefile of koppi/os, after third_party/qt6-gui/koppios/qt.mk (which brings
# the compiler flags, the Qt archives and the C runtime this links against):
#
#     Q := ../../third_party/qt6-gui
#     include $(Q)/koppios/qt.mk
#     TSUJIKIRI_QT6 ?= $(abspath ../../../tsujikiri-qt6)
#     include $(TSUJIKIRI_QT6)/koppios/koppios.mk
#
# What it does, in order:
#   1. lists the functions the vendored Qt libraries define (nm), the bindings may only use those;
#   2. generates the bindings from the headers of that very Qt, with the OS's feature set (generate.py);
#   3. compiles Lua (apps/lua/src), the bindings, the support layer and the host;
#   4. links qtlua.
# Nothing is installed on the host but tsujikiri (a Python virtual environment) and LuaBridge3 (a clone
# of a pinned commit), both kept in koppios/build.

KT  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TSU := $(abspath $(KT)/..)
DEMO := $(TSU)/demo

LUA_SRC  ?= ../lua/src
LUA_SHIM ?= ../lua/shim

QL  := $(B)/qtlua
GEN := $(QL)/generated

# tsujikiri, from a virtual environment: the one of the desktop build when there is one
PYTHON ?= $(firstword $(wildcard $(KT)/build/venv/bin/python $(DEMO)/build/venv/bin/python) $(KT)/build/venv/bin/python)

$(KT)/build/venv/bin/python: $(KT)/requirements.txt
	python3 -m venv $(KT)/build/venv
	$(KT)/build/venv/bin/python -m pip install --quiet --upgrade pip
	$(KT)/build/venv/bin/python -m pip install --quiet -r $<
	@touch $@

# LuaBridge3: the commit the bindings were tested with (the desktop build takes the tip of master)
LUABRIDGE_PIN := 1c0d0efe415cb0dff28fe2a91b8f5530bda62c97
LUABRIDGE     ?= $(KT)/build/LuaBridge3

# patches/luabridge3-no-iostreams.patch: the __tostring of a userdata is built with a std::stringstream,
# which would pull libstdc++'s iostreams into a program that has none. snprintf does the same.
$(LUABRIDGE)/Source/LuaBridge/LuaBridge.h: $(KT)/patches/luabridge3-no-iostreams.patch
	test -d $(LUABRIDGE)/.git || git clone --quiet $(or $(wildcard $(DEMO)/build/_deps/luabridge3-src),https://github.com/kunitoki/LuaBridge3.git) $(LUABRIDGE)
	git -C $(LUABRIDGE) checkout --quiet -f $(LUABRIDGE_PIN)
	git -C $(LUABRIDGE) apply $<
	@touch $@

# ---------------------------------------------------------------------------------------------
# 1. What the vendored libraries define
# ---------------------------------------------------------------------------------------------

$(QL)/symbols.txt: $(B)/libqt.a $(B)/libqtwidgets.a $(KOPPIOS_OBJS)
	@mkdir -p $(@D)
	@echo "  SYM  $@"
	@(nm -g --defined-only $(B)/libqt.a $(B)/libqtwidgets.a $(KOPPIOS_OBJS) 2>/dev/null) \
	  | awk 'NF == 3 && $$2 ~ /[TWVDBRiu]/ { print $$3 }' | sort -u > $@

# ---------------------------------------------------------------------------------------------
# 2. The bindings
# ---------------------------------------------------------------------------------------------

GEN_DEPS := $(KT)/tools/generate.py $(KT)/koppios_unbindable.txt \
  $(DEMO)/tools/qt6_gen.py $(DEMO)/tools/qt6_pointers.py $(DEMO)/qt6.input.yml.in $(DEMO)/qt6_unbindable.txt \
  $(DEMO)/formats/qt6.output.yml $(DEMO)/formats/qt6.output.tpl

$(GEN)/parts.mk: $(GEN_DEPS) $(QL)/symbols.txt $(PYTHON)
	@mkdir -p $(GEN)
	@echo "  GEN  Qt6 bindings"
	@$(file >$(QL)/qtflags.txt,$(QT_CXXFLAGS) $(QT_INC))
	@$(PYTHON) $(KT)/tools/generate.py --qt-flags @$(QL)/qtflags.txt --cwd . --symbols $(QL)/symbols.txt --out $(GEN) \
	  $(addprefix --unbindable ,$(QTLUA_UNBINDABLE)) > $(QL)/generate.log
	@touch $@

-include $(GEN)/parts.mk

# ---------------------------------------------------------------------------------------------
# 3. Compiling
# ---------------------------------------------------------------------------------------------

# Template heavy code: one translation unit needs a gigabyte or so. A limit keeps a runaway compile from
# taking the machine down with it (kilobytes of address space; 0 = none).
QTLUA_VMEM ?= 3500000

# No unwind tables: nothing on this OS unwinds (exceptions are off), and they were a sixth of the code size.
# NDEBUG: LuaBridge3's assertions are assert() otherwise, and each one carries its condition, the file and the
# function it is in as strings (the pretty name of a class template member names its type): 40% of a unit.
NOUNWIND := -fno-asynchronous-unwind-tables -fno-unwind-tables -DNDEBUG

BIND_FLAGS := $(QT_CXXFLAGS) $(NOUNWIND) -I $(GEN)/include -I $(LUA_SRC) -I $(LUABRIDGE)/Source/ -I $(DEMO)/support -I $(GEN) -w

$(QL)/gen/%.o: $(GEN)/%.cpp $(GEN)/qt6_pointers.h $(LUABRIDGE)/Source/LuaBridge/LuaBridge.h
	@mkdir -p $(@D)
	@echo "  BIND $*"
	@(test $(QTLUA_VMEM) = 0 || ulimit -v $(QTLUA_VMEM); $(CXX) $(BIND_FLAGS) -MMD -MP -c $< -o $@)

$(QL)/gen/qt6_lua.o: $(DEMO)/support/qt6_lua.cpp $(DEMO)/support/qt6_lua.h $(GEN)/qt6_pointers.h $(LUABRIDGE)/Source/LuaBridge/LuaBridge.h
	@mkdir -p $(@D)
	@echo "  BIND qt6_lua"
	@(test $(QTLUA_VMEM) = 0 || ulimit -v $(QTLUA_VMEM); $(CXX) $(BIND_FLAGS) -MMD -MP -c $< -o $@)

HOST_FLAGS := $(QT_CXXFLAGS) $(NOUNWIND) -I $(LUA_SRC) -I $(KT)/host

$(QL)/host/%.o: $(KT)/host/%.cpp $(KT)/host/lua_koppios.h
	@mkdir -p $(@D)
	@echo "  HOST $*"
	@$(CXX) $(HOST_FLAGS) -MMD -MP -c $< -o $@

# Lua 5.4.8 of the port (apps/lua/src), built for the C library the Qt programs use. The port's own
# build uses a libc of its own (apps/lua/shim); here only its printf is taken, because the C library
# has none that formats a double. See lua_runtime.cpp for the rest.
LUA_CFG := -DLUA_USE_C89 \
  -Dsprintf=sprintf_ \
  "-Dlua_getlocaledecpoint()='.'" \
  '-Dl_system(cmd)=((cmd)==0?0:-1)' \
  '-DLUA_PATH_DEFAULT="/rd/?.lua;/rd/?/init.lua;./?.lua"' \
  '-DLUA_CPATH_DEFAULT=""' \
  '-Dlua_writestring(s,l)=koppios_lua_write((s),(l))' \
  '-Dlua_writeline()=koppios_lua_write("\n",1)' \
  '-Dlua_writestringerror(s,p)=koppios_lua_errf((s),(p))'

LUA_CFLAGS := -m32 -std=gnu11 -Os -w $(NOUNWIND) -ffunction-sections -fdata-sections -fno-stack-protector -fno-pic -fno-pie \
  -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -fno-builtin $(LUA_CFG) -include $(KT)/host/lua_koppios.h

LUA_FILES := $(filter-out linit.c liolib.c loslib.c luac.c onelua.c frontend.c lua.c,$(notdir $(wildcard $(LUA_SRC)/l*.c)))
LUA_OBJS  := $(addprefix $(QL)/lua/,$(LUA_FILES:.c=.o))

$(QL)/lua/%.o: $(LUA_SRC)/%.c $(KT)/host/lua_koppios.h
	@mkdir -p $(@D)
	@echo "  LUA  $*"
	@$(CC) $(LUA_CFLAGS) -MMD -MP -c $< -o $@

# luaL_loadfilex reads through stdio: lua_runtime.cpp has the one that goes through Qt's file engine
$(QL)/lua/lauxlib.o: $(LUA_SRC)/lauxlib.c $(KT)/host/lua_koppios.h
	@mkdir -p $(@D)
	@echo "  LUA  lauxlib"
	@$(CC) $(LUA_CFLAGS) -DluaL_loadfilex=luaL_loadfilex_stdio -MMD -MP -c $< -o $@

$(QL)/lua/printf.o: $(LUA_SHIM)/printf.c
	@mkdir -p $(@D)
	@echo "  LUA  printf"
	@$(CC) -m32 -O2 -w -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -fno-pie -ffunction-sections -fdata-sections \
	  -I $(LUA_SHIM) -c $< -o $@

# ---------------------------------------------------------------------------------------------
# 4. Linking
# ---------------------------------------------------------------------------------------------

QTLUA_OBJS = $(addprefix $(QL)/gen/,$(addsuffix .o,$(PARTS) qt6_lua qt6_register)) \
  $(QL)/host/main.o $(QL)/host/lua_runtime.o $(QL)/host/cxx_runtime.o $(LUA_OBJS) $(QL)/lua/printf.o

qtlua: $(QTLUA_OBJS) $(KOPPIOS_OBJS) $(QT_LIBS_widgets) $(Q)/koppios/qt_app.lds $(KLIB)
	@echo "  LD   qtlua"
	@$(CXX) -m32 -nostdlib -no-pie -Wl,-T,$(Q)/koppios/qt_app.lds -Os -Wl,--gc-sections -Wl,--no-keep-memory \
	  -Wl,-Map,$(QL)/qtlua.map -o $(QL)/qtlua.unstripped $(QTLUA_OBJS) $(KOPPIOS_OBJS) \
	  -Wl,--start-group $(QT_LIBS_widgets) $(KLIB) $(LIBGCC) -Wl,--end-group
	@strip -s -o qtlua $(QL)/qtlua.unstripped
	@size qtlua

-include $(wildcard $(QL)/gen/*.d $(QL)/host/*.d $(QL)/lua/*.d)

qtlua-clean:
	rm -rf $(QL) qtlua

.PHONY: qtlua-clean
