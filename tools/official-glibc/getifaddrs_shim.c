/* getifaddrs shim for running glibc binaries on Termux/Android.
 *
 * Android's app sandbox denies reads of /proc/net/dev and /sys/class/net.
 * glibc's getifaddrs(3) depends on those, so it fails. In opencode this shows
 * up as Bun's networkInterfaces() throwing, /api/info returning 500, and the
 * TUI hanging at "Starting background server...".
 *
 * Return a minimal loopback list (IPv4 + IPv6). Do NOT return an empty list:
 * Bun's resolver needs at least one address-bearing interface and otherwise
 * makes getaddrinfo() fail with EAI_AGAIN.
 *
 * Build with no dependencies so it can be LD_PRELOADed into a glibc process:
 *   clang --target=aarch64-linux-android -nostdlib -shared -fPIC \
 *     -I"$PREFIX/glibc/include" -o getifaddrs-shim.so getifaddrs_shim.c
 */

#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#include <stdlib.h>

struct ifaddrs_storage {
	struct ifaddrs ifa;
	struct sockaddr_in addr4;
	struct sockaddr_in mask4;
	struct sockaddr_in6 addr6;
	struct sockaddr_in6 mask6;
};

static void fill_v4(struct ifaddrs_storage *s) {
	memset(s, 0, sizeof(*s));
	s->ifa.ifa_name = (char *)"lo";
	s->ifa.ifa_flags = IFF_UP | IFF_LOOPBACK | IFF_RUNNING;
	s->addr4.sin_family = AF_INET;
	s->addr4.sin_addr.s_addr = htonl(0x7f000001u); /* 127.0.0.1 */
	s->mask4.sin_family = AF_INET;
	s->mask4.sin_addr.s_addr = htonl(0xff000000u); /* 255.0.0.0 */
	s->ifa.ifa_addr = (struct sockaddr *)&s->addr4;
	s->ifa.ifa_netmask = (struct sockaddr *)&s->mask4;
}

static void fill_v6(struct ifaddrs_storage *s) {
	memset(s, 0, sizeof(*s));
	s->ifa.ifa_name = (char *)"lo";
	s->ifa.ifa_flags = IFF_UP | IFF_LOOPBACK | IFF_RUNNING;
	s->addr6.sin6_family = AF_INET6;
	s->addr6.sin6_addr.s6_addr[15] = 1; /* ::1 */
	s->mask6.sin6_family = AF_INET6;
	memset(&s->mask6.sin6_addr, 0xff, 16);
	s->ifa.ifa_addr = (struct sockaddr *)&s->addr6;
	s->ifa.ifa_netmask = (struct sockaddr *)&s->mask6;
}

int getifaddrs(struct ifaddrs **ifap) {
	if (!ifap)
		return -1;

	struct ifaddrs_storage *a = calloc(1, sizeof(*a));
	struct ifaddrs_storage *b = calloc(1, sizeof(*b));
	if (!a || !b) {
		free(a);
		free(b);
		return -1;
	}

	fill_v4(a);
	fill_v6(b);
	a->ifa.ifa_next = &b->ifa;
	*ifap = &a->ifa;
	return 0;
}

void freeifaddrs(struct ifaddrs *ifa) {
	/* Each node was allocated separately; walk the next chain. */
	while (ifa) {
		struct ifaddrs *next = ifa->ifa_next;
		free(ifa);
		ifa = next;
	}
}
