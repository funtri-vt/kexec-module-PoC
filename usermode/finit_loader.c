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

    /* * PASS IN THE PARAMETER TRIGGER:
     * Instead of an empty string, we pass "trigger_init=1" as our loader argument.
     * When finit_module maps the module, it immediately runs the 'trigger_init' 
     * parameter callback block in Ring 0, bypassing the struct module offset table!
     */
    long rc = syscall(__NR_finit_module, fd, "trigger_init=1", 0);
    
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