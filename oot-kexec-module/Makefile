obj-m += kexec_mod.o

# Disable Link-Time Optimization (LTO) to prevent aggressive dead-code elimination
# from stripping our global init/exit entry points during Kbuild Stage-1.
ccflags-y += -fno-lto

ifdef USE_BOARD_GRUNT
    $(info *** kexec_mod: Building with Grunt GPU Intercept enabled ***)
    ccflags-y += -DBOARD_NAME_GRUNT
endif

# Point this to the absolute path of the chromeos kernel tree you compiled earlier
KDIR := ../host_kernel/

all:
	make -C $(KDIR) M=$(PWD) modules

clean:
	make -C $(KDIR) M=$(PWD) clean
