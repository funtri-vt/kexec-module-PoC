obj-m += kexec_mod.o

# Point this to the absolute path of the chromeos kernel tree you compiled earlier
KDIR := ../host_kernel/

all:
	make -C $(KDIR) M=$(PWD) modules

clean:
	make -C $(KDIR) M=$(PWD) clean
