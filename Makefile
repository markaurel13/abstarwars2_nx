#---------------------------------------------------------------------------------
# Angry Birds Star Wars II -- Nintendo Switch wrapper (32-bit / AArch32)
#
# Ships NO game code and NO game assets: the game's own APK (the user's copy,
# any name) is read at run time; its library is unpacked from it on the first
# launch; its assets are read from the APK itself.
#
# The build is the android32 runtime's (runtime/runtime.mk: devkitARM +
# libnx32 + mesa32 from portlibs32/); ./build.sh runs it in the toolchain
# container. Output: abstarwars2_nx.nsp, which the launcher NRO carries (launcher/).
#---------------------------------------------------------------------------------
TARGET               := abstarwars2_nx
PORT_NPDM_PROGRAM_ID := 0x0100000000001015

ABS_PORTLIBS := $(CURDIR)/portlibs32
ABS_VIDEO    := $(if $(wildcard $(ABS_PORTLIBS)/lib/libavcodec.a),1,0)
ifeq ($(ABS_VIDEO),1)
PORT_LIBS    := -L$(ABS_PORTLIBS)/lib -lavformat -lavcodec -lavutil
endif
PORT_LIBS    += -L$(ABS_PORTLIBS)/lib
PORT_STAMP   := -v$(ABS_VIDEO)
include runtime/runtime.mk

$(BUILD)/abs_video.o: $(SOURCES)/abs_video.c $(RENDERER_STAMP) | $(BUILD) $(BUILD)/dcr_build.h
	@echo $(notdir $<)
	@$(CC) -MMD -MP $(CFLAGS) -fno-short-enums -DABS_VIDEO=$(ABS_VIDEO) -c $< -o $@

# The controller script and the hand cursor's pictures, assembled in with .incbin
$(BUILD)/abs_res.o: $(SOURCES)/abs_ctl.lua $(wildcard $(SOURCES)/cursor/*.png)

.PHONY: check
check:
	@echo "Checking imports..."
	@python3 runtime/tools/gen_imports.py --check
