obj-m += kexec_mod.o

# Disable Link-Time Optimization (LTO) to prevent aggressive dead-code elimination
# from stripping our global init/exit entry points during Kbuild Stage-1.
ccflags-y += -fno-lto

ifneq ($(or $(USE_BOARD_GRUNT),$(USE_BOARD_grunt)),)
    $(info *** kexec_mod: Enabled GPU soft-reset for BOARD_NAME_GRUNT ***)
    ccflags-y += -DBOARD_NAME_GRUNT
endif

# Point this to the absolute path of the chromeos kernel tree you compiled earlier
KDIR := ../host_kernel/

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
