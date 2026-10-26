// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * devmem <addr> [value]: read or write one 32-bit register through /dev/mem.
 * The panther boot stage's only use is DECON0's TRIG_CON, so the bootloader
 * framebuffer is scanned out again (busybox here has no devmem applet).
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc < 2 || argc > 3) {
		fprintf(stderr, "usage: devmem <addr> [value]\n");
		return 2;
	}
	uint64_t addr = strtoull(argv[1], NULL, 0);
	long page = sysconf(_SC_PAGESIZE);
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	uint64_t base = addr & ~(uint64_t)(page - 1);
	void *map = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
	if (map == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	volatile uint32_t *reg = (volatile uint32_t *)((char *)map + (addr - base));
	if (argc == 3) {
		*reg = (uint32_t)strtoul(argv[2], NULL, 0);
	}
	printf("0x%08x\n", *reg);
	munmap(map, page);
	close(fd);
	return 0;
}
