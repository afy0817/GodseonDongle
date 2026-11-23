// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT
//
// usbipd: export one host USB device to a Linux guest over USB/IP, using Apple's
// IOUSBHost framework instead of a VM-level USB passthrough entitlement.
//
//   build: clang -fobjc-arc -O2 -Wall usbipd.m -o usbipd \
//              -framework Foundation -framework IOKit -framework IOUSBHost
//   run:   ./usbipd <vid> <pid> [port]        e.g. ./usbipd 0x0bda 0xb812 9408
//   env:   GODSEON_USBIP_STATS=<seconds>      traffic summary interval (default 30, 0 = off)
//
// Without root it opens the device normally (fine when no macOS driver or other
// app holds it). As root it captures the device, which IOUSBHost allows without
// the com.apple.vm.device-access entitlement.
// Guest side: modprobe vhci_hcd; usbip --tcp-port 9408 attach -r <mac> -b 1-1
// Only peers on loopback or a vmnet subnet (192.168.64.0/18) may connect.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOMessage.h>
#import <IOUSBHost/IOUSBHost.h>
#include <arpa/inet.h>
#include <errno.h>
#include <libkern/OSByteOrder.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum {
    OP_REQ_DEVLIST = 0x8005, OP_REP_DEVLIST = 0x0005,
    OP_REQ_IMPORT = 0x8003, OP_REP_IMPORT = 0x0003,
    USBIP_VERSION = 0x0111,
    CMD_SUBMIT = 1, CMD_UNLINK = 2, RET_SUBMIT = 3, RET_UNLINK = 4,
    URB_ZERO_PACKET = 0x0040,
};

static uint16_t gVid, gPid;
static io_service_t gService;
static IOUSBHostDevice *gDevice;
static uint32_t gSpeed = 3;                       // usbip/Linux USB_SPEED_HIGH
static const char *gBusid = "1-1";

/// One URB the guest submitted and has not been answered yet.
@interface PendingURB : NSObject
@property (nonatomic) uint32_t conn;
@property (nonatomic) uint8_t address;            // endpoint address; 0 for control
@property (nonatomic) BOOL unlinked;
@property (nonatomic) uint64_t started;           // CLOCK_UPTIME_RAW ns
@end
@implementation PendingURB
@end

// All mutable state below is touched only on gStateQueue. IOUSBHost delivers its
// completions on gIOQueue, so synchronous IOUSBHost calls made on gStateQueue
// can never wait on themselves.
static dispatch_queue_t gStateQueue, gIOQueue, gSendQueue;
static NSMutableDictionary<NSNumber *, IOUSBHostInterface *> *gInterfaces;   // interface number
static NSMutableDictionary<NSNumber *, IOUSBHostPipe *> *gPipes;             // endpoint address
static NSMutableDictionary<NSNumber *, NSNumber *> *gMaxPacket;              // endpoint address
static NSMutableDictionary<NSNumber *, PendingURB *> *gURBs;                // seqnum
static int gClientFd = -1;
static uint32_t gConn;                                                      // bumped per connection
static dispatch_source_t gStatsTimer;     // must stay referenced, or ARC frees it and it never fires

static struct Stats {
    unsigned long submitted, completed, control, bulkIn, bulkOut, unlinks, aborts, errors;
    unsigned long long bytesIn, bytesOut;
    double maxOutMs, maxInMs;
} gPeriod, gTotal;

static uint64_t nowNs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void logmsg(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logmsg(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    fprintf(stderr, "%05ld.%03ld usbipd: %s\n", (long)(ts.tv_sec % 100000), ts.tv_nsec / 1000000, s.UTF8String);
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

// Called on gStateQueue: queue bytes for the current connection only.
static void sendToClient(uint32_t conn, NSData *data) {
    if (conn != gConn || gClientFd < 0) return;
    int fd = gClientFd;
    dispatch_async(gSendQueue, ^{
        if (!writeFull(fd, data.bytes, data.length)) logmsg(@"write failed: %s", strerror(errno));
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
    snprintf(path, sizeof path, "/sys/devices/platform/godseon-usbip/usb1/%s", gBusid);
    snprintf(busid, sizeof busid, "%s", gBusid);
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
    BOOL ok = value == 0 || openInterfaces();
    logmsg(@"configuration %lu: %lu interface(s), %lu endpoint pipe(s)",
           (unsigned long)value, (unsigned long)gInterfaces.count, (unsigned long)gPipes.count);
    return ok;
}

// ------------------------------------------------------------------ URBs
static PendingURB *track(uint32_t conn, uint32_t seq, uint8_t address) {
    PendingURB *urb = [PendingURB new];
    urb.conn = conn;
    urb.address = address;
    urb.started = nowNs();
    gURBs[@(seq)] = urb;
    return urb;
}

static void finish(uint32_t conn, uint32_t seq, IOReturn status, NSUInteger bytes, uint32_t packets,
                   NSData *inData, BOOL in) {
    PendingURB *urb = gURBs[@(seq)];
    if (!urb || urb.conn != conn) return;        // from an earlier connection
    [gURBs removeObjectForKey:@(seq)];
    gPeriod.completed++;
    if (urb.address != 0) {
        double ms = (double)(nowNs() - urb.started) / 1e6;
        if (in) gPeriod.maxInMs = MAX(gPeriod.maxInMs, ms); else gPeriod.maxOutMs = MAX(gPeriod.maxOutMs, ms);
    }
    if (urb.unlinked) return;                     // the guest already got RET_UNLINK
    int32_t st = mapStatus(status);
    if (st != 0) gPeriod.errors++;
    if (in) gPeriod.bytesIn += bytes; else gPeriod.bytesOut += bytes;
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
    gPeriod.control++;
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
        IOUSBHostPipe *pipe = gPipes[@(request.wIndex & 0xff)];
        if (pipe) [pipe clearStallWithError:nil];
        sendRetSubmit(conn, seq, 0, 0, packets, nil);
        return;
    }
    if (request.bmRequestType == 0x23 && request.bRequest == 3 && request.wValue == 4) {   // SET_FEATURE(PORT_RESET)
        NSUInteger value = gDevice.configurationDescriptor ? gDevice.configurationDescriptor->bConfigurationValue : 0;
        closeInterfaces();
        NSError *error = nil;
        if (![gDevice resetWithError:&error]) logmsg(@"device reset failed: %@", error.localizedDescription);
        if (value) configure(value);
        logmsg(@"device reset requested by the guest");
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
        logmsg(@"control %02x/%02x failed to queue: %@", request.bmRequestType, request.bRequest, error.localizedDescription);
        sendRetSubmit(conn, seq, -EPIPE, 0, packets, nil);
    }
}

static void submit(uint32_t conn, uint32_t seq, uint32_t direction, uint32_t ep, uint32_t flags,
                   int32_t length, uint32_t packets, uint64_t setupBits, NSMutableData *outData) {
    gPeriod.submitted++;
    BOOL in = direction == 1;
    if (ep == 0) { control(conn, seq, in, setupBits, outData, packets); return; }
    if (packets != 0 && packets != 0xffffffff) { sendRetSubmit(conn, seq, -EPROTO, 0, packets, nil); return; }  // no isochronous
    uint8_t address = (uint8_t)(ep | (in ? 0x80 : 0));
    IOUSBHostPipe *pipe = gPipes[@(address)];
    if (!pipe) { sendRetSubmit(conn, seq, -EPIPE, 0, packets, nil); return; }
    if (in) gPeriod.bulkIn++; else gPeriod.bulkOut++;
    // a plain buffer: IOUSBHost's ioDataWithCapacity: buffers refuse length changes
    NSMutableData *buffer = in ? [[NSMutableData alloc] initWithLength:(NSUInteger)MAX(length, 0)]
                               : (outData ?: [[NSMutableData alloc] init]);
    NSUInteger maxPacket = gMaxPacket[@(address)].unsignedIntegerValue;
    BOOL zeroPacket = !in && (flags & URB_ZERO_PACKET) && length > 0 && maxPacket && (length % maxPacket) == 0;
    track(conn, seq, address);
    NSError *error = nil;
    BOOL queued = [pipe enqueueIORequestWithData:buffer completionTimeout:0 error:&error
        completionHandler:^(IOReturn status, NSUInteger bytes) {
            if (zeroPacket && status == kIOReturnSuccess) {
                [pipe enqueueIORequestWithData:[NSMutableData data] completionTimeout:0 error:nil
                    completionHandler:^(IOReturn zlpStatus, NSUInteger zlpBytes) {
                        dispatch_async(gStateQueue, ^{ finish(conn, seq, status, bytes, packets, buffer, in); });
                    }];
                return;
            }
            dispatch_async(gStateQueue, ^{ finish(conn, seq, status, bytes, packets, buffer, in); });
        }];
    if (!queued) {
        [gURBs removeObjectForKey:@(seq)];
        logmsg(@"ep 0x%02x: failed to queue %d bytes: %@", address, length, error.localizedDescription);
        sendRetSubmit(conn, seq, -EPIPE, 0, packets, nil);
    }
}

// IOUSBHost can only cancel every request on an endpoint at once, so an endpoint is
// aborted when the last request still queued on it gets unlinked (what a driver does
// when it stops: it kills all its URBs). Unlinked requests are never answered again.
static void unlinkURB(uint32_t conn, uint32_t seq, uint32_t target) {
    PendingURB *urb = gURBs[@(target)];
    BOOL pending = urb && urb.conn == conn && !urb.unlinked;
    if (pending) {
        urb.unlinked = YES;
        gPeriod.unlinks++;
        BOOL othersLive = NO;
        for (PendingURB *other in gURBs.allValues) {
            if (other != urb && other.conn == conn && other.address == urb.address && !other.unlinked) { othersLive = YES; break; }
        }
        if (!othersLive) {
            gPeriod.aborts++;
            if (urb.address == 0) [gDevice abortDeviceRequestsWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
            else [gPipes[@(urb.address)] abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        }
    }
    sendRetUnlink(conn, seq, pending ? -ECONNRESET : 0);
}

static void addStats(struct Stats *into, const struct Stats *from) {
    into->submitted += from->submitted; into->completed += from->completed; into->control += from->control;
    into->bulkIn += from->bulkIn; into->bulkOut += from->bulkOut; into->unlinks += from->unlinks;
    into->aborts += from->aborts; into->errors += from->errors;
    into->bytesIn += from->bytesIn; into->bytesOut += from->bytesOut;
    into->maxOutMs = MAX(into->maxOutMs, from->maxOutMs); into->maxInMs = MAX(into->maxInMs, from->maxInMs);
}

// Called on gStateQueue. "oldest out" is the age of the oldest unanswered bulk OUT
// request: it keeps growing when the dongle stops transmitting.
static void logStats(double seconds) {
    if (gClientFd < 0 || gPeriod.submitted == 0) return;
    unsigned long pendingIn = 0, pendingOut = 0, pendingControl = 0, pendingUnlinked = 0;
    double oldestOut = 0;
    uint64_t now = nowNs();
    for (PendingURB *urb in gURBs.allValues) {
        if (urb.unlinked) pendingUnlinked++;
        else if (urb.address == 0) pendingControl++;
        else if (urb.address & 0x80) pendingIn++;
        else { pendingOut++; oldestOut = MAX(oldestOut, (double)(now - urb.started) / 1e6); }
    }
    logmsg(@"%.0fs: %lu urbs (ctl %lu, in %lu, out %lu, avg out %.0f B), in %.2f Mbit/s, out %.2f Mbit/s, "
           "max in %.0f ms, max out %.0f ms, errors %lu, unlinks %lu, aborts %lu | "
           "waiting: in %lu, out %lu (oldest %.0f ms), ctl %lu, unlinked %lu",
           seconds, gPeriod.submitted, gPeriod.control, gPeriod.bulkIn, gPeriod.bulkOut,
           gPeriod.bulkOut ? (double)gPeriod.bytesOut / gPeriod.bulkOut : 0,
           gPeriod.bytesIn * 8.0 / seconds / 1e6, gPeriod.bytesOut * 8.0 / seconds / 1e6,
           gPeriod.maxInMs, gPeriod.maxOutMs, gPeriod.errors, gPeriod.unlinks, gPeriod.aborts,
           pendingIn, pendingOut, oldestOut, pendingControl, pendingUnlinked);
    addStats(&gTotal, &gPeriod);
    memset(&gPeriod, 0, sizeof gPeriod);
}

// ------------------------------------------------------------------ network
static BOOL peerAllowed(const struct sockaddr_in *peer) {
    uint32_t a = ntohl(peer->sin_addr.s_addr);
    return (a >> 24) == 127 || (a & 0xffffc000) == 0xc0a84000;    // 127/8, 192.168.64.0/18
}

static void serveURBs(int fd, uint32_t conn) {
    uint8_t h[48];
    BOOL open = YES;
    while (open && readFull(fd, h, sizeof h)) @autoreleasepool {     // one pool per URB: no build-up
        uint32_t command = get32(h), seq = get32(h + 4), direction = get32(h + 12), ep = get32(h + 16);
        if (command == CMD_SUBMIT) {
            uint32_t flags = get32(h + 20), packets = get32(h + 32);
            int32_t length = (int32_t)get32(h + 24);
            uint64_t setupBits;
            memcpy(&setupBits, h + 40, 8);
            NSMutableData *outData = nil;
            if (direction == 0 && length > 0) {
                outData = [[NSMutableData alloc] initWithLength:(NSUInteger)length];
                if (!readFull(fd, outData.mutableBytes, (size_t)length)) { open = NO; continue; }
            }
            if (packets != 0 && packets != 0xffffffff) {          // skip isochronous descriptors
                NSMutableData *iso = [[NSMutableData alloc] initWithLength:(NSUInteger)packets * 16];
                if (!readFull(fd, iso.mutableBytes, iso.length)) { open = NO; continue; }
            }
            dispatch_async(gStateQueue, ^{ submit(conn, seq, direction, ep, flags, length, packets, setupBits, outData); });
        } else if (command == CMD_UNLINK) {
            uint32_t target = get32(h + 20);
            dispatch_async(gStateQueue, ^{ unlinkURB(conn, seq, target); });
        } else {
            logmsg(@"unknown command %u, closing", command);
            open = NO;
        }
    }
}

static void serveClient(int fd) {
    uint8_t op[8];
    if (!readFull(fd, op, sizeof op)) return;
    uint16_t code = get16(op + 2);
    if (code == OP_REQ_DEVLIST) {
        __block NSMutableData *reply = [NSMutableData data];
        dispatch_sync(gStateQueue, ^{
            put16(reply, USBIP_VERSION); put16(reply, OP_REP_DEVLIST); put32(reply, 0); put32(reply, 1);
            putDeviceInfo(reply, YES);
        });
        writeFull(fd, reply.bytes, reply.length);
        return;
    }
    if (code != OP_REQ_IMPORT) { logmsg(@"unexpected op 0x%04x", code); return; }
    char busid[32];
    if (!readFull(fd, busid, sizeof busid)) return;
    __block NSMutableData *reply = [NSMutableData data];
    __block uint32_t conn = 0;
    dispatch_sync(gStateQueue, ^{
        put16(reply, USBIP_VERSION); put16(reply, OP_REP_IMPORT); put32(reply, 0);
        putDeviceInfo(reply, NO);
        conn = ++gConn;
        gClientFd = fd;
        memset(&gPeriod, 0, sizeof gPeriod);
        memset(&gTotal, 0, sizeof gTotal);
    });
    if (!writeFull(fd, reply.bytes, reply.length)) return;
    logmsg(@"guest imported %.32s", busid);
    serveURBs(fd, conn);
    dispatch_sync(gStateQueue, ^{
        addStats(&gTotal, &gPeriod);
        logmsg(@"guest detached: %lu urbs, %.1f MB in, %.1f MB out, %lu errors, %lu unlinks, %lu aborts, max out %.0f ms",
               gTotal.submitted, gTotal.bytesIn / 1e6, gTotal.bytesOut / 1e6, gTotal.errors, gTotal.unlinks,
               gTotal.aborts, gTotal.maxOutMs);
        gConn++;
        gClientFd = -1;
        for (IOUSBHostPipe *pipe in gPipes.allValues) [pipe abortWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        [gDevice abortDeviceRequestsWithOption:IOUSBHostAbortOptionAsynchronous error:nil];
        [gURBs removeAllObjects];
    });
    dispatch_sync(gSendQueue, ^{});    // flush writes queued for this socket before it closes
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: %s <vid> <pid> [port]\n", argv[0]);
            return 2;
        }
        signal(SIGPIPE, SIG_IGN);
        setvbuf(stderr, NULL, _IOLBF, 0);
        gVid = (uint16_t)strtoul(argv[1], NULL, 0);
        gPid = (uint16_t)strtoul(argv[2], NULL, 0);
        int port = argc > 3 ? atoi(argv[3]) : 9408;
        const char *statsEnv = getenv("GODSEON_USBIP_STATS");
        double statsSeconds = statsEnv ? atof(statsEnv) : 30;
        // Drain autoreleased objects after every block: millions of URBs pass through these.
        dispatch_queue_attr_t serial = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        gStateQueue = dispatch_queue_create("usbipd.state", serial);
        gIOQueue = dispatch_queue_create("usbipd.io", serial);
        gSendQueue = dispatch_queue_create("usbipd.send", serial);
        gInterfaces = [NSMutableDictionary dictionary];
        gPipes = [NSMutableDictionary dictionary];
        gMaxPacket = [NSMutableDictionary dictionary];
        gURBs = [NSMutableDictionary dictionary];

        CFMutableDictionaryRef match = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(gVid) productID:@(gPid)
            bcdDevice:nil deviceClass:nil deviceSubclass:nil deviceProtocol:nil speed:nil productIDArray:nil];
        gService = IOServiceGetMatchingService(kIOMainPortDefault, match);
        if (!gService) { logmsg(@"device %04x:%04x not found", gVid, gPid); return 1; }

        BOOL root = geteuid() == 0;
        NSError *error = nil;
        gDevice = [[IOUSBHostDevice alloc] initWithIOService:gService
            options:root ? IOUSBHostObjectInitOptionsDeviceCapture : IOUSBHostObjectInitOptionsNone
            queue:gIOQueue error:&error
            interestHandler:^(IOUSBHostObject *object, uint32_t type, void *argument) {
                if (type == kIOMessageServiceIsTerminated) { logmsg(@"device went away"); exit(3); }
            }];
        if (!gDevice) {
            logmsg(@"cannot open %04x:%04x%s: %@", gVid, gPid, root ? " (capture)" : "", error.localizedDescription);
            if (!root) logmsg(@"another driver or app may hold it; run as root to capture it");
            return 1;
        }
        CFTypeRef speed = IORegistryEntryCreateCFProperty(gService, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
        if (speed) {
            int legacy = [(__bridge NSNumber *)speed intValue];      // 0 low, 1 full, 2 high, 3 super, 4 super+
            const uint32_t map[] = {1, 2, 3, 5, 6};
            if (legacy >= 0 && legacy <= 4) gSpeed = map[legacy];
            CFRelease(speed);
        }
        dispatch_sync(gStateQueue, ^{
            const IOUSBConfigurationDescriptor *cd = gDevice.configurationDescriptor;
            if (cd) openInterfaces();
            logmsg(@"opened %04x:%04x%s, speed %u, configuration %u, %lu interface(s), %lu pipe(s)", gVid, gPid,
                   root ? " (captured)" : "", gSpeed, cd ? cd->bConfigurationValue : 0,
                   (unsigned long)gInterfaces.count, (unsigned long)gPipes.count);
        });
        if (statsSeconds > 0) {
            gStatsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gStateQueue);
            uint64_t interval = (uint64_t)(statsSeconds * NSEC_PER_SEC);
            dispatch_source_set_timer(gStatsTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, NSEC_PER_SEC / 10);
            dispatch_source_set_event_handler(gStatsTimer, ^{ logStats(statsSeconds); });
            dispatch_resume(gStatsTimer);
        }

        int listener = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in addr = { .sin_len = sizeof addr, .sin_family = AF_INET,
                                    .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_ANY) };
        if (bind(listener, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(listener, 4) < 0) {
            logmsg(@"cannot listen on port %d: %s", port, strerror(errno));
            return 1;
        }
        logmsg(@"listening on port %d (busid %s)", port, gBusid);
        for (;;) {
            struct sockaddr_in peer;
            socklen_t peerLength = sizeof peer;
            int fd = accept(listener, (struct sockaddr *)&peer, &peerLength);
            if (fd < 0) { if (errno == EINTR) continue; logmsg(@"accept: %s", strerror(errno)); continue; }
            char peerText[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &peer.sin_addr, peerText, sizeof peerText);
            if (!peerAllowed(&peer)) { logmsg(@"refused %s", peerText); close(fd); continue; }
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            logmsg(@"connection from %s", peerText);
            @autoreleasepool { serveClient(fd); }
            close(fd);
        }
    }
}
