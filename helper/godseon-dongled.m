// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT
//
// godseon-dongled: GodseonDongle's root helper (launchd daemon, KeepAlive).
//   godseon-dongled <config-file>
//
// While the GodseonDongle app runs and asks for it, the daemon
//  1. hands USB devices to the app's VM over USB/IP (TCP 9408), each under its own bus ID:
//     the USB Wi-Fi dongle and an Android phone in USB tethering mode (RNDIS). As root it
//     captures them through IOUSBHost, so this works even while another app or driver holds
//     them, and no restricted entitlement is needed. Only the VM's address may connect.
//  2. keeps the Mac's IPv4 routes for the networks behind the dongle pointed at the VM.
//  3. with internet=1, makes the phone the Mac's internet: the host link 10.94.8.2/30 goes on
//     the VM's vmnet bridge as an alias (the guest is 10.94.8.1 on its eth0), and a network
//     service in the dynamic store with that address, the guest as its router and DNS server,
//     and OverridePrimary, so macOS puts it first. The guest forwards to the phone. Meanwhile
//     TCP segmentation offload is off Mac-wide (net.inet.tcp.tso=0, see takeTSO), and also
//     while the VM has a dongle whose device= line says tso=off.
// Once the app is gone it releases the devices and removes its routes and the service.
//
// Config, written by the app. The file is user-writable, so every value is validated:
//   owner=<pid>            the app; nothing is held unless this pid runs GodseonDongle
//   device=<busid> <vendor:product> [serial=<s>] [kind=wifi|tether] [rx_filter=rtw88] [tso=off]
//                          repeatable, busid 1-1 to 1-4. serial= takes only the device with that
//                          USB serial number. kind=tether (a phone) is never reset by the stall
//                          watchdog. rx_filter=rtw88: an rtw88 RTL8822B/8821C/8822C (see below).
//                          tso=off: a dongle; TSO off while the VM has it (see takeTSO)
//   usb=0bda:b812          from older apps, when there is no device= line: device 1-1
//   rx_filter=rtw88        from older apps, with usb=
//   guest=192.168.64.5     the VM's address on a vmnet bridge
//   route=192.168.50.0/24  repeatable
//   internet=1             the Mac's internet through the kind=tether device, once the VM has it
// Status for the app: /var/run/godseon-dongled.status (JSON, rewritten when it changes).
// Log: stderr (launchd sends it to /var/log/godseon-dongled.log).
//
// build: clang -fobjc-arc -O2 -Wall godseon-dongled.m -o godseon-dongled -framework Foundation \
//            -framework IOKit -framework IOUSBHost -framework SystemConfiguration

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOUSBHost/IOUSBHost.h>
#import <SystemConfiguration/SystemConfiguration.h>
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
#include <sys/sysctl.h>
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
static const int kSlots = 4;                     // bus IDs 1-1 to 1-4
static NSString *const kStatusPath = @"/var/run/godseon-dongled.status";
static NSString *const kOwnedRoutesPath = @"/var/run/godseon-dongled.routes";
static const double kStallSeconds = 6;           // a bulk OUT request waiting this long: the device stopped sending
static const double kResetSpacingSeconds = 120;  // at most one forced dongle reset per this long
static const double kSummarySeconds = 300;       // traffic summary in the log while the VM is connected
// The phone's internet: the Mac's end of the host link (an alias on the VM's vmnet bridge), the
// guest's end (on its eth0, initramfs/init-network in GodseonDongle-VM) and the network service
// published for it.
static NSString *const kHostLinkMac = @"10.94.8.2";
static NSString *const kHostLinkGuest = @"10.94.8.1";
static NSString *const kHostLinkMask = @"255.255.255.252";
static const uint32_t kHostLinkNet = 0x0a5e0800;            // 10.94.8.0
static const int kHostLinkPrefix = 30;
static NSString *const kTetherService = @"GodseonDongle-Tether";

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

/// Two prefixes share addresses.
static BOOL overlaps(uint32_t a, int aPrefix, uint32_t b, int bPrefix) {
    uint32_t mask = maskOf(MIN(aPrefix, bPrefix));
    return (a & mask) == (b & mask);
}

// ------------------------------------------------------------------ config
/// One device= line.
@interface DeviceConfig : NSObject
@property (nonatomic, copy) NSString *busid;
@property (nonatomic) uint16_t vid, pid;
@property (nonatomic, copy) NSString *serial;            // nil: the first device with this ID
@property (nonatomic) BOOL tether;
@property (nonatomic) BOOL rxFilter;
@property (nonatomic) BOOL noTSO;                        // tso=off
@end
@implementation DeviceConfig
@end

@interface Config : NSObject
@property (nonatomic) pid_t owner;
@property (nonatomic) uint32_t guest;                  // host byte order, 0 = none
@property (nonatomic, copy) NSArray<NSString *> *routes;
@property (nonatomic, copy) NSArray<DeviceConfig *> *devices;
@property (nonatomic) BOOL internet;
@end
@implementation Config
@end

static NSString *gConfigPath;

static BOOL parseUSBID(NSString *value, uint16_t *vid, uint16_t *pid) {
    unsigned v = 0, p = 0;
    char extra;
    if (sscanf(value.UTF8String, "%4x:%4x%c", &v, &p, &extra) != 2 || !v || !p) return NO;
    *vid = (uint16_t)v;
    *pid = (uint16_t)p;
    return YES;
}

/// "1-2 04e8:6863 serial=R5CT10ABCDE kind=tether"; nil when malformed. Unknown options are
/// skipped, so an older helper still takes a newer app's devices.
static DeviceConfig *parseDevice(NSString *value) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in [value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (token.length) [tokens addObject:token];
    }
    if (tokens.count < 2) return nil;
    NSString *busid = tokens[0];
    if (busid.length != 3 || ![busid hasPrefix:@"1-"] || [busid characterAtIndex:2] < '1'
        || [busid characterAtIndex:2] > '0' + kSlots) return nil;
    DeviceConfig *device = [DeviceConfig new];
    device.busid = busid;
    uint16_t vid, pid;
    if (!parseUSBID(tokens[1], &vid, &pid)) return nil;
    device.vid = vid;
    device.pid = pid;
    NSCharacterSet *serialChars = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    for (NSUInteger i = 2; i < tokens.count; i++) {
        NSString *option = tokens[i];
        if ([option hasPrefix:@"serial="]) {
            NSString *serial = [option substringFromIndex:7];
            if (serial.length == 0 || serial.length > 64
                || [serial rangeOfCharacterFromSet:serialChars.invertedSet].location != NSNotFound) return nil;
            device.serial = serial;
        } else if ([option isEqualToString:@"kind=tether"]) {
            device.tether = YES;
        } else if ([option isEqualToString:@"rx_filter=rtw88"]) {
            device.rxFilter = YES;
        } else if ([option isEqualToString:@"tso=off"]) {
            device.noTSO = YES;
        }
    }
    return device;
}

static Config *readConfig(void) {
    Config *config = [Config new];
    config.routes = @[];
    config.devices = @[];
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
    NSMutableArray<DeviceConfig *> *devices = [NSMutableArray array];
    uint16_t legacyVid = 0, legacyPid = 0;
    BOOL legacyFilter = NO;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [line rangeOfString:@"="];
        if (line.length == 0 || [line hasPrefix:@"#"] || eq.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:eq.location];
        NSString *value = [line substringFromIndex:eq.location + 1];
        if ([key isEqualToString:@"owner"]) {
            long v = value.integerValue;
            if (v > 1 && v < INT_MAX) config.owner = (pid_t)v;
        } else if ([key isEqualToString:@"device"]) {
            DeviceConfig *device = parseDevice(value);
            BOOL clash = device == nil;
            for (DeviceConfig *other in devices) {
                // one device per bus ID, and never one device under two bus IDs
                if (device && ([other.busid isEqualToString:device.busid]
                    || (other.vid == device.vid && other.pid == device.pid
                        && (!other.serial || !device.serial || [other.serial isEqualToString:device.serial])))) clash = YES;
            }
            if (!clash) [devices addObject:device];
        } else if ([key isEqualToString:@"usb"]) {
            parseUSBID(value, &legacyVid, &legacyPid);
        } else if ([key isEqualToString:@"guest"]) {
            uint32_t ip;
            if (parseIPv4(value, &ip)) config.guest = ip;
        } else if ([key isEqualToString:@"route"]) {
            NSString *cidr = canonicalCIDR(value, NULL, NULL);
            if (cidr && routes.count < 32 && ![routes containsObject:cidr]) [routes addObject:cidr];
        } else if ([key isEqualToString:@"rx_filter"]) {
            legacyFilter = [value isEqualToString:@"rtw88"];
        } else if ([key isEqualToString:@"internet"]) {
            config.internet = [value isEqualToString:@"1"];
        }
    }
    if (devices.count == 0 && legacyVid && legacyPid) {
        DeviceConfig *device = [DeviceConfig new];
        device.busid = @"1-1";
        device.vid = legacyVid;
        device.pid = legacyPid;
        device.rxFilter = legacyFilter;
        [devices addObject:device];
    }
    config.routes = routes;
    config.devices = devices;
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

struct Stats {
    unsigned long submitted, completed, control, bulkIn, bulkOut, unlinks, aborts, errors, filtered;
    unsigned long long bytesIn, bytesOut;
    double maxOutMs;
};

/// One USB/IP bus ID: the device configured for it, the VM's connection to it and its counters.
/// Touched only on gStateQueue, except the reply buffer (sendQueue only). IOUSBHost delivers
/// completions on gIOQueue, so synchronous IOUSBHost calls made on gStateQueue never wait on
/// themselves.
@interface Slot : NSObject {
@public
    struct Stats window, summary;
}
@property (nonatomic, copy) NSString *busid;
@property (nonatomic) uint32_t number;                 // 1 for 1-1
@property (nonatomic, strong) DeviceConfig *config;    // nil: nothing wanted under this bus ID
// the captured device
@property (nonatomic) io_service_t service;
@property (nonatomic, strong) IOUSBHostDevice *device;
@property (nonatomic) uint16_t openVid, openPid;
@property (nonatomic, copy) NSString *openSerial;
@property (nonatomic) BOOL openTether;
@property (nonatomic) uint32_t speed;
@property (nonatomic, copy) NSString *state;           // idle, absent, captured, error
@property (nonatomic, copy) NSString *error;
@property (nonatomic) uint64_t lastOpenAttempt;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, IOUSBHostInterface *> *interfaces;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, IOUSBHostPipe *> *pipes;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *maxPacket;
// the VM's connection
@property (nonatomic) int clientFd;
@property (nonatomic) uint32_t clientPeer;
@property (nonatomic) uint32_t conn;                   // 0: no connection
@property (nonatomic) uint64_t clientSince;
@property (nonatomic) unsigned long imports;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, PendingURB *> *urbs;
// counters and the stall watchdog
@property (nonatomic) uint64_t windowStart, summaryStart;
@property (nonatomic) double oldestOutSeconds;
@property (nonatomic) unsigned long stalls, resets, totalErrors;
@property (nonatomic) int stallStage;
@property (nonatomic) uint64_t stallAt, lastReset;
// replies (sendQueue only)
@property (nonatomic, strong) dispatch_queue_t sendQueue;
@property (nonatomic, strong) NSMutableData *pending;
@property (nonatomic) int pendingFd;
@property (nonatomic) BOOL flushQueued;
@end
@implementation Slot
@end

static dispatch_queue_t gStateQueue, gIOQueue, gRouteQueue;
static Config *gConfig;
static BOOL gActive;
static unsigned long gTick;
static NSArray<Slot *> *gSlots;
static uint32_t gConnCounter;

static NSArray<NSDictionary *> *gRouteResult = @[];
static NSString *gGuestInterface;
static BOOL gRoutesBusy;
static NSDictionary *gInternetResult;
static BOOL gInternetBusy;
static NSData *gLastStatus;

static NSString *kindName(Slot *s) { return (s.device ? s.openTether : s.config.tether) ? @"phone" : @"dongle"; }

static Slot *slotForBusid(NSString *busid) {
    for (Slot *s in gSlots) if ([s.busid isEqualToString:busid]) return s;
    return nil;
}

// ------------------------------------------------------------------ USB/IP replies
// Replies that complete together go out in one write: one TCP segment instead of one per
// URB, so the guest takes fewer interrupts. The flush block queues behind the appends. Each
// bus ID has its own queue, so a slow socket never holds up another device's replies.
static void flushPending(Slot *s) {
    if (s.pending.length && s.pendingFd >= 0) writeFull(s.pendingFd, s.pending.bytes, s.pending.length);
    s.pending.length = 0;
}

static void sendToClient(Slot *s, uint32_t conn, NSData *data) {
    if (conn != s.conn || s.clientFd < 0) return;
    int fd = s.clientFd;
    dispatch_async(s.sendQueue, ^{
        if (fd != s.pendingFd) { flushPending(s); s.pendingFd = fd; }
        [s.pending appendData:data];
        if (s.flushQueued) return;
        s.flushQueued = YES;
        dispatch_async(s.sendQueue, ^{ s.flushQueued = NO; flushPending(s); });
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

static void sendRetSubmit(Slot *s, uint32_t conn, uint32_t seq, int32_t status, uint32_t actual,
                          uint32_t packets, NSData *inData) {
    NSMutableData *d = [NSMutableData dataWithCapacity:48 + inData.length];
    put32(d, RET_SUBMIT); put32(d, seq); put32(d, 0); put32(d, 0); put32(d, 0);
    put32(d, (uint32_t)status); put32(d, actual); put32(d, 0); put32(d, packets); put32(d, 0);
    uint8_t pad[8] = {0};
    [d appendBytes:pad length:8];
    if (inData.length) [d appendData:inData];
    sendToClient(s, conn, d);
}

static void sendRetUnlink(Slot *s, uint32_t conn, uint32_t seq, int32_t status) {
    NSMutableData *d = [NSMutableData dataWithCapacity:48];
    put32(d, RET_UNLINK); put32(d, seq); put32(d, 0); put32(d, 0); put32(d, 0);
    put32(d, (uint32_t)status);
    uint8_t pad[24] = {0};
    [d appendBytes:pad length:24];
    sendToClient(s, conn, d);
}

// ------------------------------------------------------------------ device
static void forEachDescriptor(const IOUSBConfigurationDescriptor *cd, void (^body)(const uint8_t *p)) {
    if (!cd) return;
    const uint8_t *p = (const uint8_t *)cd, *end = p + OSSwapLittleToHostInt16(cd->wTotalLength);
    while (p + 2 <= end && p[0] >= 2 && p + p[0] <= end) { body(p); p += p[0]; }
}

static void putDeviceInfo(Slot *s, NSMutableData *d, BOOL withInterfaces) {
    const IOUSBDeviceDescriptor *dd = s.device.deviceDescriptor;
    const IOUSBConfigurationDescriptor *cd = s.device.configurationDescriptor;
    char path[256] = {0}, busid[32] = {0};
    snprintf(path, sizeof path, "/sys/devices/platform/godseon-usbip/usb1/%s", s.busid.UTF8String);
    snprintf(busid, sizeof busid, "%s", s.busid.UTF8String);
    [d appendBytes:path length:sizeof path];
    [d appendBytes:busid length:sizeof busid];
    put32(d, 1);
    put32(d, s.number);           // unique per bus ID; the Mac's own addresses repeat across controllers
    put32(d, s.speed);
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

static void closeInterfaces(Slot *s) {
    for (IOUSBHostPipe *pipe in s.pipes.allValues) [pipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [s.pipes removeAllObjects];
    [s.maxPacket removeAllObjects];
    for (IOUSBHostInterface *intf in s.interfaces.allValues) [intf destroy];
    [s.interfaces removeAllObjects];
}

static void openPipes(Slot *s, IOUSBHostInterface *intf) {
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
                s.pipes[@(address)] = pipe;
                s.maxPacket[@(address)] = @((uint16_t)(p[4] | (p[5] << 8)) & 0x7ff);
            } else {
                logmsg(@"%@ pipe 0x%02x: %@", s.busid, address, error.localizedDescription);
            }
        }
    });
}

static BOOL openInterfaces(Slot *s) {
    const IOUSBConfigurationDescriptor *cd = s.device.configurationDescriptor;
    NSUInteger wanted = cd ? cd->bNumInterfaces : 0;
    for (int attempt = 0; attempt < 60 && s.interfaces.count < wanted; attempt++) {
        io_iterator_t it = 0;
        if (IORegistryEntryGetChildIterator(s.service, kIOServicePlane, &it) == KERN_SUCCESS) {
            io_service_t child;
            while ((child = IOIteratorNext(it))) {
                if (IOObjectConformsTo(child, "IOUSBHostInterface")) {
                    NSError *error = nil;
                    IOUSBHostInterface *intf = [[IOUSBHostInterface alloc] initWithIOService:child
                        options:IOUSBHostObjectInitOptionsNone queue:gIOQueue error:&error interestHandler:nil];
                    if (!intf) {
                        if (attempt == 59) logmsg(@"%@ interface open failed: %@", s.busid, error.localizedDescription);
                    } else if (s.interfaces[@(intf.interfaceDescriptor->bInterfaceNumber)]) {
                        [intf destroy];
                    } else {
                        s.interfaces[@(intf.interfaceDescriptor->bInterfaceNumber)] = intf;
                        openPipes(s, intf);
                    }
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(it);
        }
        if (s.interfaces.count < wanted) usleep(50 * 1000);
    }
    return s.interfaces.count == wanted;
}

static BOOL configure(Slot *s, NSUInteger value) {
    closeInterfaces(s);
    NSError *error = nil;
    if (![s.device configureWithValue:value matchInterfaces:NO error:&error]) {
        logmsg(@"%@ SET_CONFIGURATION %lu failed: %@", s.busid, (unsigned long)value, error.localizedDescription);
        return NO;
    }
    return value == 0 || openInterfaces(s);
}

static void addStats(struct Stats *into, const struct Stats *from) {
    into->submitted += from->submitted; into->completed += from->completed; into->control += from->control;
    into->bulkIn += from->bulkIn; into->bulkOut += from->bulkOut; into->unlinks += from->unlinks;
    into->aborts += from->aborts; into->errors += from->errors; into->filtered += from->filtered;
    into->bytesIn += from->bytesIn; into->bytesOut += from->bytesOut;
    into->maxOutMs = MAX(into->maxOutMs, from->maxOutMs);
}

static void logSummary(Slot *s, NSString *what) {
    double seconds = MAX(secondsSince(s.summaryStart), 1);
    struct Stats *t = &s->summary;
    logmsg(@"%@ %@: %.0f s, %lu urbs (%.0f/s: control %.0f, bulk in %.0f, bulk out %.0f), %.1f MB in, %.1f MB out "
           "(%.2f / %.2f Mbit/s), max out %.0f ms, errors %lu, unlinks %lu, aborts %lu, filtered %lu", s.busid, what, seconds,
           t->submitted, t->submitted / seconds, t->control / seconds, t->bulkIn / seconds, t->bulkOut / seconds,
           t->bytesIn / 1e6, t->bytesOut / 1e6, t->bytesIn * 8 / seconds / 1e6, t->bytesOut * 8 / seconds / 1e6,
           t->maxOutMs, t->errors, t->unlinks, t->aborts, t->filtered);
    memset(&s->summary, 0, sizeof s->summary);
    s.summaryStart = nowNs();
}

/// Ends the VM's connection (the reader thread then sees EOF) and forgets its requests.
static void endClient(Slot *s, uint32_t conn, NSString *why) {
    if (conn != s.conn || s.clientFd < 0) return;
    addStats(&s->summary, &s->window);
    memset(&s->window, 0, sizeof s->window);
    s.windowStart = nowNs();
    logSummary(s, [NSString stringWithFormat:@"VM connection closed (%@)", why]);
    shutdown(s.clientFd, SHUT_RDWR);
    s.conn = 0;
    s.clientFd = -1;
    s.clientPeer = 0;
    s.stallStage = 0;
    for (IOUSBHostPipe *pipe in s.pipes.allValues) [pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
    [s.device abortDeviceRequestsWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
    [s.urbs removeAllObjects];
}

static void closeDevice(Slot *s, NSString *state) {
    endClient(s, s.conn, [NSString stringWithFormat:@"%@ released", kindName(s)]);
    closeInterfaces(s);
    if (s.device) {
        [s.device destroy];                // gives the device back to macOS
        s.device = nil;
        logmsg(@"%@ released %04x:%04x", s.busid, s.openVid, s.openPid);
    }
    if (s.service) { IOObjectRelease(s.service); s.service = 0; }
    s.state = state;
}

/// The registry entry of the device a slot wants, or 0. With a serial number only that device
/// matches, and a device another bus ID already holds never does.
static io_service_t findDevice(Slot *s, DeviceConfig *want) {
    CFMutableDictionaryRef match = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(want.vid) productID:@(want.pid)
        bcdDevice:nil deviceClass:nil deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:nil];
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS) return 0;   // takes match
    io_service_t found = 0, service;
    while (!found && (service = IOIteratorNext(it))) {
        BOOL usable = YES;
        for (Slot *other in gSlots) {
            if (other != s && other.service && IOObjectIsEqualTo(other.service, service)) usable = NO;
        }
        if (usable && want.serial) {
            NSString *serial = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR("USB Serial Number"),
                                                                                 kCFAllocatorDefault, 0));
            usable = [serial isKindOfClass:NSString.class] && [serial isEqualToString:want.serial];
        }
        if (usable) found = service; else IOObjectRelease(service);
    }
    IOObjectRelease(it);
    return found;
}

static void ensureDevice(Slot *s) {
    DeviceConfig *want = gActive ? s.config : nil;
    if (!want) {
        if (s.device) closeDevice(s, @"idle");
        s.state = @"idle";
        s.error = @"";
        return;
    }
    BOOL sameSerial = (!s.openSerial && !want.serial) || [s.openSerial isEqualToString:want.serial];
    if (s.device && (s.openVid != want.vid || s.openPid != want.pid || !sameSerial)) closeDevice(s, @"idle");
    if (s.device) return;
    if (s.lastOpenAttempt && secondsSince(s.lastOpenAttempt) < 2) return;
    s.lastOpenAttempt = nowNs();
    uint16_t vid = want.vid, pid = want.pid;
    NSString *kind = want.tether ? @"phone" : @"dongle";
    io_service_t service = findDevice(s, want);
    if (!service) {
        if (![s.state isEqualToString:@"absent"]) logmsg(@"%@ %@ %04x:%04x is not plugged in", s.busid, kind, vid, pid);
        s.state = @"absent";
        s.error = @"";
        return;
    }
    NSError *error = nil;
    IOUSBHostDevice *opened = [[IOUSBHostDevice alloc] initWithIOService:service options:IOUSBHostObjectInitOptionsDeviceCapture
        queue:gIOQueue error:&error interestHandler:^(IOUSBHostObject *object, uint32_t type, void *argument) {
            if (type != kIOMessageServiceIsTerminated) return;
            dispatch_async(gStateQueue, ^{
                if (s.device && s.device == (IOUSBHostDevice *)object) {
                    logmsg(@"%@ %@ unplugged", s.busid, kindName(s));
                    closeDevice(s, @"absent");
                }
            });
        }];
    if (!opened) {
        IOObjectRelease(service);
        NSString *message = error.localizedDescription ?: @"unknown error";
        if (![s.error isEqualToString:message]) logmsg(@"%@ cannot capture %04x:%04x: %@", s.busid, vid, pid, message);
        s.state = @"error";
        s.error = message;
        return;
    }
    s.device = opened;
    s.service = service;
    s.openVid = vid;
    s.openPid = pid;
    s.openSerial = want.serial;
    s.openTether = want.tether;
    s.error = @"";
    s.speed = 3;
    CFTypeRef speed = IORegistryEntryCreateCFProperty(service, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
    if (speed) {
        int legacy = [(__bridge NSNumber *)speed intValue];      // 0 low, 1 full, 2 high, 3 super, 4 super+
        const uint32_t map[] = {1, 2, 3, 5, 6};
        if (legacy >= 0 && legacy <= 4) s.speed = map[legacy];
        CFRelease(speed);
    }
    if (s.device.configurationDescriptor) openInterfaces(s);
    s.state = @"captured";
    logmsg(@"%@ captured %@ %04x:%04x (speed %u, %lu interface(s), %lu pipe(s))", s.busid, kind, vid, pid, s.speed,
           (unsigned long)s.interfaces.count, (unsigned long)s.pipes.count);
}

// ------------------------------------------------------------------ URBs
static void track(Slot *s, uint32_t conn, uint32_t seq, uint8_t address) {
    PendingURB *urb = [PendingURB new];
    urb.conn = conn;
    urb.address = address;
    urb.started = nowNs();
    s.urbs[@(seq)] = urb;
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

static BOOL enqueueBulk(Slot *s, uint32_t conn, uint32_t seq, IOUSBHostPipe *pipe, NSMutableData *buffer,
                        uint32_t packets, BOOL in, BOOL zeroPacket, NSError **error);

static void finish(Slot *s, uint32_t conn, uint32_t seq, IOReturn status, NSUInteger bytes, uint32_t packets,
                   NSMutableData *inData, BOOL in) {
    PendingURB *urb = s.urbs[@(seq)];
    if (!urb || urb.conn != conn) return;           // from an earlier connection
    if (in && conn == s.conn && urb.address != 0 && !urb.unlinked && status == kIOReturnSuccess && s.config.rxFilter &&
        rtw88OnlyTriggerFrames(inData.bytes, MIN(bytes, inData.length))) {
        IOUSBHostPipe *pipe = s.pipes[@(urb.address)];
        if (pipe && enqueueBulk(s, conn, seq, pipe, inData, packets, YES, NO, NULL)) {
            s->window.filtered++;
            return;                                  // still pending for the guest
        }
    }
    [s.urbs removeObjectForKey:@(seq)];
    s->window.completed++;
    if (urb.address != 0 && !in) s->window.maxOutMs = MAX(s->window.maxOutMs, (double)(nowNs() - urb.started) / 1e6);
    if (urb.unlinked) return;                       // the guest already got RET_UNLINK
    int32_t st = mapStatus(status);
    if (st != 0) { s->window.errors++; s.totalErrors++; }
    if (in) s->window.bytesIn += bytes; else s->window.bytesOut += bytes;
    NSData *payload = (in && bytes > 0) ? [inData subdataWithRange:NSMakeRange(0, MIN(bytes, inData.length))] : nil;
    sendRetSubmit(s, conn, seq, st, (uint32_t)bytes, packets, payload);
}

static void control(Slot *s, uint32_t conn, uint32_t seq, BOOL in, uint64_t setupBits, NSMutableData *outData,
                    uint32_t packets) {
    const uint8_t *b = (const uint8_t *)&setupBits;
    IOUSBDeviceRequest request = {
        .bmRequestType = b[0], .bRequest = b[1],
        .wValue = (uint16_t)(b[2] | (b[3] << 8)), .wIndex = (uint16_t)(b[4] | (b[5] << 8)),
        .wLength = (uint16_t)(b[6] | (b[7] << 8)),
    };
    s->window.control++;
    // Requests that change state on the macOS side go through IOUSBHost's own calls,
    // the same set the Linux usbip host driver intercepts.
    if (request.bmRequestType == 0x00 && request.bRequest == 9) {               // SET_CONFIGURATION
        sendRetSubmit(s, conn, seq, configure(s, request.wValue) ? 0 : -EPIPE, 0, packets, nil);
        return;
    }
    if (request.bmRequestType == 0x01 && request.bRequest == 11) {              // SET_INTERFACE
        IOUSBHostInterface *intf = s.interfaces[@(request.wIndex & 0xff)];
        NSError *error = nil;
        BOOL ok = intf && [intf selectAlternateSetting:request.wValue error:&error];
        if (ok) openPipes(s, intf); else logmsg(@"%@ SET_INTERFACE failed: %@", s.busid, error.localizedDescription);
        sendRetSubmit(s, conn, seq, ok ? 0 : -EPIPE, 0, packets, nil);
        return;
    }
    if (request.bmRequestType == 0x02 && request.bRequest == 1 && request.wValue == 0) {   // CLEAR_FEATURE(HALT)
        [s.pipes[@(request.wIndex & 0xff)] clearStallWithError:nil];
        sendRetSubmit(s, conn, seq, 0, 0, packets, nil);
        return;
    }
    if (request.bmRequestType == 0x23 && request.bRequest == 3 && request.wValue == 4) {   // SET_FEATURE(PORT_RESET)
        NSUInteger value = s.device.configurationDescriptor ? s.device.configurationDescriptor->bConfigurationValue : 0;
        closeInterfaces(s);
        NSError *error = nil;
        if (![s.device resetWithError:&error]) logmsg(@"%@ device reset failed: %@", s.busid, error.localizedDescription);
        if (value) configure(s, value);
        sendRetSubmit(s, conn, seq, 0, 0, packets, nil);
        return;
    }
    NSMutableData *buffer = in ? [[NSMutableData alloc] initWithLength:request.wLength]
                               : (outData.length ? outData : nil);
    track(s, conn, seq, 0);
    NSError *error = nil;
    BOOL queued = [s.device enqueueDeviceRequest:request data:buffer completionTimeout:5.0 error:&error
        completionHandler:^(IOReturn status, NSUInteger bytes) {
            dispatch_async(gStateQueue, ^{ finish(s, conn, seq, status, bytes, packets, buffer, in); });
        }];
    if (!queued) {
        [s.urbs removeObjectForKey:@(seq)];
        sendRetSubmit(s, conn, seq, s.device ? -EPIPE : -ESHUTDOWN, 0, packets, nil);
    }
}

static BOOL enqueueBulk(Slot *s, uint32_t conn, uint32_t seq, IOUSBHostPipe *pipe, NSMutableData *buffer,
                        uint32_t packets, BOOL in, BOOL zeroPacket, NSError **error) {
    return [pipe enqueueIORequestWithData:buffer completionTimeout:0 error:error
        completionHandler:^(IOReturn status, NSUInteger bytes) {
            if (zeroPacket && status == kIOReturnSuccess) {
                [pipe enqueueIORequestWithData:[[NSMutableData alloc] init] completionTimeout:0 error:nil
                    completionHandler:^(IOReturn zlpStatus, NSUInteger zlpBytes) {
                        dispatch_async(gStateQueue, ^{ finish(s, conn, seq, status, bytes, packets, buffer, in); });
                    }];
                return;
            }
            dispatch_async(gStateQueue, ^{ finish(s, conn, seq, status, bytes, packets, buffer, in); });
        }];
}

static void submit(Slot *s, uint32_t conn, uint32_t seq, uint32_t direction, uint32_t ep, uint32_t flags,
                   int32_t length, uint32_t packets, uint64_t setupBits, NSMutableData *outData) {
    if (conn != s.conn) return;
    s->window.submitted++;
    BOOL in = direction == 1;
    if (ep == 0) { control(s, conn, seq, in, setupBits, outData, packets); return; }
    if (packets != 0 && packets != 0xffffffff) { sendRetSubmit(s, conn, seq, -EPROTO, 0, packets, nil); return; }  // no isochronous
    uint8_t address = (uint8_t)(ep | (in ? 0x80 : 0));
    IOUSBHostPipe *pipe = s.pipes[@(address)];
    if (!pipe) { sendRetSubmit(s, conn, seq, s.device ? -EPIPE : -ESHUTDOWN, 0, packets, nil); return; }
    if (in) s->window.bulkIn++; else s->window.bulkOut++;
    // a plain buffer: IOUSBHost's ioDataWithCapacity: buffers refuse length changes
    NSMutableData *buffer = in ? [[NSMutableData alloc] initWithLength:(NSUInteger)MAX(length, 0)]
                               : (outData ?: [[NSMutableData alloc] init]);
    NSUInteger maxPacket = s.maxPacket[@(address)].unsignedIntegerValue;
    BOOL zeroPacket = !in && (flags & URB_ZERO_PACKET) && length > 0 && maxPacket && (length % maxPacket) == 0;
    track(s, conn, seq, address);
    NSError *error = nil;
    BOOL queued = enqueueBulk(s, conn, seq, pipe, buffer, packets, in, zeroPacket, &error);
    if (!queued) {
        [s.urbs removeObjectForKey:@(seq)];
        logmsg(@"%@ ep 0x%02x: failed to queue %d bytes: %@", s.busid, address, length, error.localizedDescription);
        sendRetSubmit(s, conn, seq, -EPIPE, 0, packets, nil);
    }
}

// IOUSBHost can only cancel every request on an endpoint at once, so an endpoint is aborted
// when the last request still queued on it gets unlinked (what a driver does when it stops:
// it kills all its URBs). Unlinked requests are never answered again.
static void unlinkURB(Slot *s, uint32_t conn, uint32_t seq, uint32_t target) {
    if (conn != s.conn) return;
    PendingURB *urb = s.urbs[@(target)];
    BOOL pending = urb && urb.conn == conn && !urb.unlinked;
    if (pending) {
        urb.unlinked = YES;
        s->window.unlinks++;
        BOOL othersLive = NO;
        for (PendingURB *other in s.urbs.allValues) {
            if (other != urb && other.conn == conn && other.address == urb.address && !other.unlinked) { othersLive = YES; break; }
        }
        if (!othersLive) {
            s->window.aborts++;
            if (urb.address == 0) [s.device abortDeviceRequestsWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
            else [s.pipes[@(urb.address)] abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        }
    }
    sendRetUnlink(s, conn, seq, pending ? -ECONNRESET : 0);
}

// A bulk OUT request that waits kStallSeconds means the device stopped taking data. First
// abort that endpoint (the driver sees failed transfers and carries on); if a dongle stalls
// again right after, reset it and drop the VM's connection: the guest re-attaches by itself
// (about 15 s offline). Resets are spaced kResetSpacingSeconds apart. A phone only ever gets
// the abort: a reset would take it out of tethering. late: see tick().
static void watchdog(Slot *s, BOOL late) {
    s.oldestOutSeconds = 0;
    if (s.clientFd < 0) { s.stallStage = 0; return; }
    uint8_t address = 0;
    uint64_t now = nowNs();
    double oldest = 0;
    for (PendingURB *urb in s.urbs.allValues) {
        if (urb.unlinked || urb.address == 0 || (urb.address & 0x80)) continue;
        double age = (double)(now - urb.started) / 1e9;
        if (age > oldest) { oldest = age; address = urb.address; }
    }
    s.oldestOutSeconds = oldest;
    if (late) return;
    if (oldest < kStallSeconds) {
        if (s.stallStage && secondsSince(s.stallAt) > 60) s.stallStage = 0;
        return;
    }
    if (s.stallStage == 0) {
        s.stalls++;
        s.stallStage = 1;
        s.stallAt = now;
        logmsg(@"%@ TX stall: a bulk OUT request on 0x%02x has waited %.0f s; aborting the endpoint", s.busid, address, oldest);
        [s.pipes[@(address)] abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        return;
    }
    if (secondsSince(s.stallAt) < kStallSeconds) return;
    if (s.openTether) {
        logmsg(@"%@ TX stalled again on 0x%02x; aborting the endpoint (phones are never reset)", s.busid, address);
        [s.pipes[@(address)] abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        s.stallAt = now;
        return;
    }
    if (s.lastReset && secondsSince(s.lastReset) < kResetSpacingSeconds) {
        logmsg(@"%@ TX stalled again on 0x%02x; aborting the endpoint (next reset allowed in %.0f s)", s.busid, address,
               kResetSpacingSeconds - secondsSince(s.lastReset));
        [s.pipes[@(address)] abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        s.stallAt = now;
        return;
    }
    s.resets++;
    s.lastReset = now;
    s.stallStage = 0;
    logmsg(@"%@ TX still stalled after the abort; resetting the dongle and reconnecting the VM", s.busid);
    endClient(s, s.conn, @"TX stall");
    NSError *error = nil;
    if (s.device && ![s.device resetWithError:&error]) logmsg(@"%@ dongle reset failed: %@", s.busid, error.localizedDescription);
    closeDevice(s, @"idle");            // captured again on the next tick
    s.lastOpenAttempt = 0;
}

// ------------------------------------------------------------------ external tools
static int runTool(NSString *tool, NSArray<NSString *> *args, NSString **output) {
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
    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:tool];
    [all addObjectsFromArray:args];
    char *argv[16];
    NSUInteger count = MIN(all.count, (NSUInteger)15);
    for (NSUInteger i = 0; i < count; i++) argv[i] = (char *)all[i].UTF8String;
    argv[count] = NULL;
    pid_t child = 0;
    int rc = posix_spawn(&child, tool.fileSystemRepresentation, &actions, &attributes, argv, environ);
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

static int runRoute(NSArray<NSString *> *args, NSString **output) {
    return runTool(@"/sbin/route", [@[@"-n"] arrayByAddingObjectsFromArray:args], output);
}

// ------------------------------------------------------------------ routes (gRouteQueue)
static NSMutableDictionary<NSString *, NSString *> *gOwned;     // cidr -> guest it points at

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

/// The bridge's own subnets as CIDRs: the VM's NAT link and, while it is up, the host link.
static NSArray<NSString *> *bridgeSubnets(NSString *interface) {
    NSMutableArray<NSString *> *subnets = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (!interface || getifaddrs(&list) != 0) return subnets;
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET || !ifa->ifa_netmask) continue;
        if (strcmp(ifa->ifa_name, interface.UTF8String) != 0) continue;
        uint32_t address = ntohl(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr);
        uint32_t mask = ntohl(((struct sockaddr_in *)ifa->ifa_netmask)->sin_addr.s_addr);
        int prefix = __builtin_popcount(mask);
        if (prefix < 1) continue;
        NSString *cidr = [NSString stringWithFormat:@"%@/%d", formatIPv4(address & mask), prefix];
        if (![subnets containsObject:cidr]) [subnets addObject:cidr];
    }
    freeifaddrs(list);
    return subnets;
}

/// Host entries on the bridge for an address outside the bridge's own subnets with no link
/// address (netstat "link#N"). Nothing outside those subnets sits on the bridge, so such an
/// entry is always a failed guess: while the bridge had no gateway route for that address (our
/// dongle route briefly away, or before the phone's service became primary), something looked
/// it up scoped to the bridge, where macOS keeps an on-link scoped default ("default link#N
/// UCSIg"); it asked the bridge, nobody answered, and the failure stays as a host entry. Being a
/// host route it beats our routes, the phone's default route included, and every new attempt
/// renews it: one server on the dongle's network stays unreachable while its neighbours work,
/// or the Mac's internet through the phone leaves from the bridge address and never reaches the
/// phone. Returns "address" for each such entry.
static NSArray<NSString *> *shadowingEntries(NSString *netstat, NSArray<NSString *> *subnets, NSString *interface) {
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *line in [netstat componentsSeparatedByString:@"\n"]) {
        NSMutableArray<NSString *> *fields = [NSMutableArray array];
        for (NSString *field in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
            if (field.length) [fields addObject:field];
        }
        // Destination Gateway Flags Netif [Expire]
        if (fields.count < 4 || ![fields[3] isEqualToString:interface] || ![fields[1] hasPrefix:@"link#"]) continue;
        if ([fields[2] rangeOfString:@"H"].location == NSNotFound) continue;
        uint32_t address;
        if (!parseIPv4(fields[0], &address) || (address >> 28) == 0xe || address == 0xffffffff) continue;  // multicast, broadcast
        BOOL onBridge = NO;
        for (NSString *cidr in subnets) {
            uint32_t net;
            int prefix;
            if (canonicalCIDR(cidr, &net, &prefix) && (address & maskOf(prefix)) == net) onBridge = YES;
        }
        if (!onBridge) [found addObject:fields[0]];
    }
    return found;
}

static NSMutableDictionary<NSString *, NSDate *> *gShadowLogged;     // address -> last logged (gRouteQueue)

/// The bridge's on-link scoped default ("default link#N UCSIg"), which macOS keeps for the vmnet
/// bridge. Once the phone's service makes the bridge the primary interface, lookups go by the
/// primary interface's scope, and this route beats the service's default through the guest:
/// every internet address then counts as sitting on the bridge, leaves from the bridge address
/// and never reaches the phone. It is taken away while the service is published and put back
/// when it goes.
static BOOL hasOnLinkScopedDefault(NSString *bridge) {
    NSString *out = nil;
    if (runTool(@"/usr/sbin/netstat", @[@"-rn", @"-f", @"inet"], &out) != 0) return NO;
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSMutableArray<NSString *> *fields = [NSMutableArray array];
        for (NSString *field in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
            if (field.length) [fields addObject:field];
        }
        if (fields.count >= 4 && [fields[0] isEqualToString:@"default"] && [fields[1] hasPrefix:@"link#"]
            && [fields[3] isEqualToString:bridge] && [fields[2] rangeOfString:@"I"].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *gScopedDefaultTakenFrom;       // the bridge whose on-link scoped default we removed

static void takeScopedDefault(NSString *bridge) {
    if (!hasOnLinkScopedDefault(bridge)) return;
    if (runRoute(@[@"delete", @"default", @"-ifscope", bridge], nil) == 0) {
        if (!gScopedDefaultTakenFrom) logmsg(@"took the on-link scoped default off %@ while the phone is the internet", bridge);
        gScopedDefaultTakenFrom = bridge;
    }
}

static void restoreScopedDefault(void) {
    NSString *bridge = gScopedDefaultTakenFrom;
    if (!bridge) return;
    gScopedDefaultTakenFrom = nil;
    if (bridgeSubnets(bridge).count == 0 || hasOnLinkScopedDefault(bridge)) return;   // bridge gone, or back already
    if (runRoute(@[@"add", @"-net", @"default", @"-interface", bridge, @"-ifscope", bridge], nil) == 0) {
        logmsg(@"put the on-link scoped default back on %@", bridge);
    }
}

static void dropShadowingEntries(NSString *interface) {
    NSArray<NSString *> *subnets = bridgeSubnets(interface);
    if (subnets.count == 0) return;
    NSString *out = nil;
    if (runTool(@"/usr/sbin/netstat", @[@"-rn", @"-f", @"inet"], &out) != 0) return;
    if (!gShadowLogged) gShadowLogged = [NSMutableDictionary dictionary];
    for (NSString *address in shadowingEntries(out, subnets, interface)) {
        if (runRoute(@[@"delete", @"-host", address, @"-ifscope", interface], nil) != 0) continue;
        NSDate *last = gShadowLogged[address];
        if (!last || -last.timeIntervalSinceNow > 60) {
            logmsg(@"removed a stale on-link entry for %@ on %@ (only %@ are on the bridge)", address, interface,
                   [subnets componentsJoinedByString:@", "]);
            gShadowLogged[address] = [NSDate date];
        }
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

// ------------------------------------------------------------------ phone internet (gRouteQueue)
// The service is what makes macOS use the phone: IPMonitor ranks a service with OverridePrimary
// first, so the default route and the DNS servers become the guest's (as for a VPN). Its keys
// are temporary: configd removes them by itself when this process goes away, and macOS then
// falls back to the networks it had. The keys stay put through Wi-Fi changes, while the alias
// lives as long as the bridge (vmnet removes the bridge with the last VM on it).
static SCDynamicStoreRef gStore;
static NSString *gPublishedOn;              // the bridge carrying the alias and named in the service

static NSString *serviceKey(NSString *entity) {
    return [NSString stringWithFormat:@"State:/Network/Service/%@/%@", kTetherService, entity];
}

/// The interface other than `except` with an address inside the host link, or nil. A vmnet
/// bridge still holding our own alias (left by a helper that died) is cleaned up instead.
static NSString *hostLinkUser(NSString *except) {
    uint32_t ours = 0;
    parseIPv4(kHostLinkMac, &ours);
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *found = nil;
    NSMutableArray<NSString *> *stale = [NSMutableArray array];
    for (struct ifaddrs *ifa = list; ifa && !found; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        uint32_t address = ntohl(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr);
        if ((address & maskOf(kHostLinkPrefix)) != kHostLinkNet) continue;
        if (except && strcmp(ifa->ifa_name, except.UTF8String) == 0) continue;
        if (address == ours && strncmp(ifa->ifa_name, "bridge", 6) == 0) [stale addObject:@(ifa->ifa_name)];
        else found = @(ifa->ifa_name);
    }
    freeifaddrs(list);
    for (NSString *bridge in stale) {
        runTool(@"/sbin/ifconfig", @[bridge, @"-alias", kHostLinkMac], nil);
        logmsg(@"removed a leftover host link %@ from %@", kHostLinkMac, bridge);
    }
    return found;
}

static BOOL hasAddress(NSString *interface, NSString *text) {
    uint32_t wanted;
    if (!interface || !parseIPv4(text, &wanted)) return NO;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return NO;
    BOOL found = NO;
    for (struct ifaddrs *ifa = list; ifa && !found; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET || strcmp(ifa->ifa_name, interface.UTF8String) != 0) continue;
        found = ntohl(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr) == wanted;
    }
    freeifaddrs(list);
    return found;
}

// The vmnet bridge advertises TSO (bridge100: TSO4,TSO6), so macOS hands the guest TCP segments
// of up to 64 KB, which its virtio-net takes as GSO packets. Forwarded to wlan0 they go out
// fine, but on the way to usb0 (rndis_host) only part of each reaches the phone and the server
// resets the connection: uploads from the Mac over the phone stopped at about 130 KB, while the
// guest's own uploads worked. ThruRNDIS never sees this, since its Mac side is a Bond over a feth
// pair, which has no TSO. The bridge does not let TSO be turned off on it alone (SIOCSIFCAP:
// not supported), so it goes off Mac-wide while the phone's service is published, and before
// it is, so that connections opened over the phone never use it.
// Through the dongle the 64 KB segments arrive, but each one leaves the guest as a burst of
// some 45 frames at once: big uploads over a busy channel retransmitted up to 28% of their
// bytes at 1-2 Mbit/s, and with TSO off one ran at 41 Mbit/s with almost none (on a quieter
// channel). So a dongle whose line says tso=off has it off too while the VM has it (tick
// decides, before the phone's service is published). The value replaced is kept in kTSOMarkPath, which a restart clears
// along with the setting, so that a helper that died puts it back. TSO that was off already
// is not ours and stays off.
static NSString *const kTSOMarkPath = @"/var/run/godseon-dongled.tso";
static int gTSOSaved = -2;                      // -2 not read yet, -1 not taken, else the value replaced

static void loadTSOMark(void) {
    if (gTSOSaved != -2) return;
    NSString *text = [NSString stringWithContentsOfFile:kTSOMarkPath encoding:NSUTF8StringEncoding error:nil];
    gTSOSaved = text ? MAX(text.intValue, 1) : -1;
}

static void takeTSO(void) {
    loadTSOMark();
    if (gTSOSaved >= 0) return;
    int value = 0, off = 0;
    size_t size = sizeof value;
    if (sysctlbyname("net.inet.tcp.tso", &value, &size, NULL, 0) != 0 || value == 0) return;
    [[NSString stringWithFormat:@"%d\n", value] writeToFile:kTSOMarkPath atomically:YES
                                                   encoding:NSUTF8StringEncoding error:nil];
    if (sysctlbyname("net.inet.tcp.tso", NULL, NULL, &off, sizeof off) != 0) {
        int saved = errno;
        unlink(kTSOMarkPath.fileSystemRepresentation);
        logmsg(@"could not turn TCP segmentation offload off: %s", strerror(saved));
        return;
    }
    gTSOSaved = value;
    logmsg(@"turned TCP segmentation offload off (net.inet.tcp.tso %d -> 0) for traffic through the VM", value);
}

static void restoreTSO(void) {
    loadTSOMark();
    if (gTSOSaved < 0) return;
    int value = gTSOSaved, current = 0;
    size_t size = sizeof current;
    gTSOSaved = -1;
    unlink(kTSOMarkPath.fileSystemRepresentation);
    // Turned back on by someone else meanwhile: left as it is.
    if (sysctlbyname("net.inet.tcp.tso", &current, &size, NULL, 0) != 0 || current != 0) return;
    if (sysctlbyname("net.inet.tcp.tso", NULL, NULL, &value, sizeof value) == 0) {
        logmsg(@"turned TCP segmentation offload back on (net.inet.tcp.tso %d)", value);
    } else {
        logmsg(@"could not turn TCP segmentation offload back on: %s", strerror(errno));
    }
}

static void withdrawInternet(void) {
    restoreScopedDefault();
    if (!gPublishedOn) {
        hostLinkUser(nil);                  // drops an alias a helper that died left behind
        return;
    }
    if (gStore) {
        SCDynamicStoreRemoveValue(gStore, (__bridge CFStringRef)serviceKey(@"IPv4"));
        SCDynamicStoreRemoveValue(gStore, (__bridge CFStringRef)serviceKey(@"DNS"));
    }
    if (hasAddress(gPublishedOn, kHostLinkMac)) runTool(@"/sbin/ifconfig", @[gPublishedOn, @"-alias", kHostLinkMac], nil);
    logmsg(@"phone internet withdrawn from %@", gPublishedOn);
    gPublishedOn = nil;
}

static NSDictionary *internetResult(NSString *state, NSString *error) {
    return @{@"state": state, @"error": error ?: @"", @"interface": gPublishedOn ?: @""};
}

/// bridge nil: the service and the alias go. Otherwise both are made to exist on that bridge.
static NSDictionary *applyInternet(NSString *bridge) {
    if (!bridge) {
        withdrawInternet();
        return internetResult(@"off", nil);
    }
    if (gPublishedOn && ![gPublishedOn isEqualToString:bridge]) withdrawInternet();
    NSString *user = hostLinkUser(bridge);
    if (user) {
        withdrawInternet();
        return internetResult(@"error", [NSString stringWithFormat:@"%@ already has an address in %@/%d", user,
                                         formatIPv4(kHostLinkNet), kHostLinkPrefix]);
    }
    if (!hasAddress(bridge, kHostLinkMac)) {
        NSString *out = nil;
        runTool(@"/sbin/ifconfig", @[bridge, @"alias", kHostLinkMac, @"netmask", kHostLinkMask], &out);
        if (!hasAddress(bridge, kHostLinkMac)) {
            NSString *why = [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return internetResult(@"error", [NSString stringWithFormat:@"cannot add %@ to %@: %@", kHostLinkMac, bridge, why]);
        }
        logmsg(@"host link %@/%d added to %@", kHostLinkMac, kHostLinkPrefix, bridge);
    }
    if (!gStore) gStore = SCDynamicStoreCreate(NULL, CFSTR("godseon-dongled"), NULL, NULL);
    if (!gStore) return internetResult(@"error", @"cannot open the dynamic store");
    NSDictionary *ipv4 = @{
        (__bridge NSString *)kSCPropNetIPv4Addresses: @[kHostLinkMac],
        (__bridge NSString *)kSCPropNetIPv4SubnetMasks: @[kHostLinkMask],
        (__bridge NSString *)kSCPropNetIPv4Router: kHostLinkGuest,
        (__bridge NSString *)kSCPropInterfaceName: bridge,
        (__bridge NSString *)kSCPropNetOverridePrimary: @1,
    };
    NSDictionary *dns = @{(__bridge NSString *)kSCPropNetDNSServerAddresses: @[kHostLinkGuest]};
    CFStringRef ipv4Key = (__bridge CFStringRef)serviceKey(@"IPv4"), dnsKey = (__bridge CFStringRef)serviceKey(@"DNS");
    NSDictionary *current = CFBridgingRelease(SCDynamicStoreCopyValue(gStore, ipv4Key));
    NSDictionary *currentDNS = CFBridgingRelease(SCDynamicStoreCopyValue(gStore, dnsKey));
    // Checked every pass: a configd restart takes the keys away.
    if (![current isEqual:ipv4] || ![currentDNS isEqual:dns]) {
        SCDynamicStoreRemoveValue(gStore, ipv4Key);
        SCDynamicStoreRemoveValue(gStore, dnsKey);
        if (!SCDynamicStoreAddTemporaryValue(gStore, dnsKey, (__bridge CFDictionaryRef)dns)
            || !SCDynamicStoreAddTemporaryValue(gStore, ipv4Key, (__bridge CFDictionaryRef)ipv4)) {
            NSString *why = @(SCErrorString(SCError()));
            SCDynamicStoreRemoveValue(gStore, dnsKey);
            CFRelease(gStore);              // a fresh session next time, in case configd restarted
            gStore = NULL;
            gPublishedOn = bridge;          // the alias is up; withdrawInternet() takes it down
            return internetResult(@"error", [NSString stringWithFormat:@"cannot publish the network service: %@", why]);
        }
        logmsg(@"phone internet published on %@: %@ via %@, DNS %@", bridge, kHostLinkMac, kHostLinkGuest, kHostLinkGuest);
    }
    gPublishedOn = bridge;
    NSDictionary *global = CFBridgingRelease(SCDynamicStoreCopyValue(gStore, CFSTR("State:/Network/Global/IPv4")));
    id primary = [global isKindOfClass:NSDictionary.class] ? global[(__bridge NSString *)kSCDynamicStorePropNetPrimaryService] : nil;
    // While published, the bridge's on-link scoped default would win (see takeScopedDefault),
    // and entries cloned from it before it went would keep addresses on the bridge address.
    takeScopedDefault(bridge);
    if ([primary isEqual:kTetherService]) dropShadowingEntries(bridge);
    return internetResult([primary isEqual:kTetherService] ? @"primary" : @"published", nil);
}

// ------------------------------------------------------------------ status
static NSDictionary *slotStatus(Slot *s) {
    double seconds = MAX(secondsSince(s.windowStart), 0.5);
    struct Stats *w = &s->window;
    NSDictionary *status = @{
        @"busid": s.busid,
        @"kind": (s.device ? s.openTether : s.config.tether) ? @"tether" : @"wifi",
        @"usb": [NSString stringWithFormat:@"%04x:%04x", s.config ? s.config.vid : s.openVid, s.config ? s.config.pid : s.openPid],
        @"device": s.state ?: @"idle",
        @"device_error": s.error ?: @"",
        @"client": @((BOOL)(s.clientFd >= 0)),       // a BOOL, so JSON gets true/false, not 1/0
        @"client_seconds": @(s.clientFd >= 0 ? (long)secondsSince(s.clientSince) : 0),
        @"imports": @(s.imports),
        @"oldest_out_ms": @(round(s.oldestOutSeconds * 1000)),
        @"errors": @(s.totalErrors),
        @"stalls": @(s.stalls),
        @"resets": @(s.resets),
        @"in_mbps": @(round(w->bytesIn * 8 / seconds / 1e4) / 100),
        @"out_mbps": @(round(w->bytesOut * 8 / seconds / 1e4) / 100),
        @"max_out_ms": @(round(w->maxOutMs)),
        @"urbs_per_s": @(round(w->submitted / seconds)),
        @"control_per_s": @(round(w->control / seconds)),
        @"in_per_s": @(round(w->bulkIn / seconds)),
        @"out_per_s": @(round(w->bulkOut / seconds)),
        @"filtered_per_s": @(round(w->filtered / seconds)),
    };
    addStats(&s->summary, &s->window);
    memset(&s->window, 0, sizeof s->window);
    s.windowStart = nowNs();
    if (s.clientFd >= 0 && secondsSince(s.summaryStart) >= kSummarySeconds) logSummary(s, @"traffic");
    return status;
}

static void writeStatus(void) {
    NSMutableArray<NSDictionary *> *devices = [NSMutableArray array];
    NSDictionary *first = nil;
    for (Slot *s in gSlots) {
        if (!s.config && !s.device) continue;
        NSDictionary *device = slotStatus(s);
        [devices addObject:device];
        if (s.number == 1) first = device;
    }
    NSDictionary *internet = gInternetResult ?: internetResult(@"off", nil);
    NSMutableDictionary *status = [@{
        @"version": @2,
        @"pid": @(getpid()),
        @"active": @(gActive),
        @"owner": @(gConfig.owner),
        @"guest": gConfig.guest ? formatIPv4(gConfig.guest) : @"",
        @"guest_interface": gGuestInterface ?: @"",
        @"routes": gRouteResult ?: @[],
        @"devices": devices,
        @"internet": @{
            @"wanted": @(gConfig.internet),
            @"state": internet[@"state"],
            @"error": internet[@"error"],
            @"interface": internet[@"interface"],
            @"host": kHostLinkMac,
            @"router": kHostLinkGuest,
        },
    } mutableCopy];
    // Apps from before version 2 read device 1-1 from the top level.
    [status addEntriesFromDictionary:first ?: @{@"usb": @"", @"device": @"idle", @"device_error": @"", @"client": @NO}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingSortedKeys error:nil];
    if (!data || [data isEqualToData:gLastStatus]) return;
    gLastStatus = data;
    [data writeToFile:kStatusPath atomically:YES];
    chmod(kStatusPath.fileSystemRepresentation, 0644);
}

// ------------------------------------------------------------------ main loop (gStateQueue)
static uint64_t gLastTick;

static void tick(void) {
    gTick++;
    // Both devices share this queue. A tick that comes late means it was busy (a device being
    // captured, configured or reset), and every device's requests waited too, answered or not:
    // for this one tick their age says nothing about the device, so no watchdog acts on it.
    uint64_t now = nowNs();
    BOOL late = gLastTick && (double)(now - gLastTick) / 1e9 > 2.5;
    gLastTick = now;
    if (!gConfig || gTick % 2 == 0) gConfig = readConfig();
    gActive = ownerAlive(gConfig.owner);
    for (Slot *s in gSlots) {
        DeviceConfig *want = nil;
        for (DeviceConfig *device in gConfig.devices) if ([device.busid isEqualToString:s.busid]) want = device;
        s.config = want;
        ensureDevice(s);
        if (s.clientFd >= 0 && (!gActive || !s.device || s.clientPeer != gConfig.guest)) {
            endClient(s, s.conn, @"the app no longer asks for it");
        }
        watchdog(s, late);
    }
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
            // or the host link (a wider route such as 10.0.0.0/8 is fine: the link's own is narrower)
            if (prefix >= kHostLinkPrefix && overlaps(net, prefix, kHostLinkNet, kHostLinkPrefix)) continue;
            [desired addObject:cidr];
        }
    }
    if (!gRoutesBusy) {
        gRoutesBusy = YES;
        dispatch_async(gRouteQueue, ^{
            NSArray<NSDictionary *> *result = applyRoutes(desired, guest, interface);
            if (interface) dropShadowingEntries(interface);
            dispatch_async(gStateQueue, ^{ gRouteResult = result; gRoutesBusy = NO; });
        });
    }
    // The phone's internet only while the VM has the phone attached.
    BOOL phoneAttached = NO;
    for (Slot *s in gSlots) if (s.config.tether && s.device && s.clientFd >= 0) phoneAttached = YES;
    NSString *internetBridge = (gConfig.internet && phoneAttached && guest) ? interface : nil;
    // TSO off while the phone is the internet, or while the VM has a dongle set to tso=off.
    BOOL noTSO = internetBridge != nil;
    for (Slot *s in gSlots) if (!s.config.tether && s.config.noTSO && s.device && s.clientFd >= 0 && guest) noTSO = YES;
    if (!gInternetBusy) {
        gInternetBusy = YES;
        dispatch_async(gRouteQueue, ^{
            if (noTSO) takeTSO(); else restoreTSO();        // before the service is published
            NSDictionary *result = applyInternet(internetBridge);
            dispatch_async(gStateQueue, ^{ gInternetResult = result; gInternetBusy = NO; });
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

static void serveURBs(Slot *s, int fd, uint32_t conn) {
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
            dispatch_async(gStateQueue, ^{ submit(s, conn, seq, direction, ep, flags, length, packets, setupBits, outData); });
        } else if (command == CMD_UNLINK) {
            uint32_t target = get32(h + 20);
            dispatch_async(gStateQueue, ^{ unlinkURB(s, conn, seq, target); });
        } else {
            logmsg(@"%@ unknown USB/IP command %u, closing", s.busid, command);
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
            NSMutableArray<Slot *> *ready = [NSMutableArray array];
            for (Slot *s in gSlots) if (s.device) [ready addObject:s];
            put16(reply, USBIP_VERSION); put16(reply, OP_REP_DEVLIST); put32(reply, 0); put32(reply, (uint32_t)ready.count);
            for (Slot *s in ready) putDeviceInfo(s, reply, YES);
        });
        writeFull(fd, reply.bytes, reply.length);
        return;
    }
    if (code != OP_REQ_IMPORT) return;
    char busid[33] = {0};
    if (!readFull(fd, busid, 32)) return;
    NSString *wanted = [[NSString alloc] initWithBytes:busid length:strnlen(busid, 32) encoding:NSUTF8StringEncoding];
    __block NSMutableData *reply = [NSMutableData data];
    __block uint32_t conn = 0;
    __block Slot *slot = nil;
    __block NSString *kind = nil;
    dispatch_sync(gStateQueue, ^{
        Slot *s = wanted ? slotForBusid(wanted) : nil;
        BOOL ready = s && s.device != nil && gActive && peer == gConfig.guest;
        put16(reply, USBIP_VERSION); put16(reply, OP_REP_IMPORT); put32(reply, ready ? 0 : 1);
        if (!ready) return;
        putDeviceInfo(s, reply, NO);
        if (s.clientFd >= 0) endClient(s, s.conn, @"the VM connected again");
        conn = ++gConnCounter;
        if (conn == 0) conn = ++gConnCounter;
        s.conn = conn;
        s.clientFd = fd;
        s.clientPeer = peer;
        s.clientSince = nowNs();
        s.imports++;
        memset(&s->window, 0, sizeof s->window);
        memset(&s->summary, 0, sizeof s->summary);
        s.windowStart = s.summaryStart = nowNs();
        slot = s;
        kind = kindName(s);              // the slot's state belongs to this queue
    });
    if (!writeFull(fd, reply.bytes, reply.length) || !slot) return;
    logmsg(@"%@ VM %@ attached the %@", slot.busid, formatIPv4(peer), kind);
    serveURBs(slot, fd, conn);
    dispatch_sync(gStateQueue, ^{ endClient(slot, conn, @"the VM went away"); });
    dispatch_sync(slot.sendQueue, ^{});    // writes queued for this socket go out before it closes
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
    for (Slot *s in gSlots) closeDevice(s, @"idle");
    dispatch_sync(gRouteQueue, ^{
        applyRoutes(@[], nil, nil);
        withdrawInternet();
        restoreTSO();
    });
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
        gRouteQueue = dispatch_queue_create("godseon.routes", serial);
        NSMutableArray<Slot *> *slots = [NSMutableArray array];
        for (uint32_t number = 1; number <= kSlots; number++) {
            Slot *s = [Slot new];
            s.busid = [NSString stringWithFormat:@"1-%u", number];
            s.number = number;
            s.state = @"idle";
            s.error = @"";
            s.speed = 3;
            s.interfaces = [NSMutableDictionary dictionary];
            s.pipes = [NSMutableDictionary dictionary];
            s.maxPacket = [NSMutableDictionary dictionary];
            s.clientFd = -1;
            s.urbs = [NSMutableDictionary dictionary];
            s.windowStart = s.summaryStart = nowNs();
            s.sendQueue = dispatch_queue_create([NSString stringWithFormat:@"godseon.send.%u", number].UTF8String, serial);
            s.pending = [NSMutableData dataWithCapacity:64 * 1024];
            s.pendingFd = -1;
            [slots addObject:s];
        }
        gSlots = slots;
        loadOwned();

        int listener = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in address = { .sin_len = sizeof address, .sin_family = AF_INET,
                                       .sin_port = htons(kPort), .sin_addr.s_addr = htonl(INADDR_ANY) };
        if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof address) < 0 || listen(listener, 8) < 0) {
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
