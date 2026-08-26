// SPDX-License-Identifier: GPL-2.0-or-later

//     custom_kexec.c: userspace program that interacts with kexec_mod.c
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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>      /* For open() */
#include <unistd.h>     /* For close() */
#include <sys/ioctl.h>  /* For ioctl() */
#include <sys/stat.h>   /* For stat() */

/* Include our shared IOCTL definitions */
#include "../kexec_ioctl.h"

/* * Helper function to read a complete binary file into a newly allocated heap buffer.
 * It returns the pointer to the buffer, and writes the size of the file to 'size_out'.
 */
static unsigned char *read_file_to_buffer(const char *filepath, size_t *size_out)
{
    struct stat st;
    FILE *file;
    unsigned char *buffer;

    /* Get file status to determine the size */
    if (stat(filepath, &st) < 0) {
        fprintf(stderr, "[-] Failed to stat file: %s\n", filepath);
        return NULL;
    }

    file = fopen(filepath, "rb");
    if (!file) {
        fprintf(stderr, "[-] Failed to open file: %s\n", filepath);
        return NULL;
    }

    buffer = malloc(st.st_size);
    if (!buffer) {
        fprintf(stderr, "[-] Out of memory while allocating %ld bytes for %s\n", st.st_size, filepath);
        fclose(file);
        return NULL;
    }

    if (fread(buffer, 1, st.st_size, file) != st.st_size) {
        fprintf(stderr, "[-] Short read error while reading %s\n", filepath);
        free(buffer);
        fclose(file);
        return NULL;
    }

    fclose(file);
    *size_out = st.st_size;
    return buffer;
}

int main(int argc, char *argv[])
{
    int fd;
    struct kexec_payload payload;
    int ret;

    unsigned char *kernel_data = NULL;
    size_t kernel_size = 0;

    unsigned char *initrd_data = NULL;
    size_t initrd_size = 0;

    const char *kernel_path = "/boot/target_bzImage";
    const char *initrd_path = "/boot/target_initrd.cpio.gz";
    
    /* Base command line parameters to preserve safe keyboard reset and debugging capabilities */
    const char *base_cmdline = "console=tty0 console=ttyS0,115200 root=/dev/ram0 debug reset_devices i8042.reset i8042.nomux i8042.nopnp i8042.noloop debug";
    char cmdline[2048];

    /* Copy base command line to our working buffer safely */
    strncpy(cmdline, base_cmdline, sizeof(cmdline) - 1);
    cmdline[sizeof(cmdline) - 1] = '\0';

    /* Parse potential command-line parameters to dynamically append target consoles */
    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "--console") == 0 || strcmp(argv[i], "-c") == 0) && i + 1 < argc) {
            size_t current_len = strlen(cmdline);
            snprintf(cmdline + current_len, sizeof(cmdline) - current_len, " %s", argv[i + 1]);
            break;
        }
    }

    printf("========================================================\n");
    printf("   Starting Custom Kexec User-Space Loader\n");
    printf("========================================================\n");
    printf("[*] Configured Command Line:\n    %s\n\n", cmdline);

    /* ---------------------------------------------------------
     * PHASE 1: Load Files into Memory
     * --------------------------------------------------------- */
    printf("[*] Loading target kernel: %s...\n", kernel_path);
    kernel_data = read_file_to_buffer(kernel_path, &kernel_size);
    if (!kernel_data) {
        return EXIT_FAILURE;
    }
    printf("[+] Successfully read target kernel (%zu bytes)\n", kernel_size);

    printf("[*] Loading target initramfs: %s...\n", initrd_path);
    initrd_data = read_file_to_buffer(initrd_path, &initrd_size);
    if (!initrd_data) {
        free(kernel_data);
        return EXIT_FAILURE;
    }
    printf("[+] Successfully read target initramfs (%zu bytes)\n", initrd_size);

    /* ---------------------------------------------------------
     * PHASE 2: Interact with our Kernel Module
     * --------------------------------------------------------- */
    printf("[*] Opening communication device /dev/custom_kexec...\n");
    fd = open("/dev/custom_kexec", O_RDWR);
    if (fd < 0) {
        perror("[-] Failed to open device! Is the custom_kexec module loaded?");
        free(kernel_data);
        free(initrd_data);
        return EXIT_FAILURE;
    }
    printf("[+] Device connected.\n");

    /* Send Command Line */
    payload.user_buf = (__u64)cmdline;
    payload.size = strlen(cmdline) + 1; /* Include null-terminator */
    printf("[*] Configuring target command line arguments...\n");
    ret = ioctl(fd, KEXEC_IOC_SET_CMDLINE, &payload);
    if (ret < 0) {
        perror("[-] Failed to set command line");
        goto cleanup;
    }

    /* Send Real bzImage payload */
    payload.user_buf = (__u64)kernel_data;
    payload.size = (__u64)kernel_size;
    printf("[*] Transferring target kernel image to system RAM...\n");
    ret = ioctl(fd, KEXEC_IOC_LOAD_KERNEL, &payload);
    if (ret < 0) {
        perror("[-] Failed to load target kernel");
        goto cleanup;
    }

    /* Send Real initrd payload */
    payload.user_buf = (__u64)initrd_data;
    payload.size = (__u64)initrd_size;
    printf("[*] Transferring target initramfs image to system RAM...\n");
    ret = ioctl(fd, KEXEC_IOC_LOAD_INITRD, &payload);
    if (ret < 0) {
        perror("[-] Failed to load target initramfs");
        goto cleanup;
    }

    /* Execute the Pivot (The Point of No Return) */
    printf("[!] Preparing system for kexec execution...\n");
    printf("[!] Ready. Initiating target kernel handoff NOW.\n");
    ret = ioctl(fd, KEXEC_IOC_EXECUTE);
    if (ret < 0) {
        perror("[-] Execution failed during system teardown");
        goto cleanup;
    }

    printf("[+] Interface operations finished.\n");

cleanup:
    close(fd);
    free(kernel_data);
    free(initrd_data);
    return ret < 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}
