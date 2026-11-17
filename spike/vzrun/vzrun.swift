// SPDX-License-Identifier: MIT
//
// vzrun (spike): boot the GodseonDongle guest with Virtualization.framework - no UTM,
// no USB passthrough (the dongle arrives over USB/IP from spike/usbipd).
//   vzrun <Image> <initramfs> <console-log> <console-fifo> [kernel args...]
// Write shell commands into <console-fifo> to type them on the guest console (hvc0);
// SIGINT/SIGTERM stops the VM.

import Foundation
import Virtualization

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    FileHandle.standardError.write("usage: vzrun <Image> <initramfs> <console-log> <console-fifo> [kernel args...]\n".data(using: .utf8)!)
    exit(2)
}

let logURL = URL(fileURLWithPath: arguments[3])
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try FileHandle(forWritingTo: logURL)

// Opened read-write so the console never sees EOF when a writer goes away.
let fifoPath = arguments[4]
unlink(fifoPath)
guard mkfifo(fifoPath, 0o600) == 0 else { fatalError("mkfifo \(fifoPath) failed") }
let consoleInput = FileHandle(fileDescriptor: open(fifoPath, O_RDWR), closeOnDealloc: true)

let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: arguments[1]))
bootLoader.initialRamdiskURL = URL(fileURLWithPath: arguments[2])
bootLoader.commandLine = (["console=hvc0", "rdinit=/sbin/init", "modules=virtio_pci,virtio_mmio,virtio_console"]
    + arguments.dropFirst(5)).joined(separator: " ")

let console = VZVirtioConsoleDeviceSerialPortConfiguration()
console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: consoleInput, fileHandleForWriting: logHandle)

let network = VZVirtioNetworkDeviceConfiguration()
network.attachment = VZNATNetworkDeviceAttachment()
network.macAddress = VZMACAddress(string: "02:00:5E:10:00:66")!

let configuration = VZVirtualMachineConfiguration()
configuration.platform = VZGenericPlatformConfiguration()
configuration.cpuCount = 1
configuration.memorySize = 256 * 1024 * 1024
configuration.bootLoader = bootLoader
configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
configuration.serialPorts = [console]
configuration.networkDevices = [network]
try configuration.validate()

let machine = VZVirtualMachine(configuration: configuration)
machine.start { result in
    if case .failure(let error) = result {
        FileHandle.standardError.write("start failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    print("VM started (mac 02:00:5e:10:00:66); console -> \(logURL.path)")
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        machine.stop { _ in unlink(fifoPath); exit(0) }
    }
    source.resume()
    signalSources.append(source)
}
dispatchMain()
