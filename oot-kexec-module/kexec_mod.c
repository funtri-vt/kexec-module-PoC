#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/miscdevice.h>
#include <linux/slab.h>
#include <linux/gfp.h>
#include <linux/highmem.h>
#include <linux/kallsyms.h>
#include <linux/screen_info.h>
#include <asm/io.h>
#include <asm/pgtable.h>

/* Use the relative path as specified by the synchronized directory layout */
#include "../kexec_ioctl.h"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Developer");
MODULE_DESCRIPTION("Custom Out-of-Tree Kexec with Scatter-Gather Trampoline");
MODULE_VERSION("6.7");

#define PAGE_SIZE_4K 4096

/* Structure to track a file payload via scattered 4KB pages */
struct scatter_buffer {
    struct page **pages;      /* Array of page pointers */
    unsigned long *phys_addrs;/* Array of raw physical addresses */
    size_t nr_pages;          /* Total number of pages allocated */
    size_t size;              /* Total size of payload in bytes */
};

static char *kernel_cmdline = NULL;
static struct scatter_buffer loaded_kernel = {NULL, NULL, 0, 0};
static struct scatter_buffer loaded_initrd = {NULL, NULL, 0, 0};
static size_t kernel_pm_offset = 0; /* Offset to the 32-bit protected-mode payload */

/* We allocate one contiguous page specifically for the x86 "Zero Page" (boot_params) */
static void *zero_page_virt = NULL;
static unsigned long zero_page_phys = 0;
static unsigned long initrd_phys_dest = 0x8000000; /* Safe default: 128MB physical */

/* Hardware shutdown function pointers resolved via kallsyms */
static void (*ptr_device_shutdown)(void) = NULL;
static void (*ptr_syscore_shutdown)(void) = NULL;
static int (*ptr_migrate_to_reboot_cpu)(void) = NULL;
static void (*ptr_smp_send_stop)(void) = NULL;
static void (*ptr_lapic_shutdown)(void) = NULL;
static struct screen_info *ptr_screen_info = NULL;

/* Helper to free a scatter buffer */
static void free_scatter_buffer(struct scatter_buffer *buf)
{
    size_t i;
    if (buf->pages) {
        for (i = 0; i < buf->nr_pages; i++) {
            if (buf->pages[i]) {
                __free_page(buf->pages[i]);
            }
        }
        kfree(buf->pages);
        kfree(buf->phys_addrs);
    }
    buf->pages = NULL;
    buf->phys_addrs = NULL;
    buf->nr_pages = 0;
    buf->size = 0;
}

/* Helper to allocate scattered individual pages and copy user data into them */
static int load_user_to_scatter_buffer(struct scatter_buffer *buf, const void __user *user_src, size_t size)
{
    size_t nr_pages = (size + PAGE_SIZE_4K - 1) / PAGE_SIZE_4K;
    size_t i;
    size_t bytes_left = size;
    const char __user *curr_user_ptr = user_src;

    free_scatter_buffer(buf);

    buf->pages = kmalloc_array(nr_pages, sizeof(struct page *), GFP_KERNEL | __GFP_ZERO);
    buf->phys_addrs = kmalloc_array(nr_pages, sizeof(unsigned long), GFP_KERNEL | __GFP_ZERO);
    if (!buf->pages || !buf->phys_addrs) {
        kfree(buf->pages);
        kfree(buf->phys_addrs);
        return -ENOMEM;
    }
    buf->nr_pages = nr_pages;
    buf->size = size;

    for (i = 0; i < nr_pages; i++) {
        void *kaddr;
        size_t copy_size = (bytes_left > PAGE_SIZE_4K) ? PAGE_SIZE_4K : bytes_left;

        buf->pages[i] = alloc_page(GFP_KERNEL | __GFP_ZERO);
        if (!buf->pages[i]) {
            free_scatter_buffer(buf);
            return -ENOMEM;
        }
        buf->phys_addrs[i] = page_to_phys(buf->pages[i]);

        kaddr = kmap(buf->pages[i]);
        if (copy_from_user(kaddr, curr_user_ptr, copy_size)) {
            kunmap(buf->pages[i]);
            free_scatter_buffer(buf);
            return -EFAULT;
        }
        kunmap(buf->pages[i]);

        curr_user_ptr += copy_size;
        bytes_left -= copy_size;
    }
    return 0;
}

static int setup_zero_page(void)
{
    unsigned char *zp = (unsigned char *)zero_page_virt;
    unsigned char *kernel_setup = NULL;
    unsigned char setup_sects;

    if (!loaded_kernel.pages || loaded_kernel.nr_pages == 0) return -EINVAL;

    memset(zp, 0, PAGE_SIZE_4K);

    kernel_setup = kmap(loaded_kernel.pages[0]);
    memcpy(zp, kernel_setup, 1024);
    kunmap(loaded_kernel.pages[0]);

    /* Inject the active screen_info to prevent display corruption */
    if (ptr_screen_info) {
        memcpy(zp, ptr_screen_info, sizeof(struct screen_info));
    } else {
        /* Fallback: Hardcode generic 80x25 VGA Text Mode parameters */
        struct screen_info *si = (struct screen_info *)zp;
        si->orig_x = 0;
        si->orig_y = 0;
        si->orig_video_mode = 3;
        si->orig_video_cols = 80;
        si->orig_video_lines = 25;
        si->orig_video_ega_bx = 3;
        si->orig_video_isVGA = 1; /* 1 = Standard VGA Text Mode */
        si->orig_video_points = 16;
    }

    if (zp[0x202] != 'H' || zp[0x203] != 'd' || zp[0x204] != 'r' || zp[0x205] != 'S') {
        printk(KERN_ERR "kexec: Loaded bzImage does not contain a valid setup header signature!\n");
        return -EINVAL;
    }

    /* Calculate the exact byte offset where the 32-bit Protected Mode kernel starts */
    setup_sects = zp[0x1F1];
    if (setup_sects == 0) setup_sects = 4;
    kernel_pm_offset = (setup_sects + 1) * 512;
    printk(KERN_INFO "kexec: Calculated protected-mode payload offset: %zu bytes\n", kernel_pm_offset);

    /* CRITICAL 6.12 FIX: Provide a valid E820 Physical Memory Map.
     * Modern kernels will instantly panic if e820_entries == 0.
     * We hardcode a generic 256MB QEMU map based on standard PC architecture.
     */
    zp[0x1e8] = 4; /* Number of E820 entries */

    /* Entry 0: 0x0 to 0x9FC00 (Usable Low RAM) */
    *((__u64 *)(zp + 0x2d0)) = 0x0ULL;
    *((__u64 *)(zp + 0x2d8)) = 0x9FC00ULL;
    *((__u32 *)(zp + 0x2e0)) = 1;

    /* Entry 1: 0x9FC00 to 0xA0000 (Reserved) */
    *((__u64 *)(zp + 0x2d0 + 20)) = 0x9FC00ULL;
    *((__u64 *)(zp + 0x2d8 + 20)) = 0x400ULL;
    *((__u32 *)(zp + 0x2e0 + 20)) = 2;

    /* Entry 2: 0xF0000 to 0x100000 (Reserved) */
    *((__u64 *)(zp + 0x2d0 + 40)) = 0xF0000ULL;
    *((__u64 *)(zp + 0x2d8 + 40)) = 0x10000ULL;
    *((__u32 *)(zp + 0x2e0 + 40)) = 2;

    /* Entry 3: 0x100000 to 0x10000000 (Usable High RAM - covers up to 256MB) */
    *((__u64 *)(zp + 0x2d0 + 60)) = 0x100000ULL;
    *((__u64 *)(zp + 0x2d8 + 60)) = 0xFEE0000ULL;
    *((__u32 *)(zp + 0x2e0 + 60)) = 1;

    zp[0x210] = 0xFF; /* Type of loader */
    
    if (loaded_initrd.size > 0) {
        /* Evacuate the initramfs to 128MB (0x8000000) to clear the giant 6.12 decompression path */
        initrd_phys_dest = 0x8000000; 
        *(uint32_t *)(zp + 0x218) = (uint32_t)initrd_phys_dest; 
        *(uint32_t *)(zp + 0x21C) = (uint32_t)loaded_initrd.size;

        /* CRITICAL 6.12 FIX: Modern 64-bit kernels combine this with ext_ramdisk_image 
         * at offset 0x0C0 to support >4GB addresses. We MUST explicitly zero this out. */
        *(uint32_t *)(zp + 0x0C0) = 0; /* ext_ramdisk_image */
        *(uint32_t *)(zp + 0x0C4) = 0; /* ext_ramdisk_size */

        printk(KERN_INFO "kexec: Configured target initrd at physical address: 0x%lx\n", initrd_phys_dest);
    }

    if (kernel_cmdline) {
        *(uint32_t *)(zp + 0x228) = 0x10000;
    }

    return 0;
}

/* * The Ultimate Trampoline.
 * Separates allocations, hardware teardown, and safe atomic copying.
 */
static void execute_trampoline(void)
{
    unsigned char *dest;
    size_t i;
    unsigned long low_page_virt;
    unsigned long low_page_phys;
    unsigned long cr3_phys, cr4_val;
    unsigned long *pgd, *pud, *pmd;
    unsigned long *p4d = NULL;
    size_t bytes_to_copy, src_offset;

    /* --- PHASE 1: SAFE ALLOCATIONS & STUB BUILDING (Interrupts ON, Scheduling Active) --- */
    low_page_virt = __get_free_page(GFP_KERNEL | GFP_DMA | __GFP_ZERO);
    if (!low_page_virt) {
        printk(KERN_ERR "kexec: Failed to allocate transition page!\n");
        return;
    }
    low_page_phys = virt_to_phys((void *)low_page_virt);

    pud = (unsigned long *)__get_free_page(GFP_KERNEL | __GFP_ZERO);
    pmd = (unsigned long *)__get_free_page(GFP_KERNEL | __GFP_ZERO);
    
    asm volatile("mov %%cr3, %0" : "=r" (cr3_phys));
    asm volatile("mov %%cr4, %0" : "=r" (cr4_val));
    cr3_phys &= ~0xFFFUL; /* Mask out PCID bits */

    /* Pre-allocate a 5-level paging transition page if 5-level paging (LA57) is enabled */
    if (cr4_val & (1 << 12)) { 
        p4d = (unsigned long *)__get_free_page(GFP_KERNEL | __GFP_ZERO);
        if (!p4d) {
            printk(KERN_ERR "kexec: Failed to allocate 5-level paging page!\n");
            free_page(low_page_virt);
            free_page((unsigned long)pud);
            free_page((unsigned long)pmd);
            return;
        }
    }

    if (!pud || !pmd) {
        printk(KERN_ERR "kexec: Failed to allocate transition page-table nodes!\n");
        if (low_page_virt) free_page(low_page_virt);
        if (pud) free_page((unsigned long)pud);
        if (pmd) free_page((unsigned long)pmd);
        if (p4d) free_page((unsigned long)p4d);
        return;
    }

    /* Create 128 huge page entries of 2MB each inside our PMD.
     * This expands our identity map limit to 256MB, ensuring the 128MB initrd dest is safely mapped.
     */
    for (i = 0; i < 128; i++) {
        pmd[i] = (i * 0x200000) | 0x83; /* Present, Read/Write, HugePage */
    }
    pud[0] = virt_to_phys(pmd) | 0x3;

    /* Build the 32-bit GDT */
    unsigned long *gdt = (unsigned long *)(low_page_virt + 2048);
    gdt[0] = 0x0000000000000000ULL; /* Null */
    gdt[1] = 0x00af9b000000ffffULL; /* 64-bit CS */
    gdt[2] = 0x00cf9a000000ffffULL; /* 32-bit CS */
    gdt[3] = 0x00cf92000000ffffULL; /* 32-bit DS */

    unsigned short *gdt_limit = (unsigned short *)(low_page_virt + 2032);
    unsigned long *gdt_base = (unsigned long *)(low_page_virt + 2034);
    *gdt_limit = 31;
    *gdt_base = low_page_phys + 2048;

    /* Assembling the Raw Machine Code */
    unsigned char *stub = (unsigned char *)low_page_virt;
    int offset = 0;

    stub[offset++] = 0xfa; /* cli */

    /* lgdt */
    stub[offset++] = 0x0f; stub[offset++] = 0x01; stub[offset++] = 0x15;
    unsigned int gdt_desc_rel = 2032 - (offset + 4);
    memcpy(&stub[offset], &gdt_desc_rel, 4); offset += 4;

    /* Switch stack */
    stub[offset++] = 0x48; stub[offset++] = 0xbc; /* mov rsp, imm64 */
    unsigned long safe_rsp = low_page_phys + 1024 - 16;
    memcpy(&stub[offset], &safe_rsp, 8); offset += 8;

    /* lretq */
    stub[offset++] = 0x48; stub[offset++] = 0xcb;

    /* Build the target Far Return stack frame */
    unsigned int offset_32bit = offset;
    unsigned long *stack_frame = (unsigned long *)(low_page_virt + 1024 - 16);
    stack_frame[0] = low_page_phys + offset_32bit; /* Target RIP */
    stack_frame[1] = 0x10; /* Target CS */

    /* mov eax, 0x18 */
    stub[offset++] = 0xb8; stub[offset++] = 0x18; stub[offset++] = 0x00; stub[offset++] = 0x00; stub[offset++] = 0x00;
    stub[offset++] = 0x8e; stub[offset++] = 0xd8; /* mov ds, eax */
    stub[offset++] = 0x8e; stub[offset++] = 0xc0; /* mov es, eax */
    stub[offset++] = 0x8e; stub[offset++] = 0xe0; /* mov fs, eax */
    stub[offset++] = 0x8e; stub[offset++] = 0xe8; /* mov gs, eax */
    stub[offset++] = 0x8e; stub[offset++] = 0xd0; /* mov ss, eax */

    /* Clear Paging Bit */
    stub[offset++] = 0x0f; stub[offset++] = 0x20; stub[offset++] = 0xc0;
    stub[offset++] = 0x25; stub[offset++] = 0xff; stub[offset++] = 0xff; stub[offset++] = 0xff; stub[offset++] = 0x7f;
    stub[offset++] = 0x0f; stub[offset++] = 0x22; stub[offset++] = 0xc0;

    /* Pipeline flush */
    stub[offset++] = 0xeb; stub[offset++] = 0x00;

    /* Clear LME bit */
    stub[offset++] = 0xb9; stub[offset++] = 0x80; stub[offset++] = 0x00; stub[offset++] = 0x00; stub[offset++] = 0xc0;
    stub[offset++] = 0x0f; stub[offset++] = 0x32;
    stub[offset++] = 0x25; stub[offset++] = 0xff; stub[offset++] = 0xfe; stub[offset++] = 0xff; stub[offset++] = 0xff;
    stub[offset++] = 0x0f; stub[offset++] = 0x30;

    /* Zero Page Pointer */
    stub[offset++] = 0xbe;
    unsigned int zp_phys = (unsigned int)zero_page_phys;
    memcpy(&stub[offset], &zp_phys, 4); offset += 4;

    /* CRITICAL 6.12 STACK STABILITY FIX:
     * Explicitly configure the 32-bit stack pointer ESP to point to a reliable, standard,
     * hardcoded physical memory address (e.g., 0x90000) right before the jump. 
     */
    stub[offset++] = 0xbc; /* mov esp, imm32 */
    unsigned int stable_boot_stack = 0x90000;
    memcpy(&stub[offset], &stable_boot_stack, 4); offset += 4;

    /* Clear Boot Registers */
    stub[offset++] = 0x31; stub[offset++] = 0xc0;
    stub[offset++] = 0x31; stub[offset++] = 0xdb;
    stub[offset++] = 0x31; stub[offset++] = 0xc9;
    stub[offset++] = 0x31; stub[offset++] = 0xd2;
    stub[offset++] = 0x31; stub[offset++] = 0xff;
    stub[offset++] = 0x31; stub[offset++] = 0xed;

    /* Jump to Entry (Exactly 0x100000 now that the 16-bit header is stripped) */
    stub[offset++] = 0xb8; stub[offset++] = 0x00; stub[offset++] = 0x00; stub[offset++] = 0x10; stub[offset++] = 0x00;
    stub[offset++] = 0xff; stub[offset++] = 0xe0;

    wbinvd(); /* Flush machine code to memory */

    /* --- PHASE 2: SYSTEM TEARDOWN --- */
    printk(KERN_INFO "kexec: Quiescing core systems...\n");
    if (ptr_lapic_shutdown) {
        printk(KERN_INFO "kexec: Masking Local APIC Timer...\n");
        ptr_lapic_shutdown();
    }
    
    printk(KERN_INFO "kexec: Point of no return. Disabling local IRQs...\n");
    local_irq_disable();

    /* --- PHASE 3: SAFE COPYING (Interrupts OFF, NO malloc/sleep calls allowed) --- */
    
    dest = (unsigned char *)phys_to_virt(0x10000);
    strcpy(dest, kernel_cmdline);

    /* Extract the exact 32-bit protected mode kernel and copy it to 0x100000 */
    dest = (unsigned char *)phys_to_virt(0x100000);
    bytes_to_copy = loaded_kernel.size - kernel_pm_offset;
    src_offset = kernel_pm_offset;
    
    for (i = 0; i < loaded_kernel.nr_pages; i++) {
        unsigned char *src = (unsigned char *)phys_to_virt(loaded_kernel.phys_addrs[i]);
        size_t page_offset = 0;
        size_t copy_size = PAGE_SIZE_4K;
        
        if (src_offset >= PAGE_SIZE_4K) {
            src_offset -= PAGE_SIZE_4K;
            continue; /* Skip pages entirely occupied by the 16-bit real-mode header */
        } else if (src_offset > 0) {
            page_offset = src_offset;
            copy_size -= src_offset;
            src_offset = 0;
        }
        
        if (copy_size > bytes_to_copy) {
            copy_size = bytes_to_copy;
        }
        
        memcpy(dest, src + page_offset, copy_size);
        dest += copy_size;
        bytes_to_copy -= copy_size;
        
        if (bytes_to_copy == 0) break;
    }

    if (loaded_initrd.size > 0) {
        /* Pack the initramfs safely high in memory at 128MB */
        dest = (unsigned char *)phys_to_virt(initrd_phys_dest);
        for (i = 0; i < loaded_initrd.nr_pages; i++) {
            void *src = phys_to_virt(loaded_initrd.phys_addrs[i]);
            memcpy(dest + (i * PAGE_SIZE_4K), src, PAGE_SIZE_4K);
        }
    }

    /* --- PHASE 4: INJECT IDENTITY MAP & JUMP (NO dynamic allocations allowed here!) --- */
    pgd = (unsigned long *)phys_to_virt(cr3_phys);
    
    if (p4d) { 
        p4d[0] = virt_to_phys(pud) | 0x3;
        pgd[0] = virt_to_phys(p4d) | 0x3;
    } else {
        pgd[0] = virt_to_phys(pud) | 0x3;
    }

    asm volatile("mov %0, %%cr3" :: "r" (cr3_phys) : "memory");

    asm volatile(
        "mov %%cr4, %%rax\n\t"
        "btr $17, %%rax\n\t"
        "mov %%rax, %%cr4\n\t"
        ::: "rax", "memory"
    );

    printk(KERN_INFO "kexec: Trampoline primed. Executing identity-mapped jump...\n");

    /* Blastoff with mandatory hardware cache flush so our physical writes hit main RAM */
    asm volatile(
        "wbinvd\n\t"
        "cli\n\t"
        "jmp *%0\n\t"
        :
        : "r"(low_page_phys)
        : "memory"
    );
}

static long kexec_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    struct kexec_payload payload;
    int ret;

    if (_IOC_DIR(cmd) & _IOC_WRITE) {
        if (copy_from_user(&payload, (void __user *)arg, sizeof(payload))) {
            return -EFAULT;
        }
    }

    switch (cmd) {
        case KEXEC_IOC_SET_CMDLINE:
            printk(KERN_INFO "kexec: Loading command line (Size: %llu bytes)\n", payload.size);
            if (kernel_cmdline) kfree(kernel_cmdline);
            if (payload.size > 2048) return -EINVAL;
            kernel_cmdline = kmalloc(payload.size, GFP_KERNEL);
            if (!kernel_cmdline) return -ENOMEM;
            if (copy_from_user(kernel_cmdline, (void __user *)payload.user_buf, payload.size)) {
                kfree(kernel_cmdline);
                kernel_cmdline = NULL;
                return -EFAULT;
            }
            kernel_cmdline[payload.size - 1] = '\0';
            break;

        case KEXEC_IOC_LOAD_KERNEL:
            printk(KERN_INFO "kexec: Loading bzImage payload...\n");
            ret = load_user_to_scatter_buffer(&loaded_kernel, (void __user *)payload.user_buf, payload.size);
            if (ret) return ret;
            break;

        case KEXEC_IOC_LOAD_INITRD:
            printk(KERN_INFO "kexec: Loading initramfs payload...\n");
            ret = load_user_to_scatter_buffer(&loaded_initrd, (void __user *)payload.user_buf, payload.size);
            if (ret) return ret;
            break;

        case KEXEC_IOC_EXECUTE:
            printk(KERN_INFO "kexec: EXECUTE command received.\n");
            if (!loaded_kernel.pages) return -EINVAL;

            ret = setup_zero_page();
            if (ret) return ret;

            ptr_migrate_to_reboot_cpu();
            ptr_device_shutdown();
            if (ptr_smp_send_stop) ptr_smp_send_stop();
            ptr_syscore_shutdown();

            execute_trampoline();
            break;

        default:
            return -ENOTTY;
    }
    return 0;
}

static const struct file_operations kexec_fops = {
    .owner = THIS_MODULE,
    .unlocked_ioctl = kexec_ioctl,
};

static struct miscdevice kexec_misc_device = {
    .minor = MISC_DYNAMIC_MINOR,
    .name = "custom_kexec",
    .fops = &kexec_fops,
};

static int __init custom_kexec_init(void)
{
    int ret;

    ptr_device_shutdown = (void *)kallsyms_lookup_name("device_shutdown");
    ptr_syscore_shutdown = (void *)kallsyms_lookup_name("syscore_shutdown");
    ptr_migrate_to_reboot_cpu = (void *)kallsyms_lookup_name("migrate_to_reboot_cpu");
    ptr_smp_send_stop = (void *)kallsyms_lookup_name("smp_send_stop");
    ptr_lapic_shutdown = (void *)kallsyms_lookup_name("lapic_shutdown");
    ptr_screen_info = (struct screen_info *)kallsyms_lookup_name("screen_info");

    if (!ptr_device_shutdown || !ptr_syscore_shutdown || !ptr_migrate_to_reboot_cpu) {
        printk(KERN_ERR "kexec: Failed to resolve essential teardown symbols.\n");
        return -ENXIO;
    }

    if (!ptr_screen_info) {
        printk(KERN_WARNING "kexec: screen_info not found. Display might be corrupted after pivot.\n");
    }

    zero_page_virt = (void *)__get_free_page(GFP_KERNEL | __GFP_ZERO);
    if (!zero_page_virt) return -ENOMEM;
    zero_page_phys = virt_to_phys(zero_page_virt);

    ret = misc_register(&kexec_misc_device);
    if (ret) {
        free_page((unsigned long)zero_page_virt);
        return ret;
    }
    printk(KERN_INFO "kexec: Module loaded successfully.\n");
    return 0;
}

static void __exit custom_kexec_exit(void)
{
    if (kernel_cmdline) kfree(kernel_cmdline);
    free_scatter_buffer(&loaded_kernel);
    free_scatter_buffer(&loaded_initrd);

    if (zero_page_virt) free_page((unsigned long)zero_page_virt);

    misc_deregister(&kexec_misc_device);
    printk(KERN_INFO "kexec: Module unloaded.\n");
}

module_init(custom_kexec_init);
module_exit(custom_kexec_exit);
