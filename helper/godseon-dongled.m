// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT
//
// godseon-dongled: GodseonDongle's root helper (launchd daemon, KeepAlive).
//   godseon-dongled <config-file>
//
// While the GodseonDongle app runs and asks for it, the daemon
//  1. hands the USB Wi-Fi dongle to the app's VM over USB/IP (TCP 9408). As root it captures
//     the device through IOUSBHost, so this works even while another app or driver holds it,
//     and no restricted entitlement is needed. Only the VM's address may connect.
//  2. keeps the Mac's IPv4 routes for the networks behind the dongle pointed at the VM.
// Once the app is gone it releases the dongle and removes the routes it added.
//
// Config, written by the app. The file is user-writable, so every value is validated:
//   owner=<pid>            the app; nothing is held unless this pid runs GodseonDongle
//   usb=0bda:b812          vendor:product of the dongle
//   guest=192.168.64.5     the VM's address on a vmnet bridge
//   route=192.168.50.0/24  repeatable
//   rx_filter=rtw88        optional: the dongle is an rtw88 RTL8822B/8821C/8822C (see below)
// Status for the app: /var/run/godseon-dongled.status (JSON, rewritten when it changes).
// Log: stderr (launchd sends it to /var/log/godseon-dongled.log).
//
// build: clang -fobjc-arc -O2 -Wall godseon-dongled.m -o godseon-dongled \
//            -framework Foundation -framework IOKit -framework IOUSBHost

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOUSBHost/IOUSBHost.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <libkern/OSByteOrder.h>
#include <libproc.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

enum {
    OP_REQ_DEVLIST = 0x8005, OP_REP_DEVLIST = 0x0005,
    OP_REQ_IMPORT = 0x8003, OP_REP_IMPORT = 0x0003,
    USBIP_VERSION = 0x0111,
    CMD_SUBMIT = 1, CMD_UNLINK = 2, RET_SUBMIT = 3, RET_UNLINK = 4,
    URB_ZERO_PACKET = 0x0040,
};

static const uint16_t kPort = 9408;
static const char *kBusid = "1-1";
static NSString *const kStatusPath = @"/var/run/godseon-dongled.status";
static NSString *const kOwnedRoutesPath = @"/var/run/godseon-dongled.routes";
static const double kStallSeconds = 6;           // a bulk OUT request waiting this long: the dongle stopped sending
static const double kResetSpacingSeconds = 120;  // at most one forced dongle reset per this long
static const double kSummarySeconds = 300;       // traffic summary in the log while the VM is connected

// ------------------------------------------------------------------ small helpers
static uint64_t nowNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static double secondsSince(uint64_t t) { return (double)(nowNs() - t) / 1e9; }

static void logmsg(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logmsg(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    char stamp[32];
    time_t t = time(NULL);
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(stderr, "%s %s\n", stamp, s.UTF8String);
}

static void put8(NSMutableData *d, uint8_t v) { [d appendBytes:&v length:1]; }
static void put16(NSMutableData *d, uint16_t v) { v = htons(v); [d appendBytes:&v length:2]; }
static void put32(NSMutableData *d, uint32_t v) { v = htonl(v); [d appendBytes:&v length:4]; }
static uint32_t get32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static uint16_t get16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

static BOOL readFull(int fd, void *buf, size_t len) {
    uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n == 0) return NO;
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        p += n; len -= (size_t)n;
    }
    return YES;
}

static BOOL writeFull(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        p += n; len -= (size_t)n;
    }
    return YES;
}

static BOOL parseIPv4(NSString *text, uint32_t *out) {
    struct in_addr a;
    if (text.length == 0 || text.length > 15 || inet_pton(AF_INET, text.UTF8String, &a) != 1) return NO;
    *out = ntohl(a.s_addr);
    return YES;
}

static NSString *formatIPv4(uint32_t v) {
    return [NSString stringWithFormat:@"%u.%u.%u.%u", v >> 24, (v >> 16) & 255, (v >> 8) & 255, v & 255];
}

static uint32_t maskOf(int prefix) { return prefix == 0 ? 0 : ~(UINT32_MAX >> prefix); }

/// "10.10.0.7/24" -> "10.10.0.0/24"; nil unless a.b.c.d/1..32.
static NSString *canonicalCIDR(NSString *text, uint32_t *network, int *prefixOut) {
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"/"];
    if (parts.count != 2) return nil;
    NSString *p = parts[1];
    if (p.length == 0 || p.length > 2
        || [p rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return nil;
    int prefix = p.intValue;
    uint32_t address;
    if (prefix < 1 || prefix > 32 || !parseIPv4(parts[0], &address)) return nil;
    uint32_t net = address & maskOf(prefix);
    if (network) *network = net;
    if (prefixOut) *prefixOut = prefix;
    return [NSString stringWithFormat:@"%@/%d", formatIPv4(net), prefix];
}

// ------------------------------------------------------------------ config
@interface Config : NSObject
@property (nonatomic) pid_t owner;
@property (nonatomic) uint16_t vid, pid;
@property (nonatomic) uint32_t guest;                  // host byte order, 0 = none
@property (nonatomic, copy) NSArray<NSString *> *routes;
@property (nonatomic) BOOL rxFilter;
@end
@implementation Config
@end

static NSString *gConfigPath;

static Config *readConfig(void) {
    Config *config = [Config new];
    config.routes = @[];
    // The file belongs to the user: never follow a link, read only a small regular file.
    int fd = open(gConfigPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return config;
    struct stat st;
    char buffer[8192];
    ssize_t n = -1;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size < (off_t)sizeof buffer) {
        n = read(fd, buffer, sizeof buffer - 1);
    }
    close(fd);
    if (n <= 0) return config;
    NSString *text = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)n encoding:NSUTF8StringEncoding];
    NSMutableArray<NSString *> *routes = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [line rangeOfString:@"="];
        if (line.length == 0 || [line hasPrefix:@"#"] || eq.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:eq.location];
        NSString *value = [line substringFromIndex:eq.location + 1];
        if ([key isEqualToString:@"owner"]) {
            long v = value.integerValue;
            if (v > 1 && v < INT_MAX) config.owner = (pid_t)v;
        } else if ([key isEqualToString:@"usb"]) {
            unsigned vid = 0, pid = 0;
            char extra;
            if (sscanf(value.UTF8String, "%4x:%4x%c", &vid, &pid, &extra) == 2 && vid && pid) {
                config.vid = (uint16_t)vid;
                config.pid = (uint16_t)pid;
            }
        } else if ([key isEqualToString:@"guest"]) {
            uint32_t ip;
            if (parseIPv4(value, &ip)) config.guest = ip;
        } else if ([key isEqualToString:@"route"]) {
            NSString *cidr = canonicalCIDR(value, NULL, NULL);
            if (cidr && routes.count < 32 && ![routes containsObject:cidr]) [routes addObject:cidr];
        } else if ([key isEqualToString:@"rx_filter"]) {
            config.rxFilter = [value isEqualToString:@"rtw88"];
        }
    }
    config.routes = routes;
    return config;
}

/// The owner counts only while that pid runs the GodseonDongle app, so a recycled pid holds nothing.
static BOOL ownerAlive(pid_t pid) {
    if (pid <= 1) return NO;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) <= 0) return NO;
    static const char suffix[] = "/Contents/MacOS/GodseonDongle";
    size_t length = strlen(path), suffixLength = sizeof suffix - 1;
    return length >= suffixLength && strcmp(path + length - suffixLength, suffix) == 0;
}

/// The vmnet bridge whose subnet holds the guest (the VM's NAT link), or nil.
static NSString *bridgeForGuest(uint32_t guest) {
    if (!guest) return nil;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *found = nil;
    for (struct ifaddrs *ifa = list; ifa && !found; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET || !ifa->ifa_netmask) continue;
        if (strncmp(ifa->ifa_name, "bridge", 6) != 0) continue;
        uint32_t address = ntohl(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr);
        uint32_t mask = ntohl(((struct sockaddr_in *)ifa->ifa_netmask)->sin_addr.s_addr);
        if (mask && address != guest && (address & mask) == (guest & mask)) found = @(ifa->ifa_name);
    }
    freeifaddrs(list);
    return found;
}

// ------------------------------------------------------------------ state
/// One URB the guest submitted and has not been answered yet.
@interface PendingURB : NSObject
@property (nonatomic) uint32_t conn;
@property (nonatomic) uint8_t address;            // endpoint address; 0 for control
@property (nonatomic) BOOL unlinked;
@property (nonatomic) uint64_t started;
@end
@implementation PendingURB
@end

// Everything below is touched only on gStateQueue. IOUSBHost delivers completions on
// gIOQueue, so synchronous IOUSBHost calls made on gStateQueue never wait on themselves.
static dispatch_queue_t gStateQueue, gIOQueue, gSendQueue, gRouteQueue;
static Config *gConfig;
static BOOL gActive;
static unsigned long gTick;

static io_service_t gService;
static IOUSBHostDevice *gDevice;
static uint16_t gOpenVid, gOpenPid;
static uint32_t gSpeed = 3;
static NSString *gDeviceState = @"idle";         // idle, absent, captured, error
static NSString *gDeviceError = @"";
static uint64_t gLastOpenAttempt;
static NSMutableDictionary<NSNumber *, IOUSBHostInterface *> *gInterfaces;
static NSMutableDictionary<NSNumber *, IOUSBHostPipe *> *gPipes;
static NSMutableDictionary<NSNumber *, NSNumber *> *gMaxPacket;

static int gClientFd = -1;
static uint32_t gClientPeer;
static uint32_t gConn;
static uint64_t gClientSince;
static unsigned long gImports;
static NSMutableDictionary<NSNumber *, PendingURB *> *gURBs;

static struct Stats {
    unsigned long submitted, completed, control, bulkIn, bulkOut, unlinks, aborts, errors, filtered;
    unsigned long long bytesIn, bytesOut;
    double maxOutMs;
} gWindow, gSummary;
static uint64_t gWindowStart, gSummaryStart;
static double gOldestOutSeconds;
static unsigned long gStalls, gResets, gTotalErrors;
static int gStallStage;
static uint64_t gStallAt, gLastReset;

static NSArray<NSDictionary *> *gRouteResult = @[];
static NSString *gGuestInterface;
static BOOL gRoutesBusy;
static NSData *gLastStatus;
static NSDictionary *gLastRates;

// ------------------------------------------------------------------ USB/IP replies
// Replies that complete together go out in one write: one TCP segment instead of one per
// URB, so the guest takes fewer interrupts. The flush block queues behind the appends.
static NSMutableData *gPending;          // gSendQueue only
static int gPendingFd = -1;
static BOOL gFlushQueued;

static void flushPending(void) {
    if (gPending.length && gPendingFd >= 0) writeFull(gPendingFd, gPending.bytes, gPending.length);
    gPending.length = 0;
}

static void sendToClient(uint32_t conn, NSData *data) {
    if (conn != gConn || gClientFd < 0) return;
    int fd = gClientFd;
    dispatch_async(gSendQueue, ^{
        if (fd != gPendingFd) { flushPending(); gPendingFd = fd; }
        [gPending appendData:data];
        if (gFlushQueued) return;
        gFlushQueued = YES;
        dispatch_async(gSendQueue, ^{ gFlushQueued = NO; flushPending(); });
    });
}

static int32_t mapStatus(IOReturn r) {
    switch (r) {
        case kIOReturnSuccess: case kIOReturnUnderrun: return 0;
        case kIOReturnAborted: return -ECONNRESET;
        case kIOReturnTimeout: return -ETIMEDOUT;
        case kIOReturnNoDevice: case kIOReturnNotResponding: case kIOReturnOffline: return -ESHUTDOWN;
        case kIOReturnOverrun: return -EOVERFLOW;
#ifdef kUSBHostReturnPipeStalled
        case kUSBHostReturnPipeStalled: return -EPIPE;
#endif
        default: return -EPROTO;
    }
}

static void sendRetSubmit(uint32_t conn, uint32_t seq, int32_t status, uint32_t actual,
                          uint32_t packets, NSData *inData) {
    NSMutableData *d = [NSMutableData dataWithCapacity:48 + inData.length];
    put32(d, RET_SUBMIT); put32(d, seq); put32(d, 0); put32(d, 0); put32(d, 0);
    put32(d, (uint32_t)status); put32(d, actual); put32(d, 0); put32(d, packets); put32(d, 0);
    uint8_t pad[8] = {0};
    [d appendBytes:pad length:8];
    if (inData.length) [d appendData:inData];
    sendToClient(conn, d);
}

static void sendRetUnlink(uint32_t conn, uint32_t seq, int32_t status) {
    NSMutableData *d = [NSMutableData dataWithCapacity:48];
    put32(d, RET_UNLINK); put32(d, seq); put32(d, 0); put32(d, 0); put32(d, 0);
    put32(d, (uint32_t)status);
    uint8_t pad[24] = {0};
    [d appendBytes:pad length:24];
    sendToClient(conn, d);
}

// ------------------------------------------------------------------ device
static void forEachDescriptor(const IOUSBConfigurationDescriptor *cd, void (^body)(const uint8_t *p)) {
    if (!cd) return;
    const uint8_t *p = (const uint8_t *)cd, *end = p + OSSwapLittleToHostInt16(cd->wTotalLength);
    while (p + 2 <= end && p[0] >= 2 && p + p[0] <= end) { body(p); p += p[0]; }
}

static void putDeviceInfo(NSMutableData *d, BOOL withInterfaces) {
    const IOUSBDeviceDescriptor *dd = gDevice.deviceDescriptor;
    const IOUSBConfigurationDescriptor *cd = gDevice.configurationDescriptor;
    char path[256] = {0}, busid[32] = {0};
    snprintf(path, sizeof path, "/sys/devices/platform/godseon-usbip/usb1/%s", kBusid);
    snprintf(busid, sizeof busid, "%s", kBusid);
    [d appendBytes:path length:sizeof path];
    [d appendBytes:busid length:sizeof busid];
    put32(d, 1);
    put32(d, (uint32_t)MAX(gDevice.deviceAddress, (NSUInteger)1));
    put32(d, gSpeed);
    put16(d, OSSwapLittleToHostInt16(dd->idVendor));
    put16(d, OSSwapLittleToHostInt16(dd->idProduct));
    put16(d, OSSwapLittleToHostInt16(dd->bcdDevice));
    put8(d, dd->bDeviceClass); put8(d, dd->bDeviceSubClass); put8(d, dd->bDeviceProtocol);
    put8(d, cd ? cd->bConfigurationValue : 0);
    put8(d, dd->bNumConfigurations);
    put8(d, cd ? cd->bNumInterfaces : 0);
    if (withInterfaces) {
        forEachDescriptor(cd, ^(const uint8_t *p) {
            if (p[1] == kIOUSBDescriptorTypeInterface && p[3] == 0) {
                put8(d, p[5]); put8(d, p[6]); put8(d, p[7]); put8(d, 0);
            }
        });
    }
}

static void closeInterfaces(void) {
    for (IOUSBHostPipe *pipe in gPipes.allValues) [pipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [gPipes removeAllObjects];
    [gMaxPacket removeAllObjects];
    for (IOUSBHostInterface *intf in gInterfaces.allValues) [intf destroy];
    [gInterfaces removeAllObjects];
}

static void openPipes(IOUSBHostInterface *intf) {
    uint8_t number = intf.interfaceDescriptor->bInterfaceNumber;
    uint8_t alternate = intf.interfaceDescriptor->bAlternateSetting;
    __block BOOL inside = NO;
    forEachDescriptor(intf.configurationDescriptor, ^(const uint8_t *p) {
        if (p[1] == kIOUSBDescriptorTypeInterface) {
            inside = (p[2] == number && p[3] == alternate);
        } else if (inside && p[1] == kIOUSBDescriptorTypeEndpoint) {
            uint8_t address = p[2];
            NSError *error = nil;
            IOUSBHostPipe *pipe = [intf copyPipeWithAddress:address error:&error];
            if (pipe) {
                gPipes[@(address)] = pipe;
                gMaxPacket[@(address)] = @((uint16_t)(p[4] | (p[5] << 8)) & 0x7ff);
            } else {
                logmsg(@"pipe 0x%02x: %@", address, error.localizedDescription);
            }
        }
    });
}

static BOOL openInterfaces(void) {
    const IOUSBConfigurationDescriptor *cd = gDevice.configurationDescriptor;
    NSUInteger wanted = cd ? cd->bNumInterfaces : 0;
    for (int attempt = 0; attempt < 60 && gInterfaces.count < wanted; attempt++) {
        io_iterator_t it = 0;
        if (IORegistryEntryGetChildIterator(gService, kIOServicePlane, &it) == KERN_SUCCESS) {
            io_service_t child;
            while ((child = IOIteratorNext(it))) {
                if (IOObjectConformsTo(child, "IOUSBHostInterface")) {
                    NSError *error = nil;
                    IOUSBHostInterface *intf = [[IOUSBHostInterface alloc] initWithIOService:child
                        options:IOUSBHostObjectInitOptionsNone queue:gIOQueue error:&error interestHandler:nil];
                    if (!intf) {
                        if (attempt == 59) logmsg(@"interface open failed: %@", error.localizedDescription);
                    } else if (gInterfaces[@(intf.interfaceDescriptor->bInterfaceNumber)]) {
                        [intf destroy];
                    } else {
                        gInterfaces[@(intf.interfaceDescriptor->bInterfaceNumber)] = intf;
                        openPipes(intf);
                    }
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(it);
        }
        if (gInterfaces.count < wanted) usleep(50 * 1000);
    }
    return gInterfaces.count == wanted;
}

static BOOL configure(NSUInteger value) {
    closeInterfaces();
    NSError *error = nil;
    if (![gDevice configureWithValue:value matchInterfaces:NO error:&error]) {
        logmsg(@"SET_CONFIGURATION %lu failed: %@", (unsigned long)value, error.localizedDescription);
        return NO;
    }
    return value == 0 || openInterfaces();
}

static void addStats(struct Stats *into, const struct Stats *from) {
    into->submitted += from->submitted; into->completed += from->completed; into->control += from->control;
    into->bulkIn += from->bulkIn; into->bulkOut += from->bulkOut; into->unlinks += from->unlinks;
    into->aborts += from->aborts; into->errors += from->errors; into->filtered += from->filtered;
    into->bytesIn += from->bytesIn; into->bytesOut += from->bytesOut;
    into->maxOutMs = MAX(into->maxOutMs, from->maxOutMs);
}

static void logSummary(NSString *what) {
    double seconds = MAX(secondsSince(gSummaryStart), 1);
    logmsg(@"%@: %.0f s, %lu urbs (%.0f/s: control %.0f, bulk in %.0f, bulk out %.0f), %.1f MB in, %.1f MB out "
           "(%.2f / %.2f Mbit/s), max out %.0f ms, errors %lu, unlinks %lu, aborts %lu, filtered %lu", what, seconds,
           gSummary.submitted, gSummary.submitted / seconds, gSummary.control / seconds, gSummary.bulkIn / seconds,
           gSummary.bulkOut / seconds,
           gSummary.bytesIn / 1e6, gSummary.bytesOut / 1e6, gSummary.bytesIn * 8 / seconds / 1e6,
           gSummary.bytesOut * 8 / seconds / 1e6, gSummary.maxOutMs, gSummary.errors, gSummary.unlinks,
           gSummary.aborts, gSummary.filtered);
    memset(&gSummary, 0, sizeof gSummary);
    gSummaryStart = nowNs();
}

/// Ends the VM's connection (the reader thread then sees EOF) and forgets its requests.
static void endClient(uint32_t conn, NSString *why) {
    if (conn != gConn || gClientFd < 0) return;
    addStats(&gSummary, &gWindow);
    memset(&gWindow, 0, sizeof gWindow);
    gWindowStart = nowNs();
    logSummary([NSString stringWithFormat:@"VM connection closed (%@)", why]);
    shutdown(gClientFd, SHUT_RDWR);
    gConn++;
    gClientFd = -1;
    gClientPeer = 0;
    gStallStage = 0;
    for (IOUSBHostPipe *pipe in gPipes.allValues) [pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
    [gDevice abortDeviceRequestsWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
    [gURBs removeAllObjects];
}

static void closeDevice(NSString *state) {
    endClient(gConn, @"dongle released");
    closeInterfaces();
    if (gDevice) {
        [gDevice destroy];                // gives the dongle back to macOS
        gDevice = nil;
        logmsg(@"released %04x:%04x", gOpenVid, gOpenPid);
    }
    if (gService) { IOObjectRelease(gService); gService = 0; }
    gDeviceState = state;
}

static void ensureDevice(void) {
    if (!gActive) {
        if (gDevice) closeDevice(@"idle");
        gDeviceState = @"idle";
        gDeviceError = @"";
        return;
    }
    if (gDevice && (gOpenVid != gConfig.vid || gOpenPid != gConfig.pid)) closeDevice(@"idle");
    if (gDevice) return;
    if (gLastOpenAttempt && secondsSince(gLastOpenAttempt) < 2) return;
    gLastOpenAttempt = nowNs();
    uint16_t vid = gConfig.vid, pid = gConfig.pid;
    CFMutableDictionaryRef match = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(vid) productID:@(pid)
        bcdDevice:nil deviceClass:nil deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:nil];
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) {
        if (![gDeviceState isEqualToString:@"absent"]) logmsg(@"dongle %04x:%04x is not plugged in", vid, pid);
        gDeviceState = @"absent";
        gDeviceError = @"";
        return;
    }
    NSError *error = nil;
    __block IOUSBHostDevice *opened = nil;
    opened = [[IOUSBHostDevice alloc] initWithIOService:service options:IOUSBHostObjectInitOptionsDeviceCapture
        queue:gIOQueue error:&error interestHandler:^(IOUSBHostObject *object, uint32_t type, void *argument) {
            if (type != kIOMessageServiceIsTerminated) return;
            dispatch_async(gStateQueue, ^{
                if (gDevice && gDevice == (IOUSBHostDevice *)object) {
                    logmsg(@"dongle unplugged");
                    closeDevice(@"absent");
                }
            });
        }];
    if (!opened) {
        IOObjectRelease(service);
        NSString *message = error.localizedDescription ?: @"unknown error";
        if (![gDeviceError isEqualToString:message]) logmsg(@"cannot capture %04x:%04x: %@", vid, pid, message);
        gDeviceState = @"error";
        gDeviceError = message;
        return;
    }
    gDevice = opened;
    gService = service;
    gOpenVid = vid;
    gOpenPid = pid;
    gDeviceError = @"";
    CFTypeRef speed = IORegistryEntryCreateCFProperty(service, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
    if (speed) {
        int legacy = [(__bridge NSNumber *)speed intValue];      // 0 low, 1 full, 2 high, 3 super, 4 super+
        const uint32_t map[] = {1, 2, 3, 5, 6};
        if (legacy >= 0 && legacy <= 4) gSpeed = map[legacy];
        CFRelease(speed);
    }
    if (gDevice.configurationDescriptor) openInterfaces();
    gDeviceState = @"captured";
    logmsg(@"captured %04x:%04x (speed %u, %lu interface(s), %lu pipe(s))", vid, pid, gSpeed,
           (unsigned long)gInterfaces.count, (unsigned long)gPipes.count);
}

// ------------------------------------------------------------------ URBs
static void track(uint32_t conn, uint32_t seq, uint8_t address) {
    PendingURB *urb = [PendingURB new];
    urb.conn = conn;
    urb.address = address;
    urb.started = nowNs();
    gURBs[@(seq)] = urb;
}

// rtw88 receive filter. RTL8822B/8821C/8822C dongles hand up every broadcast 802.11ax Trigger
// frame they hear (control subtype 2; Wi-Fi 6 access points send hundreds a second), whatever
// their receive filter registers say, although these 802.11ac chips have no use for them and
// mac80211 drops them. Measured at idle on a shared 5 GHz channel, ~90% of the dongle's bulk IN
// transfers were nothing else, and each one costs a round trip to the VM. With rx_filter=rtw88
// a completion whose packets are all Trigger frames is not answered: the same request goes back
// to the device, so the guest's URB simply waits for a useful frame. Anything that does not
// parse cleanly as rtw88 receive descriptors is passed on untouched.
//   descriptor (24 bytes, little endian): w0 [13:0] packet length, [19:16] driver info size in
//   8-byte units, [25:24] shift; w2 [28] firmware report (C2H); packets start 8-byte aligned.
static BOOL rtw88OnlyTriggerFrames(const uint8_t *p, size_t n) {
    size_t offset = 0, frames = 0;
    while (offset + 24 <= n) {
        const uint8_t *d = p + offset;
        uint32_t w0 = d[0] | d[1] << 8 | d[2] << 16 | (uint32_t)d[3] << 24;
        uint32_t w2 = d[8] | d[9] << 8 | d[10] << 16 | (uint32_t)d[11] << 24;
        size_t length = w0 & 0x3fff, start = 24 + ((w0 >> 16) & 0xf) * 8 + ((w0 >> 24) & 3);
        if (length < 10 || offset + start + length > n || (w2 & (1u << 28))) return NO;
        uint16_t fc = p[offset + start] | p[offset + start + 1] << 8;
        if (((fc >> 2) & 3) != 1 || ((fc >> 4) & 0xf) != 2) return NO;    // control, subtype Trigger
        frames++;
        offset += (start + length + 7) & ~(size_t)7;
    }
    return frames > 0 && offset >= n;
}

static BOOL enqueueBulk(uint32_t conn, uint32_t seq, IOUSBHostPipe *pipe, NSMutableData *buffer,
                        uint32_t packets, BOOL in, BOOL zeroPacket, NSError **error);

static void finish(uint32_t conn, uint32_t seq, IOReturn status, NSUInteger bytes, uint32_t packets,
                   NSMutableData *inData, BOOL in) {
    PendingURB *urb = gURBs[@(seq)];
    if (!urb || urb.conn != conn) return;           // from an earlier connection
    if (in && conn == gConn && urb.address != 0 && !urb.unlinked && status == kIOReturnSuccess && gConfig.rxFilter &&
        rtw88OnlyTriggerFrames(inData.bytes, MIN(bytes, inData.length))) {
        IOUSBHostPipe *pipe = gPipes[@(urb.address)];
        if (pipe && enqueueBulk(conn, seq, pipe, inData, packets, YES, NO, NULL)) {
            gWindow.filtered++;
            return;                                  // still pending for the guest
        }
    }
    [gURBs removeObjectForKey:@(seq)];
    gWindow.completed++;
    if (urb.address != 0 && !in) gWindow.maxOutMs = MAX(gWindow.maxOutMs, (double)(nowNs() - urb.started) / 1e6);
    if (urb.unlinked) return;                       // the guest already got RET_UNLINK
    int32_t st = mapStatus(status);
    if (st != 0) { gWindow.errors++; gTotalErrors++; }
    if (in) gWindow.bytesIn += bytes; else gWindow.bytesOut += bytes;
    NSData *payload = (in && bytes > 0) ? [inData subdataWithRange:NSMakeRange(0, MIN(bytes, inData.length))] : nil;
    sendRetSubmit(conn, seq, st, (uint32_t)bytes, packets, payload);
}

static void control(uint32_t conn, uint32_t seq, BOOL in, uint64_t setupBits, NSMutableData *outData, uint32_t packets) {
    const uint8_t *s = (const uint8_t *)&setupBits;
    IOUSBDeviceRequest request = {
        .bmRequestType = s[0], .bRequest = s[1],
        .wValue = (uint16_t)(s[2] | (s[3] << 8)), .wIndex = (uint16_t)(s[4] | (s[5] << 8)),
        .wLength = (uint16_t)(s[6] | (s[7] << 8)),
    };
    gWindow.control++;
    // Requests that change state on the macOS side go through IOUSBHost's own calls,
    // the same set the Linux usbip host driver intercepts.
    if (request.bmRequestType == 0x00 && request.bRequest == 9) {               // SET_CONFIGURATION
        sendRetSubmit(conn, seq, configure(request.wValue) ? 0 : -EPIPE, 0, packets, nil);
        return;
    }
    if (request.bmRequestType == 0x01 && request.bRequest == 11) {              // SET_INTERFACE
        IOUSBHostInterface *intf = gInterfaces[@(request.wIndex & 0xff)];
        NSError *error = nil;
        BOOL ok = intf && [intf selectAlternateSetting:request.wValue error:&error];
        if (ok) openPipes(intf); else logmsg(@"SET_INTERFACE failed: %@", error.localizedDescription);
        sendRetSubmit(conn, seq, ok ? 0 : -EPIPE, 0, packets, nil);
        return;
    }
    if (request.bmRequestType == 0x02 && request.bRequest == 1 && request.wValue == 0) {   // CLEAR_FEATURE(HALT)
        [gPipes[@(request.wIndex & 0xff)] clearStallWithError:nil];
        sendRetSubmit(conn, seq, 0, 0, packets, nil);
        return;
    }
    if (request.bmRequestType == 0x23 && request.bRequest == 3 && request.wValue == 4) {   // SET_FEATURE(PORT_RESET)
        NSUInteger value = gDevice.configurationDescriptor ? gDevice.configurationDescriptor->bConfigurationValue : 0;
        closeInterfaces();
        NSError *error = nil;
        if (![gDevice resetWithError:&error]) logmsg(@"device reset failed: %@", error.localizedDescription);
        if (value) configure(value);
        sendRetSubmit(conn, seq, 0, 0, packets, nil);
        return;
    }
    NSMutableData *buffer = in ? [[NSMutableData alloc] initWithLength:request.wLength]
                               : (outData.length ? outData : nil);
    track(conn, seq, 0);
    NSError *error = nil;
    BOOL queued = [gDevice enqueueDeviceRequest:request data:buffer completionTimeout:5.0 error:&error
        completionHandler:^(IOReturn status, NSUInteger bytes) {
            dispatch_async(gStateQueue, ^{ finish(conn, seq, status, bytes, packets, buffer, in); });
        }];
    if (!queued) {
        [gURBs removeObjectForKey:@(seq)];
        sendRetSubmit(conn, seq, gDevice ? -EPIPE : -ESHUTDOWN, 0, packets, nil);
    }
}

static BOOL enqueueBulk(uint32_t conn, uint32_t seq, IOUSBHostPipe *pipe, NSMutableData *buffer,
                        uint32_t packets, BOOL in, BOOL zeroPacket, NSError **error) {
    return [pipe enqueueIORequestWithData:buffer completionTimeout:0 error:error
        completionHandler:^(IOReturn status, NSUInteger bytes) {
            if (zeroPacket && status == kIOReturnSuccess) {
                [pipe enqueueIORequestWithData:[[NSMutableData alloc] init] completionTimeout:0 error:nil
                    completionHandler:^(IOReturn zlpStatus, NSUInteger zlpBytes) {
                        dispatch_async(gStateQueue, ^{ finish(conn, seq, status, bytes, packets, buffer, in); });
                    }];
                return;
            }
            dispatch_async(gStateQueue, ^{ finish(conn, seq, status, bytes, packets, buffer, in); });
        }];
}

static void submit(uint32_t conn, uint32_t seq, uint32_t direction, uint32_t ep, uint32_t flags,
                   int32_t length, uint32_t packets, uint64_t setupBits, NSMutableData *outData) {
    if (conn != gConn) return;
    gWindow.submitted++;
    BOOL in = direction == 1;
    if (ep == 0) { control(conn, seq, in, setupBits, outData, packets); return; }
    if (packets != 0 && packets != 0xffffffff) { sendRetSubmit(conn, seq, -EPROTO, 0, packets, nil); return; }  // no isochronous
    uint8_t address = (uint8_t)(ep | (in ? 0x80 : 0));
    IOUSBHostPipe *pipe = gPipes[@(address)];
    if (!pipe) { sendRetSubmit(conn, seq, gDevice ? -EPIPE : -ESHUTDOWN, 0, packets, nil); return; }
    if (in) gWindow.bulkIn++; else gWindow.bulkOut++;
    // a plain buffer: IOUSBHost's ioDataWithCapacity: buffers refuse length changes
    NSMutableData *buffer = in ? [[NSMutableData alloc] initWithLength:(NSUInteger)MAX(length, 0)]
                               : (outData ?: [[NSMutableData alloc] init]);
    NSUInteger maxPacket = gMaxPacket[@(address)].unsignedIntegerValue;
    BOOL zeroPacket = !in && (flags & URB_ZERO_PACKET) && length > 0 && maxPacket && (length % maxPacket) == 0;
    track(conn, seq, address);
    NSError *error = nil;
    BOOL queued = enqueueBulk(conn, seq, pipe, buffer, packets, in, zeroPacket, &error);
    if (!queued) {
        [gURBs removeObjectForKey:@(seq)];
        logmsg(@"ep 0x%02x: failed to queue %d bytes: %@", address, length, error.localizedDescription);
        sendRetSubmit(conn, seq, -EPIPE, 0, packets, nil);
    }
}

// IOUSBHost can only cancel every request on an endpoint at once, so an endpoint is aborted
// when the last request still queued on it gets unlinked (what a driver does when it stops:
// it kills all its URBs). Unlinked requests are never answered again.
static void unlinkURB(uint32_t conn, uint32_t seq, uint32_t target) {
    if (conn != gConn) return;
    PendingURB *urb = gURBs[@(target)];
    BOOL pending = urb && urb.conn == conn && !urb.unlinked;
    if (pending) {
        urb.unlinked = YES;
        gWindow.unlinks++;
        BOOL othersLive = NO;
        for (PendingURB *other in gURBs.allValues) {
            if (other != urb && other.conn == conn && other.address == urb.address && !other.unlinked) { othersLive = YES; break; }
        }
        if (!othersLive) {
            gWindow.aborts++;
            if (urb.address == 0) [gDevice abortDeviceRequestsWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
            else [gPipes[@(urb.address)] abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        }
    }
    sendRetUnlink(conn, seq, pending ? -ECONNRESET : 0);
}

// A bulk OUT request that waits kStallSeconds means the dongle stopped taking data. First
// abort that endpoint (the driver sees failed transfers and carries on); if it stalls again
// right after, reset the dongle and drop the VM's connection: the guest re-attaches by itself
// (about 15 s offline). Resets are spaced kResetSpacingSeconds apart.
static void watchdog(void) {
    gOldestOutSeconds = 0;
    if (gClientFd < 0) { gStallStage = 0; return; }
    uint8_t address = 0;
    uint64_t now = nowNs();
    for (PendingURB *urb in gURBs.allValues) {
        if (urb.unlinked || urb.address == 0 || (urb.address & 0x80)) continue;
        double age = (double)(now - urb.started) / 1e9;
        if (age > gOldestOutSeconds) { gOldestOutSeconds = age; address = urb.address; }
    }
    if (gOldestOutSeconds < kStallSeconds) {
        if (gStallStage && secondsSince(gStallAt) > 60) gStallStage = 0;
        return;
    }
    if (gStallStage == 0) {
        gStalls++;
        gStallStage = 1;
        gStallAt = now;
        logmsg(@"TX stall: a bulk OUT request on 0x%02x has waited %.0f s; aborting the endpoint", address, gOldestOutSeconds);
        [gPipes[@(address)] abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        return;
    }
    if (secondsSince(gStallAt) < kStallSeconds) return;
    if (gLastReset && secondsSince(gLastReset) < kResetSpacingSeconds) {
        logmsg(@"TX stalled again on 0x%02x; aborting the endpoint (next reset allowed in %.0f s)", address,
               kResetSpacingSeconds - secondsSince(gLastReset));
        [gPipes[@(address)] abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        gStallAt = now;
        return;
    }
    gResets++;
    gLastReset = now;
    gStallStage = 0;
    logmsg(@"TX still stalled after the abort; resetting the dongle and reconnecting the VM");
    endClient(gConn, @"TX stall");
    NSError *error = nil;
    if (gDevice && ![gDevice resetWithError:&error]) logmsg(@"dongle reset failed: %@", error.localizedDescription);
    closeDevice(@"idle");            // captured again on the next tick
    gLastOpenAttempt = 0;
}

// ------------------------------------------------------------------ routes (gRouteQueue)
static NSMutableDictionary<NSString *, NSString *> *gOwned;     // cidr -> guest it points at

static int runRoute(NSArray<NSString *> *args, NSString **output) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);   // sockets stay with us
    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObjects:@"/sbin/route", @"-n", nil];
    [all addObjectsFromArray:args];
    char *argv[16];
    NSUInteger count = MIN(all.count, (NSUInteger)15);
    for (NSUInteger i = 0; i < count; i++) argv[i] = (char *)all[i].UTF8String;
    argv[count] = NULL;
    pid_t child = 0;
    int rc = posix_spawn(&child, "/sbin/route", &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(fds[1]);
    NSMutableData *data = [NSMutableData data];
    char buffer[2048];
    ssize_t n;
    while ((n = read(fds[0], buffer, sizeof buffer)) > 0) [data appendBytes:buffer length:(NSUInteger)n];
    close(fds[0]);
    if (rc != 0) return -1;
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// RTM_GET with a netmask is an exact-match lookup on macOS: no route for this very prefix
// gives no gateway, even when a wider route (the default) would carry the traffic.
static void routeInfo(NSString *cidr, NSString **gateway, NSString **interface) {
    NSString *out = nil;
    *gateway = nil;
    *interface = nil;
    if (runRoute(@[@"get", @"-net", cidr], &out) != 0) return;
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([t hasPrefix:@"gateway: "]) *gateway = [t substringFromIndex:9];
        else if ([t hasPrefix:@"interface: "]) *interface = [t substringFromIndex:11];
    }
}

static void saveOwned(void) {
    NSMutableString *text = [NSMutableString string];
    for (NSString *cidr in gOwned) [text appendFormat:@"%@ %@\n", cidr, gOwned[cidr]];
    [text writeToFile:kOwnedRoutesPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void loadOwned(void) {
    gOwned = [NSMutableDictionary dictionary];
    NSString *text = [NSString stringWithContentsOfFile:kOwnedRoutesPath encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
        uint32_t ip;
        if (parts.count == 2 && canonicalCIDR(parts[0], NULL, NULL) && parseIPv4(parts[1], &ip)) gOwned[parts[0]] = parts[1];
    }
}

/// Makes the table hold exactly the desired routes through the guest. Only routes that still
/// point at the guest are deleted: macOS deletes by destination, so a same-prefix route of the
/// user's would otherwise go too. A route for the same prefix through anything else is a
/// conflict, reported and left alone.
static NSArray<NSDictionary *> *applyRoutes(NSArray<NSString *> *desired, NSString *guest, NSString *interface) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *owned = [NSMutableDictionary dictionary];
    for (NSString *cidr in desired) {
        NSString *gateway, *via;
        routeInfo(cidr, &gateway, &via);
        if (!([gateway isEqualToString:guest] && [via isEqualToString:interface])) {
            if (gateway && ([gateway isEqualToString:guest] || [gOwned[cidr] isEqualToString:gateway])) {
                runRoute(@[@"delete", @"-net", cidr, gateway], nil);       // ours, but stale
            }
            runRoute(@[@"add", @"-net", cidr, guest, @"-ifp", interface], nil);
            routeInfo(cidr, &gateway, &via);
            if (!([gateway isEqualToString:guest] && [via isEqualToString:interface])) {
                [result addObject:@{@"cidr": cidr, @"state": @"conflict", @"gateway": gateway ?: @"", @"interface": via ?: @""}];
                if (![gOwned[cidr] isEqualToString:@"conflict"]) logmsg(@"%@ already goes through %@ %@; not replacing it", cidr, gateway ?: @"?", via ?: @"?");
                continue;
            }
            logmsg(@"added %@ via %@ on %@", cidr, guest, interface);
        }
        owned[cidr] = guest;
        [result addObject:@{@"cidr": cidr, @"state": @"ok", @"gateway": guest, @"interface": interface}];
    }
    for (NSString *cidr in gOwned) {
        if (owned[cidr]) continue;
        NSString *old = gOwned[cidr], *gateway, *via;
        routeInfo(cidr, &gateway, &via);
        if ([gateway isEqualToString:old] && runRoute(@[@"delete", @"-net", cidr, old], nil) == 0) logmsg(@"removed %@", cidr);
    }
    if (![gOwned isEqualToDictionary:owned]) {
        gOwned = owned;
        saveOwned();
    }
    return result;
}

// ------------------------------------------------------------------ status
static void writeStatus(void) {
    double seconds = MAX(secondsSince(gWindowStart), 0.5);
    NSDictionary *rates = @{
        @"in_mbps": @(round(gWindow.bytesIn * 8 / seconds / 1e4) / 100),
        @"out_mbps": @(round(gWindow.bytesOut * 8 / seconds / 1e4) / 100),
        @"max_out_ms": @(round(gWindow.maxOutMs)),
        @"urbs_per_s": @(round(gWindow.submitted / seconds)),
        @"control_per_s": @(round(gWindow.control / seconds)),
        @"in_per_s": @(round(gWindow.bulkIn / seconds)),
        @"out_per_s": @(round(gWindow.bulkOut / seconds)),
        @"filtered_per_s": @(round(gWindow.filtered / seconds)),
    };
    addStats(&gSummary, &gWindow);
    memset(&gWindow, 0, sizeof gWindow);
    gWindowStart = nowNs();
    if (gClientFd >= 0 && secondsSince(gSummaryStart) >= kSummarySeconds) logSummary(@"traffic");
    NSMutableDictionary *status = [@{
        @"version": @1,
        @"pid": @(getpid()),
        @"active": @(gActive),
        @"owner": @(gConfig.owner),
        @"usb": [NSString stringWithFormat:@"%04x:%04x", gConfig.vid, gConfig.pid],
        @"device": gDeviceState,
        @"device_error": gDeviceError ?: @"",
        @"guest": gConfig.guest ? formatIPv4(gConfig.guest) : @"",
        @"guest_interface": gGuestInterface ?: @"",
        @"client": @((BOOL)(gClientFd >= 0)),       // a BOOL, so JSON gets true/false, not 1/0
        @"client_seconds": @(gClientFd >= 0 ? (long)secondsSince(gClientSince) : 0),
        @"imports": @(gImports),
        @"oldest_out_ms": @(round(gOldestOutSeconds * 1000)),
        @"errors": @(gTotalErrors),
        @"stalls": @(gStalls),
        @"resets": @(gResets),
        @"routes": gRouteResult ?: @[],
    } mutableCopy];
    [status addEntriesFromDictionary:rates];
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingSortedKeys error:nil];
    if (!data || [data isEqualToData:gLastStatus]) return;
    gLastStatus = data;
    gLastRates = rates;
    [data writeToFile:kStatusPath atomically:YES];
    chmod(kStatusPath.fileSystemRepresentation, 0644);
}

// ------------------------------------------------------------------ main loop (gStateQueue)
static void tick(void) {
    gTick++;
    if (!gConfig || gTick % 2 == 0) gConfig = readConfig();
    gActive = gConfig.vid && gConfig.pid && ownerAlive(gConfig.owner);
    ensureDevice();
    if (gClientFd >= 0 && (!gActive || gClientPeer != gConfig.guest)) endClient(gConn, @"the app no longer asks for it");
    watchdog();
    if (gTick % 2 != 0) return;
    NSString *guest = (gActive && gConfig.guest) ? formatIPv4(gConfig.guest) : nil;
    NSString *interface = guest ? bridgeForGuest(gConfig.guest) : nil;
    gGuestInterface = interface;
    NSMutableArray<NSString *> *desired = [NSMutableArray array];
    if (guest && interface) {
        for (NSString *cidr in gConfig.routes) {
            uint32_t net;
            int prefix;
            canonicalCIDR(cidr, &net, &prefix);
            if ((gConfig.guest & maskOf(prefix)) == net) continue;    // would carry the VM's own link
            [desired addObject:cidr];
        }
    }
    if (!gRoutesBusy) {
        gRoutesBusy = YES;
        dispatch_async(gRouteQueue, ^{
            NSArray<NSDictionary *> *result = applyRoutes(desired, guest, interface);
            dispatch_async(gStateQueue, ^{ gRouteResult = result; gRoutesBusy = NO; });
        });
    }
    writeStatus();
}

// ------------------------------------------------------------------ network (one thread per connection)
/// Buffered socket reads: a burst of URBs costs one read() instead of two per URB.
typedef struct {
    int fd;
    size_t start, end;
    uint8_t bytes[64 * 1024];
} Reader;

static BOOL readerRead(Reader *r, void *out, size_t length) {
    uint8_t *p = out;
    while (length > 0) {
        if (r->start == r->end) {
            r->start = r->end = 0;
            ssize_t n;
            do { n = read(r->fd, r->bytes, sizeof r->bytes); } while (n < 0 && errno == EINTR);
            if (n <= 0) return NO;
            r->end = (size_t)n;
        }
        size_t take = MIN(length, r->end - r->start);
        memcpy(p, r->bytes + r->start, take);
        r->start += take;
        p += take;
        length -= take;
    }
    return YES;
}

static void serveURBs(int fd, uint32_t conn) {
    Reader *reader = calloc(1, sizeof(Reader));
    if (!reader) return;
    reader->fd = fd;
    uint8_t h[48];
    BOOL open = YES;
    while (open && readerRead(reader, h, sizeof h)) @autoreleasepool {     // one pool per URB: no build-up
        uint32_t command = get32(h), seq = get32(h + 4), direction = get32(h + 12), ep = get32(h + 16);
        if (command == CMD_SUBMIT) {
            uint32_t flags = get32(h + 20), packets = get32(h + 32);
            int32_t length = (int32_t)get32(h + 24);
            uint64_t setupBits;
            memcpy(&setupBits, h + 40, 8);
            NSMutableData *outData = nil;
            if (direction == 0 && length > 0) {
                if (length > 16 * 1024 * 1024) { open = NO; continue; }
                outData = [[NSMutableData alloc] initWithLength:(NSUInteger)length];
                if (!readerRead(reader, outData.mutableBytes, (size_t)length)) { open = NO; continue; }
            }
            if (packets != 0 && packets != 0xffffffff) {          // skip isochronous descriptors
                if (packets > 1024) { open = NO; continue; }
                NSMutableData *iso = [[NSMutableData alloc] initWithLength:(NSUInteger)packets * 16];
                if (!readerRead(reader, iso.mutableBytes, iso.length)) { open = NO; continue; }
            }
            dispatch_async(gStateQueue, ^{ submit(conn, seq, direction, ep, flags, length, packets, setupBits, outData); });
        } else if (command == CMD_UNLINK) {
            uint32_t target = get32(h + 20);
            dispatch_async(gStateQueue, ^{ unlinkURB(conn, seq, target); });
        } else {
            logmsg(@"unknown USB/IP command %u, closing", command);
            open = NO;
        }
    }
    free(reader);
}

static void serveConnection(int fd, uint32_t peer) {
    uint8_t op[8];
    if (!readFull(fd, op, sizeof op)) return;
    uint16_t code = get16(op + 2);
    if (code == OP_REQ_DEVLIST) {
        __block NSMutableData *reply = [NSMutableData data];
        dispatch_sync(gStateQueue, ^{
            BOOL ready = gDevice != nil;
            put16(reply, USBIP_VERSION); put16(reply, OP_REP_DEVLIST); put32(reply, 0); put32(reply, ready ? 1 : 0);
            if (ready) putDeviceInfo(reply, YES);
        });
        writeFull(fd, reply.bytes, reply.length);
        return;
    }
    if (code != OP_REQ_IMPORT) return;
    char busid[32];
    if (!readFull(fd, busid, sizeof busid)) return;
    __block NSMutableData *reply = [NSMutableData data];
    __block uint32_t conn = 0;
    __block BOOL ready = NO;
    dispatch_sync(gStateQueue, ^{
        ready = gDevice != nil && gActive && peer == gConfig.guest;
        put16(reply, USBIP_VERSION); put16(reply, OP_REP_IMPORT); put32(reply, ready ? 0 : 1);
        if (!ready) return;
        putDeviceInfo(reply, NO);
        if (gClientFd >= 0) endClient(gConn, @"the VM connected again");
        conn = ++gConn;
        gClientFd = fd;
        gClientPeer = peer;
        gClientSince = nowNs();
        gImports++;
        memset(&gWindow, 0, sizeof gWindow);
        memset(&gSummary, 0, sizeof gSummary);
        gWindowStart = gSummaryStart = nowNs();
    });
    if (!writeFull(fd, reply.bytes, reply.length) || !ready) return;
    logmsg(@"VM %@ attached the dongle", formatIPv4(peer));
    serveURBs(fd, conn);
    dispatch_sync(gStateQueue, ^{ endClient(conn, @"the VM went away"); });
    dispatch_sync(gSendQueue, ^{});    // writes queued for this socket go out before it closes
}

static void acceptLoop(int listener) {
    for (;;) {
        struct sockaddr_in peer;
        socklen_t peerLength = sizeof peer;
        int fd = accept(listener, (struct sockaddr *)&peer, &peerLength);
        if (fd < 0) { if (errno != EINTR) usleep(100 * 1000); continue; }
        uint32_t address = ntohl(peer.sin_addr.s_addr);
        __block uint32_t guest = 0;
        dispatch_sync(gStateQueue, ^{ guest = gActive ? gConfig.guest : 0; });
        if (!guest || address != guest) { close(fd); continue; }
        int one = 1, idle = 5, interval = 2, count = 3;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        // A VM that stops dead sends no FIN; keepalives notice it within ~11 s.
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof idle);
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof interval);
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, sizeof count);
        [NSThread detachNewThreadWithBlock:^{
            @autoreleasepool { serveConnection(fd, address); }
            close(fd);
        }];
    }
}

static void shutdownAndExit(void) {
    logmsg(@"stopping");
    closeDevice(@"idle");
    dispatch_sync(gRouteQueue, ^{ applyRoutes(@[], nil, nil); });
    unlink(kStatusPath.fileSystemRepresentation);
    exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <config-file>\n", argv[0]);
            return 2;
        }
        if (geteuid() != 0) {
            fprintf(stderr, "%s must run as root (it is installed as a launchd daemon)\n", argv[0]);
            return 1;
        }
        gConfigPath = @(argv[1]);
        signal(SIGPIPE, SIG_IGN);
        setvbuf(stderr, NULL, _IOLBF, 0);
        // Drain autoreleased objects after every block: millions of URBs pass through these.
        dispatch_queue_attr_t serial = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        gStateQueue = dispatch_queue_create("godseon.state", serial);
        gIOQueue = dispatch_queue_create("godseon.io", serial);
        gSendQueue = dispatch_queue_create("godseon.send", serial);
        gRouteQueue = dispatch_queue_create("godseon.routes", serial);
        gInterfaces = [NSMutableDictionary dictionary];
        gPipes = [NSMutableDictionary dictionary];
        gMaxPacket = [NSMutableDictionary dictionary];
        gURBs = [NSMutableDictionary dictionary];
        gPending = [NSMutableData dataWithCapacity:64 * 1024];
        gWindowStart = gSummaryStart = nowNs();
        loadOwned();

        int listener = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in address = { .sin_len = sizeof address, .sin_family = AF_INET,
                                       .sin_port = htons(kPort), .sin_addr.s_addr = htonl(INADDR_ANY) };
        if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof address) < 0 || listen(listener, 4) < 0) {
            logmsg(@"cannot listen on TCP %u: %s", kPort, strerror(errno));
            sleep(10);                    // launchd restarts us; do not spin
            return 1;
        }
        logmsg(@"started: config %@, USB/IP on TCP %u", gConfigPath, kPort);
        [NSThread detachNewThreadWithBlock:^{ acceptLoop(listener); }];

        static dispatch_source_t timer, term;   // must stay referenced, or ARC frees them
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gStateQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, NSEC_PER_SEC / 20);
        dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { tick(); } });
        dispatch_resume(timer);
        signal(SIGTERM, SIG_IGN);
        term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, gStateQueue);
        dispatch_source_set_event_handler(term, ^{ shutdownAndExit(); });
        dispatch_resume(term);
        dispatch_main();
    }
}
