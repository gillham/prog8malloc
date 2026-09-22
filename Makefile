#
# Simple Makefile for a Prog8 program.
#
# This Makefile requires basic Windows or Unix shell tools
# and the Prog8 compiler as `prog8c`.  The `PCC` variable
# can be overridden to use the compiler as a JAR file but
# the JAR file would need to be downloaded or located.
# `java -jar prog8c-12.2-all.jar` would be equivalent to
# running `prog8c` for example.
#
# The 64tass (or Tass64) assembler is needed by the compiler.
# The C64 emulator requires VICE.
#
# The current custom targets configuration requires symlinks but
# on platforms without symlinks you can copy the `config` and `libraries`
# directories from the `.prog8targets` directory to the root of the repo.
#
# Make targets and explanations:
# all:
#     default target if you just run `make` which ensures
#     the `build/` directory exists and tries to compile
#     whatever targets are in the PROGS variable
#
# build:
#     creates the `build/` directory
#
# clean:
#     removes everything in `build/`
#
# build/mainc64.prg:
#     builds the program for the C64 target
#
# build/maincx16.prg:
#     builds the program for the CX16 target
#
# build/main.gtr:
#     builds the program for the GameTank Console custom target
#
# build/main.p8ir:
#     builds the program for the virtual target
#
# run:
#     depends on the `all` target and then runs in the virtual emulator target
#
# emu-c64:
#     depends on `all` and runs the C64 binary under the VICE emulator.
#
# emu-cx16:
#     depends on `all` and runs the CX16 binary under the x16emu emulator.
#
# check:
#     runs a compiler syntax check without attempting to compile.
#     use it for quickly finding syntax errors in the source code.
#
# test:
#     compiles and runs on the virtual target and compares the output
#     to expected output.  use to validate correct source code changes
#     (presumably the expected results will change as features are written)

# detect & set platform specifics
ifeq ($(OS),Windows_NT)
    CLEAN = del /S /Q build\*
    CP = copy
    RM = del /Q
    MD = mkdir
    MV = cmd -c "move"
    SEP = \\
else
    CLEAN = rm -fr build/*
    CP = cp -p
    RM = rm -f
    MD = mkdir -p
    MV = mv
    SEP = /
endif

PCC=prog8c
PCCARGSBASE=-asmlist -plaintext -out build
PCCARGSDIRS=-srcdirs src
PCCARGSC64=-srcdirs src:src/c64 -plaintext -asmlist -target c64 -out build/
PCCARGSGTC=$(PCCARGSBASE) $(PCCARGSDIRS):src$(SEP)gametank -varsgolden -slabsgolden -target config/gametank.properties
PCCARGSVM=-srcdirs src:src/virtual -plaintext -asmlist -target virtual -out build/
PCCARGSX16=-srcdirs src:src/cx16 -plaintext -asmlist -target cx16 -out build/

PROGS	= build/main.p8ir
#PROGS	= build/mainc64.prg
SRCS	= src/main.p8
XSRCS	= src/libmem.p8 src/tests.p8

.PHONY:	all check test clean run emu

all: build $(PROGS)

build:
	$(MD) build/

build/mainc64.prg: $(SRCS) $(XSRCS)
	$(PCC) $(PCCARGSC64) $<
	$(MV) build/main.prg $@

build/maincx16.prg: $(SRCS) $(XSRCS)
	$(PCC) $(PCCARGSX16) $<
	$(MV) build/main.prg $@

build/main.p8ir: $(SRCS) $(XSRCS)
	$(PCC) $(PCCARGSVM) $<

build/main.gtr: src/main_rom.p8 $(SRCS) $(XSRCS) src/gametank/malloc_platform.p8
	$(PCC) $(PCCARGSGTC) $<
	truncate -s 2m $@
	#dd if=build/main_rom.bin of=$@ bs=16K seek=127 conv=notrunc
	dd if=build/main_rom.bin of=$@ bs=32K seek=0 conv=notrunc
	dd if=build/main_rom.bin of=$@ bs=32K seek=63 conv=notrunc

check:
	$(PCC) -check -quiet $(PCCARGSVM) $(SRCS)

clean:
	$(CLEAN)

run:	all
	$(PCC) -vm build/main.p8ir

emu-c64:	$(SRCS) $(XSRCS)
	$(PCC) $(PCCARGSC64) -emu $<

emu-cx16: $(SRCS) $(XSRCS)
	$(PCC) $(PCCARGSX16) -emu $<

# the -mcpserver option requires the vice-mcp package:
# 	https://github.com/barryw/vice-mcp
#
# you might want to use romdev instead:
#	https://github.com/monteslu/romdev
#
emu-mcp:	build/mainc64.prg
	x64sc -mcpserver -autostartprgmode 1 $<

mcp:	build/mainc64.prg
	x64sc -mcpserver

mcp-warp:	build/mainc64.prg
	x64sc -mcpserver -warp -autostart-warp

# this runs the test on the virtual machine only.
# currently requires prog8c v12.x, not v14.x.
test:	all
	$(PCC) -quiet $(PCCARGSVM) -emu $(SRCS) | diff -u tests/expected/virtual_main.txt -

#
# end-of-file
#
