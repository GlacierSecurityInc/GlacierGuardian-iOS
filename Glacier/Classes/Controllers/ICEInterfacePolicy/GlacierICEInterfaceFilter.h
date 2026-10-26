#ifndef GlacierICEInterfaceFilter_h
#define GlacierICEInterfaceFilter_h
#include <ifaddrs.h>
#include <stddef.h>
#include <sys/socket.h>
#include <stdbool.h>

// Only changes the SDK's private enumeration snapshot, never OS interface state.
size_t GlacierICEFilterInactiveCellular(struct ifaddrs *interfaces, const char *activeCellularInterface);
bool GlacierICECellularSourceAllowed(const struct ifaddrs *interfaces, const struct sockaddr *source, const char *activeCellularInterface);
// The default path's cellular interface wins; otherwise (e.g. on Wi-Fi) the
// cellular-only path's. NULL when neither is known, which hides all cellular.
const char *GlacierICESelectActiveCellular(const char *defaultPathCellular, const char *cellularOnlyPathCellular);
#endif
