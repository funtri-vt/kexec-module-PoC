obj-m += kexec_mod.o

# Disable Link-Time Optimization (LTO)
ccflags-y += -fno-lto

ccflags-y += -I$(srctree)

# Point this to the absolute path of the chromeos kernel tree
KDIR := ../host_kernel/

all:
	make -C $(KDIR) M=$(PWD) modules

clean:
	make -C $(KDIR) M=$(PWD) clean
	rm -f board_config.h
