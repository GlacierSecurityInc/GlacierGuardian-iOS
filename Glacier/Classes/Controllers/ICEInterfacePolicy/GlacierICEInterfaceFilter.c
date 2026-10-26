#include "GlacierICEInterfaceFilter.h"
#include <net/if.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>

static int isCellular(const char *name) {
    if (!name || strncmp(name, "pdp_ip", 6) != 0 || name[6] == '\0') return 0;
    for (const char *p = name + 6; *p; ++p) if (*p < '0' || *p > '9') return 0;
    return 1;
}

size_t GlacierICEFilterInactiveCellular(struct ifaddrs *interfaces, const char *activeCellularInterface) {
    size_t hidden = 0;
    for (struct ifaddrs *entry = interfaces; entry; entry = entry->ifa_next) {
        if (isCellular(entry->ifa_name) &&
            (!activeCellularInterface || strcmp(entry->ifa_name, activeCellularInterface) != 0)) {
            if (entry->ifa_flags & IFF_RUNNING) ++hidden;
            // WebRTC checks IFF_RUNNING before creating a Network/ICE socket.
            // Keep the list and its allocations intact for Darwin freeifaddrs.
            entry->ifa_flags &= ~IFF_RUNNING;
            if (entry->ifa_addr) entry->ifa_addr->sa_family = AF_UNSPEC;
        }
    }
    return hidden;
}

bool GlacierICECellularSourceAllowed(const struct ifaddrs *interfaces, const struct sockaddr *source, const char *activeCellularInterface) {
    bool cellularSource = false;
    if (!source || (source->sa_family != AF_INET && source->sa_family != AF_INET6)) return true;
    for (const struct ifaddrs *entry = interfaces; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != source->sa_family || !isCellular(entry->ifa_name)) continue;
        bool same = source->sa_family == AF_INET
            ? ((const struct sockaddr_in *)source)->sin_addr.s_addr == ((const struct sockaddr_in *)entry->ifa_addr)->sin_addr.s_addr
            : memcmp(&((const struct sockaddr_in6 *)source)->sin6_addr, &((const struct sockaddr_in6 *)entry->ifa_addr)->sin6_addr, sizeof(struct in6_addr)) == 0;
        if (!same) continue;
        cellularSource = true;
        if (activeCellularInterface && strcmp(entry->ifa_name, activeCellularInterface) == 0) return true;
    }
    return !cellularSource;
}

const char *GlacierICESelectActiveCellular(const char *defaultPathCellular, const char *cellularOnlyPathCellular) {
    if (defaultPathCellular && defaultPathCellular[0]) return defaultPathCellular;
    if (cellularOnlyPathCellular && cellularOnlyPathCellular[0]) return cellularOnlyPathCellular;
    return NULL;
}
