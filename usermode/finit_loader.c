// SPDX-License-Identifier: GPL-2.0-or-later

//     finit_loader.c: userspace program designed for loading kexec_mod.c
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


#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/syscall.h>

#ifndef __NR_finit_module
#define __NR_finit_module 313
#endif

/* Helper to fetch the live memory address of a kernel symbol */
unsigned long get_kallsyms_address(const char *target_symbol) {
    FILE *fp = fopen("/proc/kallsyms", "r");
    if (!fp) {
        return 0; /* Failed to open */
    }

    char *line = NULL;
    size_t len = 0;
    unsigned long addr = 0;
    char type;
    char sym_name[256];
    unsigned long found_addr = 0;

    /* Read the file line by line */
    while (getline(&line, &len, fp) != -1) {
        /* Parse the hex address, symbol type, and symbol name */
        if (sscanf(line, "%lx %c %255s", &addr, &type, sym_name) == 3) {
            if (strcmp(sym_name, target_symbol) == 0) {
                found_addr = addr;
                break;
            }
        }
    }

    free(line);
    fclose(fp);
    return found_addr;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "[-] Usage: %s <path_to_module.ko>\n", argv[0]);
        return 1;
    }

    const char *module_path = argv[1];
    printf("[*] Attempting to open module: %s\n", module_path);

    int fd = open(module_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "[-] Failed to open file '%s': %s (errno: %d)\n", 
                module_path, strerror(errno), errno);
        return 1;
    }

    printf("[*] File opened successfully (FD: %d). Calling finit_module with trigger param...\n", fd);

    /* 1. Fetch the address */
    unsigned long kallsyms_addr = get_kallsyms_address("kallsyms_lookup_name");
    if (kallsyms_addr == 0) {
        fprintf(stderr, "[-] Failed to find kallsyms_lookup_name in /proc/kallsyms. Are you root?\n");
        close(fd);
        return 1;
    }
    printf("[*] Found kallsyms_lookup_name at: 0x%lx\n", kallsyms_addr);


    /* 2. Format the parameter string dynamically */
    char param_buf[256];
    /* IMPORTANT: kallsyms_addr must come before trigger_init=1 */
    snprintf(param_buf, sizeof(param_buf), "kallsyms_addr=%lu trigger_init=1", kallsyms_addr);

    printf("[*] Calling finit_module with params: '%s'\n", param_buf);

    /* 3. Pass the buffer to the syscall instead of the hardcoded string */
    long rc = syscall(__NR_finit_module, fd, param_buf, 0);

    if (rc != 0) {
        fprintf(stderr, "[-] finit_module failed: %s (errno: %d)\n", 
                strerror(errno), errno);
        close(fd);
        return 1;
    }

    printf("[+] Module loaded successfully!\n");
    close(fd);
    return 0;
}
