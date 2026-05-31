#ifndef _KEXEC_IOCTL_H
#define _KEXEC_IOCTL_H

#include <linux/ioctl.h>
#include <linux/types.h>

/* * This structure is used to pass data from user space to kernel space.
 * We use __u64 for the pointer to ensure it works identically whether 
 * the user-space program is compiled as 32-bit or 64-bit.
 */
struct kexec_payload {
    __u64 user_buf; /* Pointer to the user-space buffer containing our data */
    __u64 size;     /* Size of the data in bytes */
};

/* * A "Magic Number" uniquely identifies our ioctls so the kernel 
 * doesn't confuse them with ioctls meant for other devices. 
 * We'll use 'K' for Kexec.
 */
#define KEXEC_MAGIC 'K'

/* * Define the specific ioctl commands.
 * _IOW means "User space is Writing data to the kernel"
 * _IO  means "Trigger an action, no data attached"
 */

/* 1. Send the kernel command line string (e.g., "console=ttyS0 root=/dev/ram0") */
#define KEXEC_IOC_SET_CMDLINE   _IOW(KEXEC_MAGIC, 1, struct kexec_payload)

/* 2. Send the actual bzImage file data */
#define KEXEC_IOC_LOAD_KERNEL   _IOW(KEXEC_MAGIC, 2, struct kexec_payload)

/* 3. Send the initramfs file data */
#define KEXEC_IOC_LOAD_INITRD   _IOW(KEXEC_MAGIC, 3, struct kexec_payload)

/* 4. Trigger the teardown and jump! (Point of no return) */
#define KEXEC_IOC_EXECUTE       _IO(KEXEC_MAGIC, 4)

#endif /* _KEXEC_IOCTL_H */
