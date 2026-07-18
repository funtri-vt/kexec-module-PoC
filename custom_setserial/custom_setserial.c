#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <strings.h> // For strcasecmp
#include <sys/ioctl.h>
#include <linux/serial.h>
#include <getopt.h>

// String-to-Int Switcher for Serial Types
int parse_type(const char *str) {
    if (!strcasecmp(str, "PORT_UNKNOWN") || !strcasecmp(str, "UNKNOWN")) return PORT_UNKNOWN;
    if (!strcasecmp(str, "PORT_8250")    || !strcasecmp(str, "8250"))    return PORT_8250;
    if (!strcasecmp(str, "PORT_16450")   || !strcasecmp(str, "16450"))   return PORT_16450;
    if (!strcasecmp(str, "PORT_16550")   || !strcasecmp(str, "16550"))   return PORT_16550;
    if (!strcasecmp(str, "PORT_16550A")  || !strcasecmp(str, "16550A"))  return PORT_16550A;
    if (!strcasecmp(str, "PORT_16650")   || !strcasecmp(str, "16650"))   return PORT_16650;
    if (!strcasecmp(str, "PORT_16750")   || !strcasecmp(str, "16750"))   return PORT_16750;
    if (!strcasecmp(str, "PORT_16850")   || !strcasecmp(str, "16850"))   return PORT_16850;
    // Fallback: parse as integer if it doesn't match known strings
    return strtol(str, NULL, 0);
}

// String-to-Int Switcher for IO Types
int parse_io_type(const char *str) {
    if (!strcasecmp(str, "SERIAL_IO_PORT") || !strcasecmp(str, "PORT"))    return SERIAL_IO_PORT;
    if (!strcasecmp(str, "SERIAL_IO_HUB6") || !strcasecmp(str, "HUB6"))    return SERIAL_IO_HUB6;
    if (!strcasecmp(str, "SERIAL_IO_MEM")  || !strcasecmp(str, "MEM"))     return SERIAL_IO_MEM;
    if (!strcasecmp(str, "SERIAL_IO_MEM32")|| !strcasecmp(str, "MEM32"))   return SERIAL_IO_MEM32;
    if (!strcasecmp(str, "SERIAL_IO_AU")   || !strcasecmp(str, "AU"))      return SERIAL_IO_AU;
    if (!strcasecmp(str, "SERIAL_IO_TSI")  || !strcasecmp(str, "TSI"))     return SERIAL_IO_TSI;
    // Fallback: parse as integer
    return strtol(str, NULL, 0);
}

void print_usage(const char *prog_name) {
    printf("Usage: %s <device> [options]\n", prog_name);
    printf("Options:\n");
    printf("  -t, --type <str|int>      Set port type (e.g., 16550A or 4)\n");
    printf("  -o, --io-type <str|int>   Set IO type (e.g., MEM32 or 3)\n");
    printf("  -m, --iomem-base <addr>   Set MMIO base address (e.g., 0xfedc6000)\n");
    printf("  -s, --reg-shift <int>     Set register shift (e.g., 2)\n");
    printf("  -b, --baud-base <int>     Set baud base (e.g., 3000000)\n");
    printf("  -p, --port <addr>         Set standard I/O port (e.g., 0x3f8)\n");
    printf("  -h, --help                Show this help message\n");
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    const char *device = NULL;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] != '-') {
            device = argv[i];
            break;
        }
    }

    if (!device) {
        fprintf(stderr, "[-] No device specified.\n");
        print_usage(argv[0]);
        return 1;
    }

    int type = -1;
    int io_type = -1;
    unsigned long iomem_base = 0;
    int iomem_base_set = 0;
    int reg_shift = -1;
    int baud_base = -1;
    unsigned long port = 0;
    int port_set = 0;

    static struct option long_options[] = {
        {"type",       required_argument, 0, 't'},
        {"io-type",    required_argument, 0, 'o'},
        {"iomem-base", required_argument, 0, 'm'},
        {"reg-shift",  required_argument, 0, 's'},
        {"baud-base",  required_argument, 0, 'b'},
        {"port",       required_argument, 0, 'p'},
        {"help",       no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    int option_index = 0;
    while ((opt = getopt_long(argc, argv, "t:o:m:s:b:p:h", long_options, &option_index)) != -1) {
        switch (opt) {
            case 't': type = parse_type(optarg); break;
            case 'o': io_type = parse_io_type(optarg); break;
            case 'm': iomem_base = strtoul(optarg, NULL, 0); iomem_base_set = 1; break;
            case 's': reg_shift = strtol(optarg, NULL, 0); break;
            case 'b': baud_base = strtol(optarg, NULL, 0); break;
            case 'p': port = strtoul(optarg, NULL, 0); port_set = 1; break;
            case 'h': print_usage(argv[0]); return 0;
            default: return 1;
        }
    }

    int fd = open(device, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        perror("[-] Failed to open device");
        return 1;
    }

    struct serial_struct ser;
    
    if (ioctl(fd, TIOCGSERIAL, &ser) < 0) {
        perror("[-] Failed to get current serial struct (TIOCGSERIAL)");
        close(fd);
        return 1;
    }

    if (type != -1)       ser.type = type;
    if (io_type != -1)    ser.io_type = io_type;
    if (iomem_base_set)   ser.iomem_base = (void *)iomem_base;
    if (reg_shift != -1)  ser.iomem_reg_shift = reg_shift;
    if (baud_base != -1)  ser.baud_base = baud_base;
    if (port_set)         ser.port = port;

    if (ioctl(fd, TIOCSSERIAL, &ser) < 0) {
        perror("[-] Failed to set hardware map via ioctl (TIOCSSERIAL)");
        close(fd);
        return 1;
    }

    printf("[+] SUCCESS: %s successfully configured.\n", device);
    close(fd);
    return 0;
}
