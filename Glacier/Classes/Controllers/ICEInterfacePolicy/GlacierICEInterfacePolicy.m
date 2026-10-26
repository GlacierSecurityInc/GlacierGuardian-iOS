#import "GlacierICEInterfacePolicy.h"
#import "GlacierICEInterfaceFilter.h"
#import "GlacierICESymbolRebinding.h"
#import <Network/Network.h>
#import <mach-o/dyld.h>
#import <net/if.h>
#import <os/log.h>
#import <pthread.h>
#import <stdatomic.h>
#import <string.h>
#import <dlfcn.h>
#import <errno.h>
#import <netinet/in.h>

static pthread_mutex_t pathLock = PTHREAD_MUTEX_INITIALIZER;
static char activeCellularInterface[IFNAMSIZ];
static char defaultPathCellular[IFNAMSIZ];
static char cellularOnlyPathCellular[IFNAMSIZ];
static nw_path_monitor_t defaultMonitor;
static nw_path_monitor_t cellularMonitor;
static dispatch_queue_t monitorQueue;
static dispatch_group_t firstPathReports;
static atomic_bool firstPathReportsSettled;
static atomic_uint_fast64_t enumerationCount;
static atomic_size_t lastHiddenCount = ATOMIC_VAR_INIT(SIZE_MAX);
static int (*systemGetifaddrs)(struct ifaddrs **);
static int (*systemBind)(int, const struct sockaddr *, socklen_t);

// Path monitors report asynchronously after launch. Until both have reported,
// no cellular interface is allowed, so a call set up right after a cold launch
// could gather without cellular. Wait briefly, once, for the first reports;
// after that (or after the timeout) this returns immediately.
static void awaitFirstPathReports(void) {
    if (atomic_load(&firstPathReportsSettled)) return;
    long timedOut = dispatch_group_wait(firstPathReports, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC));
    if (!atomic_exchange(&firstPathReportsSettled, true) && timedOut)
        os_log_info(OS_LOG_DEFAULT, "[ICEPath] path reports not ready after 200 ms; continuing without cellular");
}

static int filteredGetifaddrs(struct ifaddrs **interfaces) {
    awaitFirstPathReports();
    int result = systemGetifaddrs(interfaces);
    if (result != 0 || !interfaces) return result;
    char active[IFNAMSIZ];
    pthread_mutex_lock(&pathLock);
    memcpy(active, activeCellularInterface, sizeof(active));
    pthread_mutex_unlock(&pathLock);
    size_t hidden = GlacierICEFilterInactiveCellular(*interfaces, active[0] ? active : NULL);
    atomic_fetch_add(&enumerationCount, 1);
    if (atomic_exchange(&lastHiddenCount, hidden) != hidden) {
        os_log_info(OS_LOG_DEFAULT, "[ICEPath] filtered cellular entries=%{public}lu; path ready=%{public}d",
                    (unsigned long)hidden, active[0] != 0);
        for (struct ifaddrs *entry = *interfaces; entry; entry = entry->ifa_next) {
            if (entry->ifa_name && strncmp(entry->ifa_name, "pdp_ip", 6) == 0) {
                os_log_info(OS_LOG_DEFAULT, "[ICEPath] SDK cellular interface=%{public}s family=%{public}u running=%{public}d",
                    entry->ifa_name, entry->ifa_addr ? entry->ifa_addr->sa_family : 0,
                    (entry->ifa_flags & IFF_RUNNING) != 0);
            }
        }
    }
    return result;
}

static int filteredBind(int descriptor, const struct sockaddr *source, socklen_t length) {
    bool validLength = source && ((source->sa_family == AF_INET && length >= sizeof(struct sockaddr_in)) ||
        (source->sa_family == AF_INET6 && length >= sizeof(struct sockaddr_in6)));
    if (validLength) {
        awaitFirstPathReports();
        struct ifaddrs *interfaces = NULL;
        if (systemGetifaddrs(&interfaces) != 0) {
            // Let the native call fail through the normal ICE error path, without
            // risking an unverified cellular source during an enumeration failure.
            errno = EADDRNOTAVAIL;
            return -1;
        }
        char active[IFNAMSIZ];
        pthread_mutex_lock(&pathLock);
        memcpy(active, activeCellularInterface, sizeof(active));
        pthread_mutex_unlock(&pathLock);
        bool allowed = GlacierICECellularSourceAllowed(interfaces, source, active[0] ? active : NULL);
        freeifaddrs(interfaces);
        if (!allowed) {
            os_log_info(OS_LOG_DEFAULT, "[ICEPath] refused inactive cellular source binding");
            errno = EADDRNOTAVAIL;
            return -1;
        }
    }
    return systemBind(descriptor, source, length);
}

// Runs on monitorQueue. Records the path's cellular interface (empty when the
// path is unsatisfied or doesn't use cellular), then republishes the selection.
static nw_path_monitor_t startPathMonitor(nw_path_monitor_t monitor, char *slot) {
    __block bool reported = false;
    dispatch_group_enter(firstPathReports);
    nw_path_monitor_set_queue(monitor, monitorQueue);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        char selected[IFNAMSIZ] = {0};
        char *selectedName = selected;
        if (nw_path_get_status(path) == nw_path_status_satisfied &&
            nw_path_uses_interface_type(path, nw_interface_type_cellular)) {
            nw_path_enumerate_interfaces(path, ^bool(nw_interface_t interface) {
                if (nw_interface_get_type(interface) == nw_interface_type_cellular) {
                    strlcpy(selectedName, nw_interface_get_name(interface), IFNAMSIZ);
                    return false;
                }
                return true;
            });
        }
        memcpy(slot, selected, sizeof(selected));
        const char *active = GlacierICESelectActiveCellular(defaultPathCellular, cellularOnlyPathCellular);
        pthread_mutex_lock(&pathLock);
        strlcpy(activeCellularInterface, active ? active : "", sizeof(activeCellularInterface));
        pthread_mutex_unlock(&pathLock);
        os_log_info(OS_LOG_DEFAULT, "[ICEPath] cellular default=%{public}s cellular-only=%{public}s active=%{public}s",
                    defaultPathCellular, cellularOnlyPathCellular, active ? active : "");
        if (!reported) {
            reported = true;
            dispatch_group_leave(firstPathReports);
        }
    });
    nw_path_monitor_start(monitor);
    return monitor;
}

@implementation GlacierICEInterfacePolicy
+ (void)startMonitoring {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The default path names the cellular context the app is actually using.
        // While Wi-Fi is the default, the cellular-only path names the context the
        // system would hand app traffic to, so ICE keeps it as a backup and can fail
        // over without waiting for re-enumeration. Auxiliary contexts stay hidden
        // either way. Continual ICE gathering follows handoffs as these change.
        monitorQueue = dispatch_queue_create("com.glacier.ice.cellular-path", DISPATCH_QUEUE_SERIAL);
        firstPathReports = dispatch_group_create();
        defaultMonitor = startPathMonitor(nw_path_monitor_create(), defaultPathCellular);
        cellularMonitor = startPathMonitor(nw_path_monitor_create_with_type(nw_interface_type_cellular), cellularOnlyPathCellular);
    });
}

+ (BOOL)install {
    [self startMonitoring];
    static dispatch_once_t once;
    static BOOL installed;
    dispatch_once(&once, ^{
        // The SDK has no public per-interface allowlist. Rebind only WebRTC's
        // getifaddrs import, leaving the app, other SDKs and OS networking untouched.
        // This also closes the SDK monitor's cold-start fail-open enumeration window.
        systemGetifaddrs = getifaddrs;
        systemBind = bind;
        size_t enumerationRebound = 0, bindRebound = 0;
        struct glacier_ice_rebinding bindings[] = {
            {"getifaddrs", filteredGetifaddrs, NULL, &enumerationRebound},
            {"bind", filteredBind, NULL, &bindRebound}
        };
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            const char *name = _dyld_get_image_name(i);
            if (name && strstr(name, "/WebRTC.framework/") &&
                strcmp(strrchr(name, '/'), "/WebRTC") == 0) {
                glacier_ice_rebind_symbols_image((void *)_dyld_get_image_header(i),
                    _dyld_get_image_vmaddr_slide(i), bindings, 2);
            }
        }
        installed = enumerationRebound > 0 && bindRebound > 0;
        os_log_info(OS_LOG_DEFAULT, "[ICEPath] WebRTC enumeration policy installed=%{public}d", installed);
    });
    return installed;
}

+ (uint64_t)enumerationCount { return atomic_load(&enumerationCount); }
@end
