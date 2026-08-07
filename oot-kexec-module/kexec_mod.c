// SPDX-License-Identifier: GPL-2.0-or-later

//     kexec_mod.c: performs an in memory kexec through a misc device for kernels that don't support it
//     Copyright (C) 2026  funtri-vt (funtri.vt@gmail.com)

// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

/* Auto-generated board configuration header */
#include "board_config.h"

//linux includes
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/miscdevice.h>
#include <linux/slab.h>
#include <linux/gfp.h>
#include <linux/highmem.h>
#include <linux/kallsyms.h>
#include <linux/screen_info.h>
#include <linux/delay.h>
#include <linux/pci.h>

//asm includes
#include <asm/io.h>
#include <asm/pgtable.h>
#include <asm/set_memory.h>

/* Use the relative path as specified by the synchronized directory layout */
#include "../kexec_ioctl.h"

//driver includes
#ifdef BOARD_NAME_GRUNT
/* Grunt-specific (Stoney Ridge / GFX8) GPU Driver Headers */
#include "drivers/gpu/drm/amd/include/asic_reg/gca/gfx_8_0_d.h"
#include "drivers/gpu/drm/amd/include/asic_reg/gca/gfx_8_0_sh_mask.h"
#include "drivers/gpu/drm/amd/include/asic_reg/oss/oss_3_0_sh_mask.h"
#include "drivers/gpu/drm/amd/include/asic_reg/oss/oss_3_0_d.h"

/* Aliases for GFX8 GRBM Soft Reset Macros to prevent namespace collisions */
#define GFX8_mmGRBM_SOFT_RESET                      mmGRBM_SOFT_RESET
#define GFX8_mmGRBM_STATUS                          mmGRBM_STATUS
#define GFX8_GRBM_SOFT_RESET__SOFT_RESET_CP_MASK    GRBM_SOFT_RESET__SOFT_RESET_CP_MASK
#define GFX8_GRBM_SOFT_RESET__SOFT_RESET_GFX_MASK   GRBM_SOFT_RESET__SOFT_RESET_GFX_MASK
#define GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPF_MASK   GRBM_SOFT_RESET__SOFT_RESET_CPF_MASK
#define GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPC_MASK   GRBM_SOFT_RESET__SOFT_RESET_CPC_MASK
#define GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPG_MASK   GRBM_SOFT_RESET__SOFT_RESET_CPG_MASK
#define GFX8_GRBM_SOFT_RESET__SOFT_RESET_RLC_MASK   GRBM_SOFT_RESET__SOFT_RESET_RLC_MASK
#define GFX8_GRBM_STATUS__CP_BUSY_MASK              GRBM_STATUS__CP_BUSY_MASK

#define GFX8_mmSRBM_SOFT_RESET                      mmSRBM_SOFT_RESET
#define GFX8_SRBM_SOFT_RESET__SOFT_RESET_SDMA_MASK  SRBM_SOFT_RESET__SOFT_RESET_SDMA_MASK
#define GFX8_SRBM_SOFT_RESET__SOFT_RESET_SDMA1_MASK SRBM_SOFT_RESET__SOFT_RESET_SDMA1_MASK
#define GFX8_SRBM_SOFT_RESET__SOFT_RESET_IH_MASK    SRBM_SOFT_RESET__SOFT_RESET_IH_MASK
// gui active isn't given to us by those includes, so we need to define it manually.
#define GFX8_GRBM_STATUS__GUI_ACTIVE_MASK             0x80000000

#define AMDGPU_ASIC_RESET_DATA                  0x39d5e86b

/* Global pointer for the intercepted Grunt GPU */
static struct pci_dev *stoney_gpu_dev = NULL;
static void __iomem *stoney_mmio_base = NULL;
#endif


MODULE_LICENSE("GPL");
MODULE_AUTHOR("funtri-vt");
MODULE_DESCRIPTION("Custom Out-of-Tree Kexec with Parameter Callback Hijack and Passing of kallsyms_lookup_name address");
MODULE_VERSION("0.0.1-alpha");

#define PAGE_SIZE_4K 4096

/* Structure to track a file payload via scattered 4KB pages */
struct scatter_buffer {
    unsigned long *virt_addrs;/* Array of virtual addresses (__get_free_page) */
    unsigned long *phys_addrs;/* Array of raw physical addresses */
    size_t nr_pages;          /* Total number of pages allocated */
    size_t size;              /* Total size of payload in bytes */
};

/* Struct used to pass configuration data safely to the assembly trampoline */
struct trampoline_control {
    uint64_t low_page_phys;
    uint64_t zero_page_phys;
};

/* E820 memory segment descriptor format */
struct e820_entry {
    uint64_t addr;
    uint64_t size;
    uint32_t type;
} __attribute__((packed));

/* Coreboot signature "LBIO" (0x4F49424C in little-endian) */
#define CB_SIGNATURE 0x4F49424C
#define CB_TAG_MEMORY 0x0001
#define CB_TAG_FORWARD 0x0011

struct cb_forward {
    uint32_t tag;
    uint32_t size;
    uint64_t forward;
} __attribute__((packed));

/* Smart-Scan Coreboot Header */
struct lb_header {
    uint8_t  signature[4]; /* "LBIO" */
    uint32_t header_bytes;
    uint32_t header_checksum;
    uint32_t table_bytes;
    uint32_t table_checksum;
    uint32_t table_entries;
} __attribute__((packed));

struct lb_record {
    uint32_t tag;
    uint32_t size;
} __attribute__((packed));

struct lb_memory_range {
    uint64_t start;
    uint64_t size;
    uint32_t type;
} __attribute__((packed));

struct lb_memory {
    uint32_t tag;
    uint32_t size;
    struct lb_memory_range map[0];
} __attribute__((packed));

/* Declare the labels compiled inside our global assembly block */
extern char trampoline_start[];
extern char trampoline_end[];

/* Declare the variable and register it as a module parameter */
static unsigned long kallsyms_addr = 0;
module_param(kallsyms_addr, ulong, 0444);

/* Define a function pointer type that matches the signature of kallsyms_lookup_name */
typedef unsigned long (*kallsyms_lookup_name_t)(const char *name);

static kallsyms_lookup_name_t ptr_kallsyms_lookup_name = NULL;

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
static void (*ptr_native_stop_other_cpus)(int wait) = NULL; /* Fallback SMP stopper */
static void (*ptr_lapic_shutdown)(void) = NULL;
static struct screen_info *ptr_screen_info = NULL;
static unsigned long *ptr_sme_me_mask = NULL;

/* Guard flag to ensure the initialization runs exactly once */
static int oot_kexec_initialized = 0;

/* Helper to free a scatter buffer */
static void free_scatter_buffer(struct scatter_buffer *buf)
{
    size_t i;
    if (buf->virt_addrs) {
        for (i = 0; i < buf->nr_pages; i++) {
            if (buf->virt_addrs[i]) {
                if (ptr_sme_me_mask && *ptr_sme_me_mask != 0) {
                    set_memory_encrypted(buf->virt_addrs[i], 1);
                }
                free_page(buf->virt_addrs[i]);
            }
        }
        kfree(buf->virt_addrs);
        kfree(buf->phys_addrs);
    }
    buf->virt_addrs = NULL;
    buf->phys_addrs = NULL;
    buf->nr_pages = 0;
    buf->size = 0;
}

/* * Helper to allocate a page guaranteed to be located above a safe physical threshold.
 * This prevents the page allocator from giving us low memory pages (below 16MB) 
 * which our trampoline would overwrite during the final copying stage.
 */
static unsigned long get_safe_high_page(gfp_t gfp_mask)
{
    unsigned long page;
    unsigned long phys;
    struct page_node {
        unsigned long page;
        struct page_node *next;
    };
    struct page_node *head = NULL;
    struct page_node *curr;

    while (1) {
        page = __get_free_page(gfp_mask);
        if (!page)
            break;

        phys = virt_to_phys((void *)page);
        
        /* Threshold: 16MB (0x1000000) guarantees the memory sits cleanly above
         * the kexec destination copy window (0x100000 to ~0x900000).
         */
        if (phys >= 0x1000000UL) {
            break; /* Allocation is high enough and fully safe! */
        }

        /* This page is in low memory. Temporarily retain it so the allocator 
         * does not hand us the exact same page on the subsequent loop pass.
         */
        curr = kmalloc(sizeof(*curr), GFP_ATOMIC);
        if (!curr) {
            /* If we run out of tracking memory, break and accept this page as a fallback */
            break;
        }
        curr->page = page;
        curr->next = head;
        head = curr;
    }

    /* Free all collected low memory pages back to the system */
    while (head) {
        curr = head;
        head = head->next;
        free_page(curr->page);
        kfree(curr);
    }

    return page;
}

/* Helper to allocate scattered individual pages and copy user data into them */
static int load_user_to_scatter_buffer(struct scatter_buffer *buf, const void __user *user_src, size_t size)
{
    size_t nr_pages = (size + PAGE_SIZE_4K - 1) / PAGE_SIZE_4K;
    size_t i;
    size_t bytes_left = size;
    const char __user *curr_user_ptr = user_src;

    free_scatter_buffer(buf);

    buf->virt_addrs = kmalloc_array(nr_pages, sizeof(unsigned long), GFP_KERNEL | __GFP_ZERO);
    buf->phys_addrs = kmalloc_array(nr_pages, sizeof(unsigned long), GFP_KERNEL | __GFP_ZERO);
    if (!buf->virt_addrs || !buf->phys_addrs) {
        kfree(buf->virt_addrs);
        kfree(buf->phys_addrs);
        return -ENOMEM;
    }
    buf->nr_pages = nr_pages;
    buf->size = size;

    for (i = 0; i < nr_pages; i++) {
        size_t copy_size = (bytes_left > PAGE_SIZE_4K) ? PAGE_SIZE_4K : bytes_left;

        /* Force allocation to only return safe pages above our physical threshold */
        buf->virt_addrs[i] = get_safe_high_page(GFP_KERNEL | __GFP_ZERO);
        if (!buf->virt_addrs[i]) {
            free_scatter_buffer(buf);
            return -ENOMEM;
        }
        if ( ptr_sme_me_mask && *ptr_sme_me_mask != 0) {
            set_memory_decrypted(buf->virt_addrs[i], 1);
            clflush_cache_range((void *)buf->virt_addrs[i], PAGE_SIZE_4K);
        }
        
        /* Store physical address for the final jump */
        buf->phys_addrs[i] = virt_to_phys((void *)buf->virt_addrs[i]);

        /* Copy straight to the virtual address without kmap */
        if (copy_from_user((void *)buf->virt_addrs[i], curr_user_ptr, copy_size)) {
            free_scatter_buffer(buf);
            return -EFAULT;
        }

        curr_user_ptr += copy_size;
        bytes_left -= copy_size;
    }
    return 0;
}

/* Struct representing boot parameter segments (Zero Page)
 * CRITICAL FIXED offsets aligned with standard Linux kernel boot specifications:
 * - 0x000: screen_info
 * - 0x0c0: ext_ramdisk_image (64-bit support)
 * - 0x0c4: ext_ramdisk_size (64-bit support)
 * - 0x1e8: e820_entries
 * - 0x1f1: setup_header
 * - 0x2d0: e820_table
 */
struct real_boot_params {
    /* 0x000 */ uint8_t screen_info[0x40];
    /* 0x040 */ uint8_t padding1[0x80];         /* Pad up to 0x0c0 */
    /* 0x0c0 */ uint32_t ext_ramdisk_image;     /* 0x0c0 */
    /* 0x0c4 */ uint32_t ext_ramdisk_size;      /* 0x0c4 */
    /* 0x0c8 */ uint8_t padding2[0x120];        /* Pad up to 0x1e8 */
    /* 0x1e8 */ uint8_t e820_entries;           /* 0x1e8 */
    /* 0x1e9 */ uint8_t padding3[0x8];          /* Pad up to 0x1f1 */
    /* 0x1f1 */ uint8_t setup_header[0x9f];     /* 0x1f1 (Standard setup header size is 159 bytes) */
    /* 0x290 */ uint8_t padding4[0x40];         /* Pad up to 0x2d0 */
    /* 0x2d0 */ uint8_t e820_table[112 * 20];   /* 0x2d0 */
} __attribute__((packed));

/* Helper 1: Extracts E820 from a verified LBIO table */
static int extract_e820_from_lbio(void *vaddr, struct real_boot_params *zp)
{
    struct lb_header *header = (struct lb_header *)vaddr;
    uint32_t entries = header->table_entries;
    void *current_rec = (void *)((unsigned char *)vaddr + header->header_bytes);
    uint32_t j;

    for (j = 0; j < entries; j++) {
        struct lb_record *rec = (struct lb_record *)current_rec;

        if (rec->tag == CB_TAG_MEMORY) {
            struct lb_memory *mem = (struct lb_memory *)rec;
            int num_ranges = (mem->size - sizeof(struct lb_memory)) / sizeof(struct lb_memory_range);
            struct e820_entry *e820 = (struct e820_entry *)zp->e820_table;
            int k;

            if (num_ranges > 112) num_ranges = 112;

            zp->e820_entries = num_ranges;

            for (k = 0; k < num_ranges; k++) {
                e820[k].addr = mem->map[k].start;
                e820[k].size = mem->map[k].size;
                e820[k].type = mem->map[k].type;
            }

            printk(KERN_INFO "kexec: Populated %d E820 entries directly from Coreboot!\n", num_ranges);
            return 0; /* Success */
        }
        current_rec = (void *)((unsigned char *)current_rec + rec->size);
    }
    return -1;
}

/* Helper 2: Checks if an LBIO table is just a forwarder to high memory */
static uint64_t check_for_forwarder(void *vaddr)
{
    struct lb_header *header = (struct lb_header *)vaddr;
    uint32_t entries = header->table_entries;
    void *current_rec = (void *)((unsigned char *)vaddr + header->header_bytes);
    uint32_t j;

    for (j = 0; j < entries; j++) {
        struct lb_record *rec = (struct lb_record *)current_rec;
        if (rec->tag == CB_TAG_FORWARD) {
            struct cb_forward *fwd = (struct cb_forward *)rec;
            return fwd->forward;
        }
        current_rec = (void *)((unsigned char *)current_rec + rec->size);
    }
    return 0;
}

/* Main Coreboot Scanner */
static int parse_coreboot_memory(struct real_boot_params *zp)
{
    /* Coreboot places its static forwarders in these exact legacy ranges */
    unsigned long scan_ranges[][2] = {
        {0x0, 0x1000},          /* 4KB at the very bottom of RAM */
        {0xF0000, 0x100000}     /* 64KB legacy VGA/BIOS hole */
    };
    int i;
    uint64_t cbmem_target = 0;

    /* Step 1: Scan safe low memory to find the LBIO Forwarder */
    for (i = 0; i < 2; i++) {
        unsigned long start_phys = scan_ranges[i][0];
        unsigned long end_phys = scan_ranges[i][1];
        unsigned long size = end_phys - start_phys;
        unsigned long offset;

        /* Map the ENTIRE memory region exactly once, safely page-aligned */
        void *vaddr_base = memremap(start_phys, size, MEMREMAP_WB);
        if (!vaddr_base) continue;

        /* Scan through our safely mapped virtual memory in 16-byte steps */
        for (offset = 0; offset < size; offset += 16) {
            void *vaddr = (void *)((unsigned char *)vaddr_base + offset);
            struct lb_header *header = (struct lb_header *)vaddr;

            if (header->signature[0] == 'L' && header->signature[1] == 'B' &&
                header->signature[2] == 'I' && header->signature[3] == 'O') {

                /* Case A: The full memory map is sitting right here */
                if (extract_e820_from_lbio(vaddr, zp) == 0) {
                    memunmap(vaddr_base);
                    return 0;
                }

                /* Case B: We found the forwarder pointing to the real table */
                cbmem_target = check_for_forwarder(vaddr);
                if (cbmem_target != 0) {
                    printk(KERN_INFO "kexec: Found Coreboot forwarder to high CBMEM at physical 0x%llx\n", cbmem_target);
                    break; /* Break inner loop */
                }
            }
        }
        memunmap(vaddr_base);
        if (cbmem_target != 0) break; /* Break outer loop */
    }

    /* Step 2: Teleport exactly to the high memory table */
    if (cbmem_target != 0) {
        void *high_vaddr = memremap(cbmem_target, 65536, MEMREMAP_WB);
        if (high_vaddr) {
            int ret = extract_e820_from_lbio(high_vaddr, zp);
            memunmap(high_vaddr);
            if (ret == 0) return 0;
        }
    }

    return -1; /* Failed to find the memory tag */
}

static int setup_zero_page(void)
{
    struct real_boot_params *zp = (struct real_boot_params *)zero_page_virt;
    unsigned char *kernel_setup = NULL;
    unsigned char setup_sects;
    void *host_boot_params = NULL;

    if (!loaded_kernel.virt_addrs || loaded_kernel.nr_pages == 0) return -EINVAL;

    memset(zp, 0, PAGE_SIZE_4K);

    kernel_setup = (unsigned char *)loaded_kernel.virt_addrs[0];
    memcpy(zp->setup_header, kernel_setup + 0x1f1, 0x9f); // Copy verified standard setup header size


    /* --- BARE-METAL UPGRADE: HOST E820 REPLICATION & CBMEM --- */
    host_boot_params = (void *)ptr_kallsyms_lookup_name("boot_params");

    /* 1. Try the Coreboot Smart Scan First */
    if (parse_coreboot_memory(zp) == 0) {
        /* Successfully extracted the ground-truth memory map directly from Coreboot! */
    }
    /* 2. Fallback to replicating the host kernel's existing E820 */
    else if (host_boot_params) {
        memcpy(zp->e820_table, (unsigned char *)host_boot_params + 0x2d0, sizeof(zp->e820_table));
        zp->e820_entries = *(uint8_t *)((unsigned char *)host_boot_params + 0x1e8);
        printk(KERN_EMERG "kexec: Replicated host E820 memory map (%d entries)\n", zp->e820_entries);
    }
    /* 3. Absolute Disaster Fallback: The 256MB Stub */
    else {
        uint64_t *entry;
        zp->e820_entries = 4;
        printk(KERN_WARNING "kexec: Could not find boot_params or Coreboot tables. Falling back to 256MB E820 stub!\n");

        /* Entry 0: Usable Low RAM */
        entry = (uint64_t *)(zp->e820_table);
        entry[0] = 0x0ULL; entry[1] = 0x9FC00ULL; *((uint32_t *)(entry + 2)) = 1;

            /* Entry 1: Reserved */
        entry = (uint64_t *)(zp->e820_table + 20);
        entry[0] = 0x9FC00ULL; entry[1] = 0x400ULL; *((uint32_t *)(entry + 2)) = 2;

        /* Entry 2: Reserved */
        entry = (uint64_t *)(zp->e820_table + 40);
        entry[0] = 0xF0000ULL; entry[1] = 0x10000ULL; *((uint32_t *)(entry + 2)) = 2;

        /* Entry 3: Usable High RAM */
        entry = (uint64_t *)(zp->e820_table + 60);
        entry[0] = 0x100000ULL; entry[1] = 0xFEE0000ULL; *((uint32_t *)(entry + 2)) = 1;
    }

    /* --- BARE-METAL UPGRADE: LINEAR FRAMEBUFFER DIAGNOSTICS --- */
    if (ptr_screen_info) {
        memcpy(zp->screen_info, ptr_screen_info, sizeof(struct screen_info));
    } else {
        struct screen_info *si = (struct screen_info *)zp->screen_info;
        si->orig_x = 0;
        si->orig_y = 0;
        si->orig_video_isVGA = 7; /* VIDEO_TYPE_VLFB / VESA Framebuffer */
        si->orig_video_cols = 80;
        si->orig_video_lines = 25;
    }

    if (zp->setup_header[0x11] != 'H' || zp->setup_header[0x12] != 'd' || 
        zp->setup_header[0x13] != 'r' || zp->setup_header[0x14] != 'S') {
        printk(KERN_EMERG "kexec: Loaded bzImage does not contain a valid setup header signature!\n");
        return -EINVAL;
    }

    /* Calculate the exact byte offset where the 32-bit Protected Mode kernel starts */
    setup_sects = zp->setup_header[0];
    if (setup_sects == 0) setup_sects = 4;
    kernel_pm_offset = (setup_sects + 1) * 512;
    printk(KERN_EMERG "kexec: Calculated protected-mode payload offset: %zu bytes\n", kernel_pm_offset);

    zp->setup_header[0x1F] = 0xFF; /* Type of loader */
    
    if (loaded_initrd.size > 0) {
        initrd_phys_dest = 0x8000000; /* Safe high physical RAM destination */
        *(uint32_t *)&(zp->setup_header[0x27]) = (uint32_t)initrd_phys_dest; 
        *(uint32_t *)&(zp->setup_header[0x2B]) = (uint32_t)loaded_initrd.size;

        zp->ext_ramdisk_image = 0;
        zp->ext_ramdisk_size = 0;

        printk(KERN_EMERG "kexec: Configured target initrd at physical address: 0x%lx\n", initrd_phys_dest);
    }

    if (kernel_cmdline) {
        /* Set command line pointer dynamically using absolute offset in zero page */
        *(uint32_t *)((unsigned char *)zp + 0x228) = 0x10000;
    }

    return 0;
}

/* * The Ultimate Trampoline.
 * This function performs allocations and safely delegates the teardown and jump steps.
 */
static void execute_trampoline(void)
{
    unsigned char *dest;
    size_t i, j;
    unsigned long low_page_virt;
    unsigned long low_page_phys;
    unsigned long cr3_phys, cr4_val;
    unsigned long *pgd, *pud;
    unsigned long *p4d = NULL;
    size_t bytes_to_copy, src_offset;
    size_t trampoline_size;
    struct trampoline_control *ctrl;
    unsigned long jump_target;

    unsigned long sme_mask = 0;
    if (ptr_sme_me_mask) {
        sme_mask = *ptr_sme_me_mask;
        if (sme_mask) printk(KERN_EMERG "kexec: AMD SME enabled! Applying C-bit mask: 0x%lx\n", sme_mask);
    }

    /* --- ADVANCED DYNAMIC MEMORY CALCULATOR ---
     * Scan the zero page E820 table we just built to calculate the highest usable memory address.
     */
    uint64_t max_physical_ram = 0x100000000ULL; /* Default fallback: 4 GB */

    struct real_boot_params *zp = (struct real_boot_params *)zero_page_virt;
    if (zp && zp->e820_entries > 0) {
        uint8_t entries = zp->e820_entries;
        struct e820_entry *table = (struct e820_entry *)zp->e820_table;
        uint64_t highest_ram_found = 0;

        for (i = 0; i < entries; i++) {
            if (table[i].type == 1) { /* E820_TYPE_RAM */
                uint64_t segment_ceiling = table[i].addr + table[i].size;
                if (segment_ceiling > highest_ram_found) {
                    highest_ram_found = segment_ceiling;
                }
            }
        }
        if (highest_ram_found > 0) {
            max_physical_ram = highest_ram_found;
            printk(KERN_EMERG "kexec: Detected system physical RAM ceiling at: %llu MB\n", max_physical_ram >> 20);
        }
    }

    /* Calculate necessary PMD directories. (Each PMD page maps 1 GB of memory space) */
    size_t num_pmds = (max_physical_ram + 0x3fffffffULL) >> 30;
    if (num_pmds == 0) num_pmds = 1;
    if (num_pmds > 32) num_pmds = 32; /* Upper safety limit: Cap allocations at 32 GB */

    /* Allocate the variable length array on kernel heap */
    unsigned long **pmds = kmalloc_array(num_pmds, sizeof(unsigned long *), GFP_KERNEL | __GFP_ZERO);
    if (!pmds) {
        printk(KERN_EMERG "kexec: Failed to allocate PMD pointer tracker array!\n");
        return;
    }

    /* --- PHASE 1: SAFE ALLOCATIONS & STUB BUILDING (Interrupts ON, Scheduling Active) --- */
    low_page_virt = __get_free_page(GFP_DMA32 | __GFP_ZERO);
    if (!low_page_virt) {
        printk(KERN_EMERG "kexec: Failed to allocate transition page!\n");
        kfree(pmds);
        return;
    }
    low_page_phys = virt_to_phys((void *)low_page_virt);

    pud = (unsigned long *)__get_free_page(GFP_KERNEL | __GFP_ZERO);
    for (i = 0; i < num_pmds; i++) {
        pmds[i] = (unsigned long *)__get_free_page(GFP_KERNEL | __GFP_ZERO);
    }
    
    asm volatile("mov %%cr3, %0" : "=r" (cr3_phys));
    asm volatile("mov %%cr4, %0" : "=r" (cr4_val));
    cr3_phys = (cr3_phys & ~0xFFFUL) | sme_mask; /* Mask out PCID bits */

    /* Pre-allocate a 5-level paging transition page if 5-level paging (LA57) is enabled */
    if (cr4_val & (1 << 12)) { 
        p4d = (unsigned long *)__get_free_page(GFP_KERNEL | __GFP_ZERO);
    }

    /* Verify all translation page table page allocations succeeded */
    bool alloc_failed = (!pud || ((cr4_val & (1 << 12)) && !p4d));
    for (i = 0; i < num_pmds; i++) {
        if (!pmds[i]) alloc_failed = true;
    }

    if (alloc_failed) {
        printk(KERN_EMERG "kexec: Failed to allocate transition page-table nodes!\n");
        if (low_page_virt) free_page(low_page_virt);
        if (pud) free_page((unsigned long)pud);
        for (i = 0; i < num_pmds; i++) {
            if (pmds[i]) free_page((unsigned long)pmds[i]);
        }
        if (p4d) free_page((unsigned long)p4d);
        kfree(pmds);
        return;
    }

    size_t kernel_payload_size = (loaded_kernel.size > kernel_pm_offset) ?
                              (loaded_kernel.size - kernel_pm_offset) : 0;
    /* BARE-METAL IDENTITY-MAP UPGRADE:
     * Populate only the exact number of required PMD tables dynamically.
     * Maps each segment cleanly up to the system memory ceiling!
     */
    for (i = 0; i < num_pmds; i++) {
        for (j = 0; j < 512; j++) {
            uint64_t phys_start = (i * 0x40000000ULL) + (j * 0x200000ULL);
            uint64_t phys_end = phys_start + 0x200000ULL;
            uint64_t entry_sme = sme_mask;

            uint64_t kernel_start = 0x100000ULL;
            uint64_t kernel_end   = kernel_start + kernel_payload_size;

            uint64_t initrd_start = initrd_phys_dest;
            uint64_t initrd_end   = initrd_phys_dest + loaded_initrd.size;

            /* Strip C-bit from ANY 2MB PMD that overlaps with decrypted targets to prevent MCEs */
            if ((low_page_phys >= phys_start && low_page_phys < phys_end) ||
                (zero_page_phys >= phys_start && zero_page_phys < phys_end) ||
                (0x10000 >= phys_start && 0x10000 < phys_end) ||
                (kernel_payload_size > 0 && kernel_start < phys_end && kernel_end > phys_start) ||
                (loaded_initrd.size > 0 && initrd_start < phys_end && initrd_end > phys_start)) {

                entry_sme = 0;
            }

            pmds[i][j] = phys_start | entry_sme | 0x83;
        }
        /* Append | sme_mask */
        pud[i] = virt_to_phys(pmds[i]) | sme_mask | 0x3;
    }

    /* Copy our compiled position-independent assembly template right after the control block */
    trampoline_size = (size_t)(trampoline_end - trampoline_start);

    /* --- BARE-METAL UPGRADE: AMD SME TARGET DECRYPTION --- */
    if (ptr_sme_me_mask && *ptr_sme_me_mask) {
        size_t kernel_pages = (loaded_kernel.size - kernel_pm_offset + PAGE_SIZE_4K - 1) / PAGE_SIZE_4K;

        printk(KERN_EMERG "kexec: AMD SME active. Stripping C-bits from destination targets...\n");

        /* Decrypt trampoline and zero page */
        set_memory_decrypted(low_page_virt, 1);
        clflush_cache_range((void *)low_page_virt, PAGE_SIZE_4K);
        /* Decrypt low memory targets (0x10000 cmdline, 0x100000 kernel) */
        set_memory_decrypted((unsigned long)phys_to_virt(0x10000), 1);
        clflush_cache_range(phys_to_virt(0x10000), PAGE_SIZE_4K);

        set_memory_decrypted((unsigned long)phys_to_virt(0x100000), kernel_pages);
        clflush_cache_range(phys_to_virt(0x100000), kernel_pages * PAGE_SIZE_4K);
        /* Decrypt initrd destination if present */
        if (loaded_initrd.size > 0) {
            set_memory_decrypted((unsigned long)phys_to_virt(initrd_phys_dest), loaded_initrd.nr_pages);
            clflush_cache_range(phys_to_virt(initrd_phys_dest), loaded_initrd.nr_pages * PAGE_SIZE_4K);
        }
    }

    /* Populate the trampoline control block parameters (placed at the start of low_page_virt) (moved to make sure we're writing to plaintext memory) */
    ctrl = (struct trampoline_control *)low_page_virt;
    ctrl->low_page_phys = low_page_phys;
    ctrl->zero_page_phys = zero_page_phys;


    //copy after setting decrypted
    memcpy((void *)(low_page_virt + 32), (void *)trampoline_start, trampoline_size);

    /* --- PHASE 2: SYSTEM TEARDOWN --- */
    printk(KERN_EMERG "kexec: Quiescing core systems...\n");
    if (ptr_syscore_shutdown) {
        printk(KERN_EMERG "kexec: Tearing down syscore...\n");
        ptr_syscore_shutdown();
    }
    printk(KERN_EMERG "kexec: Point of no return. Disabling local IRQs...\n");
    if (ptr_smp_send_stop) {
        ptr_smp_send_stop();
    } else if (ptr_native_stop_other_cpus) {
        ptr_native_stop_other_cpus(0);
    }
    mdelay(100);
    local_irq_disable();
    if (ptr_lapic_shutdown) {
        printk(KERN_EMERG "kexec: Masking Local APIC Timer...\n");
        ptr_lapic_shutdown();
    }
    
#ifdef BOARD_NAME_GRUNT
    // BEGIN FIXES
    if (stoney_gpu_dev && stoney_mmio_base) {
            /* --- BEGIN GRBM SOFT RESET INJECTION --- */
            /* We are completely atomic here. No IRQs, no other CPUs. */

            /* mmGRBM_SOFT_RESET (DWORD index scaled to byte offset) */
            void __iomem *grbm_soft_reset = stoney_mmio_base + (GFX8_mmGRBM_SOFT_RESET * 4);
            /* mmGRBM_STATUS (DWORD index scaled to byte offset) */
            void __iomem *grbm_status = stoney_mmio_base + (GFX8_mmGRBM_STATUS * 4);

            void __iomem *srbm_soft_reset = stoney_mmio_base + (GFX8_mmSRBM_SOFT_RESET * 4);
            

            u32 grbm_tmp, status_val, srbm_tmp;
            int timeout;

            printk(KERN_EMERG "kexec: Performing Read-Modify-Write on GRBM_SOFT_RESET...\n");

            /* 1. READ current register state to preserve other blocks */
            grbm_tmp = ioread32(grbm_soft_reset);
            srbm_tmp = ioread32(srbm_soft_reset);

            /* 2. MODIFY by OR-ing the required CP and GFX sub-engine bits via macros */
            grbm_tmp |= (GFX8_GRBM_SOFT_RESET__SOFT_RESET_CP_MASK  |
                    GFX8_GRBM_SOFT_RESET__SOFT_RESET_GFX_MASK |
                    GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPF_MASK |
                    GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPC_MASK |
                    GFX8_GRBM_SOFT_RESET__SOFT_RESET_RLC_MASK |
                    GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPG_MASK);
            
            srbm_tmp |= (GFX8_SRBM_SOFT_RESET__SOFT_RESET_SDMA_MASK  |
                 GFX8_SRBM_SOFT_RESET__SOFT_RESET_SDMA1_MASK |
                 GFX8_SRBM_SOFT_RESET__SOFT_RESET_IH_MASK);

            /* 3. WRITE back the asserted state */
            iowrite32(grbm_tmp, grbm_soft_reset);
            iowrite32(srbm_tmp, srbm_soft_reset);
            ioread32(grbm_soft_reset);
            ioread32(srbm_soft_reset);
            udelay(50);

            /* 4. DE-ASSERT: Read current state again, clear out the reset bits */
            grbm_tmp = ioread32(grbm_soft_reset);
            grbm_tmp &= ~(GFX8_GRBM_SOFT_RESET__SOFT_RESET_CP_MASK  |
                     GFX8_GRBM_SOFT_RESET__SOFT_RESET_GFX_MASK |
                     GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPF_MASK |
                     GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPC_MASK |
                     GFX8_GRBM_SOFT_RESET__SOFT_RESET_RLC_MASK |
                     GFX8_GRBM_SOFT_RESET__SOFT_RESET_CPG_MASK);
            srbm_tmp = ioread32(srbm_soft_reset);
            srbm_tmp &= ~(GFX8_SRBM_SOFT_RESET__SOFT_RESET_SDMA_MASK  |
                  GFX8_SRBM_SOFT_RESET__SOFT_RESET_SDMA1_MASK |
                  GFX8_SRBM_SOFT_RESET__SOFT_RESET_IH_MASK);

            iowrite32(grbm_tmp, grbm_soft_reset);
            iowrite32(srbm_tmp, srbm_soft_reset);
            ioread32(srbm_soft_reset);
            ioread32(grbm_soft_reset);

            /* 5. HANDSHAKE: Poll mmGRBM_STATUS using clean mask comparisons */
            timeout = 1000;
            while (--timeout) {
                status_val = ioread32(grbm_status);
                if (!(status_val & GFX8_GRBM_STATUS__CP_BUSY_MASK) &&
                    !(status_val & GFX8_GRBM_STATUS__GUI_ACTIVE_MASK)) {
                    printk(KERN_EMERG "kexec: GPU CP and GFX pipelines reported IDLE at loop %d.\n", 1000 - timeout);
                    break;
                }
                udelay(5);
            }

            if (timeout == 0) {
                printk(KERN_EMERG "kexec: WARNING - GPU status handshake timed out! Status Reg: 0x%X\n", status_val);
            } else {
                printk(KERN_EMERG "kexec: GPU soft-reset completed safely via native macros.\n");
            }

            /* NO iounmap() needed. We are abandoning this kernel. */
            /* --- END GRBM SOFT RESET INJECTION --- */

            /* --- NEW VENDOR PCI CONFIG RESET --- */
            // printk(KERN_EMERG "kexec: Triggering AMDGPU Vendor PCI Config Reset (0x7c)...\n");
            // pci_write_config_dword(stoney_gpu_dev, 0x7c, AMDGPU_ASIC_RESET_DATA); /* AMDGPU_ASIC_RESET_DATA */

            // /* Give the SMU microcontroller time to boot its firmware before we pivot */
            // mdelay(150);

            // pci_clear_master(stoney_gpu_dev);
            // pci_dev_put(stoney_gpu_dev);
    }
    //END FIXES
#endif

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
    /* Ensure phys_to_virt doesn't ingest the C-bit from cr3_phys */
    pgd = (unsigned long *)phys_to_virt(cr3_phys & ~sme_mask);
    if (p4d) {
        p4d[0] = virt_to_phys(pud) | sme_mask | 0x3;
        pgd[0] = virt_to_phys(p4d) | sme_mask | 0x3;
    } else {
        pgd[0] = virt_to_phys(pud) | sme_mask | 0x3;
    }

    asm volatile("mov %0, %%cr3" :: "r" (cr3_phys) : "memory");

    asm volatile(
        "mov %%cr4, %%rax\n\t"
        "btr $17, %%rax\n\t"
        "mov %%rax, %%cr4\n\t"
        ::: "rax", "memory"
    );

    printk(KERN_EMERG "kexec: Trampoline primed. Executing identity-mapped jump...\n");

    /* Point execution straight to our copied assembly block (offset 32 bytes past the control block) */
    jump_target = low_page_phys + 32;


    // don't release, we're jumping to a new kernel anyway so it doesn't matter.'

    /* CRITICAL FIX: Pass low_page_phys in %rdi and zero_page_phys in %rsi. 
     * This bypasses RIP-relative calculation discrepancies entirely!
     */
    /* Write back and invalidate all CPU cache lines to DRAM before disabling paging */
    asm volatile("wbinvd\n\t" ::: "memory");

    asm volatile(
        "cli\n\t"
        "movq %1, %%rdi\n\t"
        "movq %2, %%rsi\n\t"
        "jmp *%0\n\t"
        :
        : "r"(jump_target), "r"(low_page_phys), "r"(zero_page_phys)
        : "rdi", "rsi", "memory"
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
            printk(KERN_EMERG "kexec: Loading command line (Size: %llu bytes)\n", payload.size);
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
            printk(KERN_EMERG "kexec: Loading bzImage payload...\n");
            ret = load_user_to_scatter_buffer(&loaded_kernel, (void __user *)payload.user_buf, payload.size);
            if (ret) return ret;
            break;

        case KEXEC_IOC_LOAD_INITRD:
            printk(KERN_EMERG "kexec: Loading initramfs payload...\n");
            ret = load_user_to_scatter_buffer(&loaded_initrd, (void __user *)payload.user_buf, payload.size);
            if (ret) return ret;
            break;

        case KEXEC_IOC_EXECUTE:
            printk(KERN_EMERG "kexec: EXECUTE command received.\n");
            if (!loaded_kernel.virt_addrs) return -EINVAL;

            ret = setup_zero_page();
            if (ret) return ret;
            mdelay(2000);
            if (ptr_migrate_to_reboot_cpu) ptr_migrate_to_reboot_cpu();
            
#ifdef BOARD_NAME_GRUNT
            /* BARE-METAL UPGRADE: Find the GPU and store it in our global pointer */
            stoney_gpu_dev = pci_get_device(0x1002, 0x98E4, NULL);
            if (stoney_gpu_dev) {
                if (stoney_gpu_dev->dev.driver) {
                    printk(KERN_EMERG "kexec: Intercepted AMD GPU! Nullifying shutdown hook...\n");
                    // stoney_gpu_dev->dev.driver->shutdown = NULL;
                }

                /* Force the kernel to wake the GPU and assign PCI resources */
                if (pci_enable_device(stoney_gpu_dev)) {
                    printk(KERN_EMERG "kexec: WARNING - Failed to enable GPU PCI device!\n");
                } else {
                    printk(KERN_EMERG "kexec: Successfully enabled GPU PCI device.\n");
                }

                phys_addr_t mmio_start = 0;
                resource_size_t mmio_len = 0;

                /* 1. Try standard kernel resource tree (BAR 5 then BAR 2) */
                if (pci_resource_flags(stoney_gpu_dev, 5) & IORESOURCE_MEM) {
                    mmio_start = pci_resource_start(stoney_gpu_dev, 5);
                    mmio_len = pci_resource_len(stoney_gpu_dev, 5);
                } else if (pci_resource_flags(stoney_gpu_dev, 2) & IORESOURCE_MEM) {
                    mmio_start = pci_resource_start(stoney_gpu_dev, 2);
                    mmio_len = pci_resource_len(stoney_gpu_dev, 2);
                }
                /* 2. BARE-METAL FALLBACK: Kernel tree is empty. Read the raw PCI config registers! */
                else {
                    u32 bar_val;
                    printk(KERN_EMERG "kexec: Kernel PCI tree empty! Bypassing kernel and reading RAW hardware BARs...\n");

                    /* Try RAW BAR 5 (Offset 0x24) */
                    pci_read_config_dword(stoney_gpu_dev, PCI_BASE_ADDRESS_5, &bar_val);
                    if (bar_val && !(bar_val & PCI_BASE_ADDRESS_SPACE_IO)) {
                        mmio_start = bar_val & PCI_BASE_ADDRESS_MEM_MASK;
                    } else {
                        /* Try RAW BAR 2 (Offset 0x18) */
                        pci_read_config_dword(stoney_gpu_dev, PCI_BASE_ADDRESS_2, &bar_val);
                        if (bar_val && !(bar_val & PCI_BASE_ADDRESS_SPACE_IO)) {
                            mmio_start = bar_val & PCI_BASE_ADDRESS_MEM_MASK;
                            /* Check if BAR 2 is 64-bit and stitch the high bits if needed */
                            if ((bar_val & PCI_BASE_ADDRESS_MEM_TYPE_MASK) == PCI_BASE_ADDRESS_MEM_TYPE_64) {
                                u32 bar_val_hi;
                                pci_read_config_dword(stoney_gpu_dev, PCI_BASE_ADDRESS_2 + 4, &bar_val_hi);
                                mmio_start |= ((phys_addr_t)bar_val_hi << 32);
                            }
                        }
                    }
                    /* Standard AMD MMIO window size is 256KB */
                    mmio_len = 0x40000;
                }

                if (mmio_start) {
                    printk(KERN_EMERG "kexec: Pre-mapping GPU MMIO at physical 0x%llx...\n", (unsigned long long)mmio_start);
                    stoney_mmio_base = ioremap(mmio_start, mmio_len);

                    if (!stoney_mmio_base) {
                        printk(KERN_EMERG "kexec: WARNING - ioremap failed for GPU MMIO!\n");
                    }
                } else {
                    printk(KERN_EMERG "kexec: FATAL - Could not find MMIO base address in hardware or kernel!\n");
                }
            }
#endif
            mdelay(2000);
            /* BARE-METAL UPGRADE: Re-enabling ptr_device_shutdown to properly shutdown devices.*/
            if (ptr_device_shutdown) ptr_device_shutdown();
            
#ifdef BOARD_NAME_GRUNT
            if (stoney_gpu_dev) {
                u16 cmd;
                /* * The native shutdown hook put the SMU to sleep safely, but it also
                 * called pci_disable_device() (turning off MMIO) and possibly put the GPU in D3hot.
                 * We must wake it up and forcefully re-enable the PCI memory space so
                 * our trampoline can access the GRBM!
                 */
                pci_set_power_state(stoney_gpu_dev, PCI_D0);
                pci_read_config_word(stoney_gpu_dev, PCI_COMMAND, &cmd);
                if (!(cmd & PCI_COMMAND_MEMORY)) {
                    pci_write_config_word(stoney_gpu_dev, PCI_COMMAND, cmd | PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);
                    printk(KERN_EMERG "kexec: Forcefully re-enabled GPU PCI Memory Space for Trampoline.\n");
                }
            }
#endif

            printk(KERN_EMERG "kexec: Waiting for secondary cores to halt...\n");
            mdelay(100);
            


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

/* * Clean Initialization Core.
 * This is the actual functional setup block. 
 * We remove the '__init' memory qualifier to prevent early memory page discarding,
 * allowing it to be safely called from the runtime parameter parsing context.
 */
int run_hijacked_initialization(void)
{
    int ret;

    if (oot_kexec_initialized) {
        return 0;
    }
    oot_kexec_initialized = 1;

    printk(KERN_EMERG "kexec: Hijack trigger received. Initializing custom kexec module...\n");

    /* Safety check: ensure userspace actually passed the address */
    if (kallsyms_addr == 0) {
        printk(KERN_EMERG "kexec: CRITICAL - kallsyms_addr parameter was not provided by loader!\n");
        return -EINVAL;
    }

    /* Cast the raw unsigned long into our callable function pointer */
    ptr_kallsyms_lookup_name = (kallsyms_lookup_name_t)kallsyms_addr;

    /* Resolve all symbols using custom pointer */
    ptr_device_shutdown = (void *)ptr_kallsyms_lookup_name("device_shutdown");
    ptr_syscore_shutdown = (void *)ptr_kallsyms_lookup_name("syscore_shutdown");
    ptr_migrate_to_reboot_cpu = (void *)ptr_kallsyms_lookup_name("migrate_to_reboot_cpu");
    ptr_smp_send_stop = (void *)ptr_kallsyms_lookup_name("smp_send_stop");
    ptr_native_stop_other_cpus = (void *)ptr_kallsyms_lookup_name("native_stop_other_cpus");
    ptr_lapic_shutdown = (void *)ptr_kallsyms_lookup_name("lapic_shutdown");
    ptr_screen_info = (struct screen_info *)ptr_kallsyms_lookup_name("screen_info");
    ptr_sme_me_mask = (unsigned long *)ptr_kallsyms_lookup_name("sme_me_mask");

    /* --- Comprehensive Symbol Logging --- */
    if (!ptr_device_shutdown) printk(KERN_WARNING "kexec: device_shutdown symbol missing!\n");
    if (!ptr_syscore_shutdown) printk(KERN_WARNING "kexec: syscore_shutdown symbol missing!\n");
    if (!ptr_migrate_to_reboot_cpu) printk(KERN_WARNING "kexec: migrate_to_reboot_cpu symbol missing!\n");
    if (!ptr_lapic_shutdown) printk(KERN_WARNING "kexec: lapic_shutdown symbol missing!\n");
    
    if (!ptr_screen_info) {
        printk(KERN_WARNING "kexec: screen_info not found. Display might be corrupted after pivot.\n");
    }

    if (!ptr_sme_me_mask) {
        printk(KERN_INFO "kexec: sme_me_mask symbol missing. (Normal if SME is disabled or non-AMD CPU).\n");
    }

    /* --- SMP Stop Logic Logging --- */
    if (!ptr_smp_send_stop) {
        printk(KERN_WARNING "kexec: smp_send_stop symbol missing! Falling back to native_stop_other_cpus.\n");
    }
    if (!ptr_native_stop_other_cpus) {
        printk(KERN_WARNING "kexec: native_stop_other_cpus symbol missing!\n");
    }
    if (!ptr_smp_send_stop && !ptr_native_stop_other_cpus) {
        printk(KERN_EMERG "kexec: CRITICAL WARNING - Secondary cores cannot be halted! Pivot may be unstable.\n");
    }

    /* Force the zero page to be allocated above 16MB boundary */
    zero_page_virt = (void *)get_safe_high_page(GFP_DMA32 | __GFP_ZERO);
    if (!zero_page_virt) {
        printk(KERN_EMERG "kexec: Failed to allocate zero page.\n");
        return -ENOMEM;
    }
    zero_page_phys = virt_to_phys(zero_page_virt);
    set_memory_decrypted((unsigned long)zero_page_virt, 1);
    ret = misc_register(&kexec_misc_device);
    if (ret) {
        printk(KERN_EMERG "kexec: misc_register failed (%d)\n", ret);
        free_page((unsigned long)zero_page_virt);
        return ret;
    }
    
#ifdef BOARD_NAME_GRUNT
    printk(KERN_EMERG "kexec: Compiled for BOARD_NAME_GRUNT. amdgpu reset ACTIVE.\n");
#endif

    printk(KERN_EMERG "kexec: Module loaded successfully. Device node created.\n");
    return 0;
}
/* * Parameter Setter Hijack Wrapper.
 * This function handles parameter parsing during finit_module.
 * It executes our core module setup sequence natively within Ring 0.
 */
static int param_trigger_set(const char *val, const struct kernel_param *kp)
{
    return run_hijacked_initialization();
}

static const struct kernel_param_ops param_trigger_ops = {
    .set = param_trigger_set,
};

/* * Register the custom parameter callback.
 * This places our callback routine inside the stable '__param' section.
 * When finit_loader passes "trigger_init=1", the kernel executes 'param_trigger_set'.
 */
module_param_cb(trigger_init, &param_trigger_ops, NULL, 0444);

/* * Standard Fallbacks.
 * We preserve empty macros to satisfy basic Kbuild metadata linking requirements.
 */
static int __init dummy_kexec_init(void)
{
    return 0;
}

static void __exit dummy_kexec_exit(void)
{
    if (kernel_cmdline) kfree(kernel_cmdline);
    free_scatter_buffer(&loaded_kernel);
    free_scatter_buffer(&loaded_initrd);

    if (zero_page_virt) {
        if (ptr_sme_me_mask && *ptr_sme_me_mask != 0) {
            set_memory_encrypted((unsigned long)zero_page_virt, 1);
        }
        free_page((unsigned long)zero_page_virt);
    }

    misc_deregister(&kexec_misc_device);
    printk(KERN_EMERG "kexec: Module unloaded.\n");
}

module_init(dummy_kexec_init);
module_exit(dummy_kexec_exit);

/* ==============================================================================
 * UNIFIED SYSTEM TRANSITION TRAMPOLINE (GLOBAL ASSEMBLY BLOCK)
 * ==============================================================================
 * Clean, register-driven transition assembly block. 
 * Eliminates all relative IP compiler assumptions.
 * ==============================================================================
 */
asm(
    ".code64\n"
    ".align 8\n"
    ".globl trampoline_start\n"
    "trampoline_start:\n"
    "    cli\n"
    
    /* Input registers passed cleanly from C (bypasses relative memory leaks):
     * %rdi = low_page_phys
     * %rsi = zero_page_phys
     */
    "    movq %rdi, %rax\n"          /* Keep low_page_phys copy in %rax */
    "    movq %rsi, %rbx\n"          /* Store zero_page_phys in %rbx across transition */
    
    /* Dynamically patch the absolute physical address of our GDT into our GDT descriptor */
    "    lea gdt_desc(%rip), %rdx\n"
    "    movq %rax, %rcx\n"          /* %rcx = low_page_phys */
    "    addq $(32 + gdt_start - trampoline_start), %rcx\n" /* Accounting for 32-byte structural header */
    "    movq %rcx, 2(%rdx)\n"       /* Patch absolute GDT physical address */
    "    lgdt (%rdx)\n"              /* Load GDT */
    
    /* Setup GDT transition Stack (low_page_phys + 2048) */
    "    movq %rax, %rsp\n"
    "    addq $2048, %rsp\n"
    
    /* Setup Far Return Frame (lretq) */
    "    movq %rax, %rcx\n"
    "    addq $(32 + compat_mode_start - trampoline_start), %rcx\n"
    "    pushq $0x10\n"              /* Target CS (32-bit CS is at index 0x10) */
    "    pushq %rcx\n"               /* Target instruction pointer */
    "    lretq\n"                    /* Transition to 32-bit Compatibility Mode */

    ".align 8\n"
    "gdt_start:\n"
    "    .quad 0x0000000000000000\n" /* Null Segment */
    "    .quad 0x00af9b000000ffff\n" /* 64-bit CS (0x08) */
    "    .quad 0x00cf9a000000ffff\n" /* 32-bit CS (0x10) */
    "    .quad 0x00cf92000000ffff\n" /* 32-bit DS/SS (0x18) */
    "gdt_desc:\n"
    "    .word 31\n"                 /* GDT Limit (4 Segments) */
    "    .quad 0\n"                  /* GDT Physical Base */

    ".code32\n"
    "compat_mode_start:\n"
    "    movl $0x18, %eax\n"         /* Load DS selector (32-bit Data) */
    "    movl %eax, %ds\n"
    "    movl %eax, %es\n"
    "    movl %eax, %ss\n"
    "    movl %eax, %fs\n"
    "    movl %eax, %gs\n"
    
    /* Disable Paging (Clear PG bit in CR0) */
    "    movl %cr0, %eax\n"
    "    andl $0x7fffffff, %eax\n"
    "    movl %eax, %cr0\n"
    "    jmp 1f\n"                   /* Flush prefetch queue */
    "1:\n"
    
    /* Disable Long Mode in EFER MSR */
    "    movl $0xc0000080, %ecx\n"
    "    rdmsr\n"
    "    andl $0xfffffeff, %eax\n"   /* Clear LME bit */
    "    wrmsr\n"
    
    /* Setup standard boot environment registers */
    "    movl %ebx, %esi\n"          /* ESI = Zero Page physical pointer */
    "    movl $0x90000, %esp\n"      /* Safe stable 32-bit kernel boot stack */
    
    /* Clear boots registers */
    "    xorl %ebx, %ebx\n"
    "    xorl %ecx, %ecx\n"
    "    xorl %edx, %edx\n"
    "    xorl %edi, %edi\n"
    "    xorl %ebp, %ebp\n"
    
    /* --- PHYSICAL DIAGNOSTIC STALL LOOP --- */
    "    movl $3000000000, %ecx\n"
    "delay_loop:\n"
    "    nop\n"
    "    decl %ecx\n"
    "    jnz delay_loop\n"
    
    /* Jump into 32-bit kernel entry */
    "    movl $0x100000, %eax\n"
    "    jmpl *%eax\n"

    ".code64\n"                      /* Restore assembly state back to 64-bit */
    ".globl trampoline_end\n"
    "trampoline_end:\n"
);
