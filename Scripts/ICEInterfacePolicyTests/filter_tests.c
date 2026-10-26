#include "GlacierICEInterfaceFilter.h"
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>

static void check(int ok, const char *description) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", description); exit(1); }
}
int main(void) {
    const char *names[] = {"pdp_ip0", "pdp_ip0", "pdp_ip1", "pdp_ip1", "en0", "utun3", "lo0", "pdp_ip10", "pdp_ipBackup"};
    struct ifaddrs rows[9] = {0};
    struct sockaddr addresses[9] = {0};
    for (size_t i = 0; i < 9; i++) {
        rows[i].ifa_name = (char *)names[i];
        addresses[i].sa_family = i % 2 == 0 ? AF_INET : AF_INET6;
        rows[i].ifa_addr = &addresses[i];
        rows[i].ifa_flags = IFF_UP | IFF_RUNNING | IFF_MULTICAST;
        rows[i].ifa_next = i < 8 ? &rows[i + 1] : NULL;
    }
    GlacierICEFilterInactiveCellular(rows, "pdp_ip0");
    check(!(rows[2].ifa_flags & IFF_RUNNING) && !(rows[3].ifa_flags & IFF_RUNNING), "inactive cellular IPv4/IPv6 must be hidden before ICE opens sockets");
    check(rows[2].ifa_addr->sa_family == AF_UNSPEC && rows[3].ifa_addr->sa_family == AF_UNSPEC, "inactive addresses cannot be converted by the SDK even if it ignores flags");
    check((rows[0].ifa_flags & IFF_RUNNING) && (rows[1].ifa_flags & IFF_RUNNING), "active cellular retains both address families");
    check(!(rows[7].ifa_flags & IFF_RUNNING), "multi-digit auxiliary cellular interface is excluded");
    for (size_t i = 4; i < 7; i++) check(rows[i].ifa_flags & IFF_RUNNING, "Wi-Fi, VPN and loopback flags must be preserved");
    check(rows[8].ifa_flags & IFF_RUNNING, "non-cellular names with similar prefix are preserved");
    for (size_t i = 0; i < 9; i++) rows[i].ifa_flags = IFF_UP | IFF_RUNNING;
    GlacierICEFilterInactiveCellular(rows, "pdp_ip1");
    check(!(rows[0].ifa_flags & IFF_RUNNING) && (rows[2].ifa_flags & IFF_RUNNING), "active path can switch to pdp_ip1; no hardcoded interface index");
    for (size_t i = 0; i < 9; i++) rows[i].ifa_flags = IFF_UP | IFF_RUNNING;
    GlacierICEFilterInactiveCellular(rows, NULL);
    check(!(rows[0].ifa_flags & IFF_RUNNING) && !(rows[2].ifa_flags & IFF_RUNNING), "unknown cellular path cannot expose auxiliary interfaces on cold start");
    check(rows[4].ifa_flags & IFF_RUNNING, "unknown cellular path preserves Wi-Fi");
    check(GlacierICEFilterInactiveCellular(NULL, "pdp_ip0") == 0, "empty enumeration is safe");
    struct sockaddr_in active4 = {.sin_family = AF_INET, .sin_addr.s_addr = 1};
    struct sockaddr_in inactive4 = {.sin_family = AF_INET, .sin_addr.s_addr = 2};
    struct sockaddr_in6 active6 = {.sin6_family = AF_INET6, .sin6_addr = IN6ADDR_LOOPBACK_INIT};
    struct sockaddr_in6 inactive6 = active6; inactive6.sin6_addr.s6_addr[15] = 2;
    struct ifaddrs sourceRows[] = {
        {.ifa_name="pdp_ip0", .ifa_addr=(struct sockaddr *)&active4},
        {.ifa_name="pdp_ip1", .ifa_addr=(struct sockaddr *)&inactive4},
        {.ifa_name="pdp_ip0", .ifa_addr=(struct sockaddr *)&active6},
        {.ifa_name="pdp_ip1", .ifa_addr=(struct sockaddr *)&inactive6}
    };
    for (size_t i=0; i<3; ++i) sourceRows[i].ifa_next=&sourceRows[i+1];
    check(GlacierICECellularSourceAllowed(sourceRows, (struct sockaddr *)&active4, "pdp_ip0"), "active IPv4 socket can bind");
    check(GlacierICECellularSourceAllowed(sourceRows, (struct sockaddr *)&active6, "pdp_ip0"), "active IPv6 socket can bind");
    check(!GlacierICECellularSourceAllowed(sourceRows, (struct sockaddr *)&inactive4, "pdp_ip0"), "inactive IPv4 socket bind is rejected");
    check(!GlacierICECellularSourceAllowed(sourceRows, (struct sockaddr *)&inactive6, "pdp_ip0"), "inactive IPv6 socket bind is rejected even for stale SDK networks");
    check(GlacierICECellularSourceAllowed(sourceRows, (struct sockaddr *)&inactive6, "pdp_ip1"), "socket guard follows new active interface");
    struct sockaddr_in wildcard = {.sin_family=AF_INET};
    check(GlacierICECellularSourceAllowed(sourceRows, (struct sockaddr *)&wildcard, NULL), "wildcard/default-route socket is preserved");
    check(!GlacierICECellularSourceAllowed(sourceRows, (struct sockaddr *)&active6, NULL), "unknown path rejects explicit cellular source bind");
    check(strcmp(GlacierICESelectActiveCellular("pdp_ip0", "pdp_ip1"), "pdp_ip0") == 0, "cellular default path wins over the cellular-only path");
    check(strcmp(GlacierICESelectActiveCellular("", "pdp_ip0"), "pdp_ip0") == 0, "on Wi-Fi the primary cellular context stays available as a backup");
    check(GlacierICESelectActiveCellular("", "") == NULL && GlacierICESelectActiveCellular(NULL, NULL) == NULL, "no known cellular path hides all cellular");
    for (size_t i = 0; i < 9; i++) rows[i].ifa_flags = IFF_UP | IFF_RUNNING;
    GlacierICEFilterInactiveCellular(rows, GlacierICESelectActiveCellular("", "pdp_ip0"));
    check((rows[0].ifa_flags & IFF_RUNNING) && (rows[4].ifa_flags & IFF_RUNNING), "Wi-Fi and primary cellular are both gathered on Wi-Fi");
    check(!(rows[2].ifa_flags & IFF_RUNNING) && !(rows[7].ifa_flags & IFF_RUNNING), "auxiliary cellular stays hidden on Wi-Fi");
    puts("PASS: active cellular filtering, Wi-Fi backup, handoff, cold start, both families, and non-cellular preservation");
}
