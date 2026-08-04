# Export variables so child Kbuild processes inherit them
export USE_BOARD_GRUNT
export USE_BOARD_grunt

obj-m += kexec_mod.o

# Disable Link-Time Optimization (LTO)
ccflags-y += -fno-lto

# Check if either uppercase or lowercase flag was set
ifneq ($(or $(USE_BOARD_GRUNT),$(USE_BOARD_grunt)),)
    ccflags-y += -DBOARD_NAME_GRUNT
endif

# Point this to the absolute path of the host kernel tree
KDIR := ../host_kernel/

all:
	$(MAKE) -C $(KDIR) M=$(PWD) USE_BOARD_GRUNT=$(USE_BOARD_GRUNT) USE_BOARD_grunt=$(USE_BOARD_grunt) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
