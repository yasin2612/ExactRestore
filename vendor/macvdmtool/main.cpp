/* SPDX-License-Identifier: Apache-2.0 */
/* Based on https://github.com/osy/ThunderboltPatcher */
/* Modified for Exact Restore: every HPM port is usable. Adds "list", "dfu <rid>", "dfu all" and "restart <rid>". */

#include "AppleHPMLib.h"
#include "ssops.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

#include <CoreFoundation/CFNumber.h>
#include <CoreFoundation/CFString.h>

struct failure : public std::runtime_error {
    failure(const char *x) : std::runtime_error(x)
    {
    }
};

struct IOObjectDeleter {
    io_object_t arg;

    IOObjectDeleter(io_object_t arg) : arg(arg)
    {
    }

    ~IOObjectDeleter()
    {
        if (arg)
            IOObjectRelease(arg);
    }
};

struct HPMPluginInstance {
    IOCFPlugInInterface **plugin = nullptr;
    AppleHPMLib **device;
    int32_t rid = 0;
    bool inDBMa = false;

    HPMPluginInstance(io_service_t service)
    {
        SInt32 score;
        IOReturn ret = IOCreatePlugInInterfaceForService(service, kAppleHPMLibType,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
        if (ret != kIOReturnSuccess)
            throw failure("IOCreatePlugInInterfaceForService failed");

        HRESULT res = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kAppleHPMLibInterface),
                                                (LPVOID *)&device);
        if (res != S_OK)
            throw failure("QueryInterface failed");
    }

    ~HPMPluginInstance()
    {
        if (plugin) {
            // Only touch ports this run actually switched, so idle ports are left alone.
            if (inDBMa) {
                printf("RID %d: exiting DBMa mode... ", rid);
                if (this->command(0, 'DBMa', "\x00") == 0)
                    printf("OK\n");
                else
                    printf("Failed\n");
            }
            IODestroyPlugInInterface(plugin);
        }
    }

    std::string readRegister(uint64_t chipAddr, uint8_t dataAddr, int flags = 0)
    {
        std::string ret;
        ret.resize(64);
        uint64_t rlen = 0;
        IOReturn x = (*device)->Read(device, chipAddr, dataAddr, &ret[0], 64, flags, &rlen);
        if (x != 0)
            throw failure("readRegister failed");
        return ret;
    }

    void writeRegister(uint64_t chipAddr, uint8_t dataAddr, std::string value)
    {
        IOReturn x = (*device)->Write(device, chipAddr, dataAddr, &value[0], value.length(), 0);
        if (x != 0)
            throw failure("writeRegister failed");
    }

    int command(uint64_t chipAddr, uint32_t cmd, std::string args = "")
    {
        if (args.length())
            (*device)->Write(device, chipAddr, 9, args.data(), args.length(), 0);
        auto ret = (*device)->Command(device, chipAddr, cmd, 0);
        if (ret)
            return -1;
        auto res = this->readRegister(chipAddr, 9);
        return res[0] & 0xfu;
    }
};

struct Port {
    int32_t rid;
    std::string path;
    std::unique_ptr<HPMPluginInstance> inst;
};

uint32_t GetUnlockKey()
{
    CFMutableDictionaryRef matching = IOServiceMatching("IOPlatformExpertDevice");
    if (!matching)
        throw failure("IOServiceMatching failed (IOPED)");

    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    if (!service)
        throw failure("IOServiceGetMatchingService failed (IOPED)");

    IOObjectDeleter deviceDel(service);

    io_name_t deviceName;
    if (IORegistryEntryGetName(service, deviceName) != kIOReturnSuccess) {
        throw failure("IORegistryEntryGetName failed (IOPED)");
    }

    printf("Mac type: %s\n", deviceName);

    return (deviceName[0] << 24) | (deviceName[1] << 16) | (deviceName[2] << 8) | deviceName[3];
}

std::vector<Port> FindPorts()
{
    printf("Looking for HPM devices...\n");

    CFMutableDictionaryRef matching = IOServiceMatching("AppleHPM");
    if (!matching)
        throw failure("IOServiceMatching failed");

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iter) != kIOReturnSuccess)
        throw failure("IOServiceGetMatchingServices failed");
    IOObjectDeleter iterDel(iter);

    std::vector<Port> ports;
    io_service_t device;
    while ((device = IOIteratorNext(iter))) {
        IOObjectDeleter deviceDel(device);
        io_string_t pathName;

        if (IORegistryEntryGetPath(device, kIOServicePlane, pathName) != kIOReturnSuccess)
            continue;

        CFNumberRef data = (CFNumberRef)IORegistryEntryCreateCFProperty(device, CFSTR("RID"),
                                                                        kCFAllocatorDefault, 0);
        if (!data)
            continue;

        int32_t rid;
        CFNumberGetValue(data, kCFNumberSInt32Type, &rid);
        CFRelease(data);

        try {
            auto inst = std::make_unique<HPMPluginInstance>(device);
            inst->rid = rid;
            ports.push_back(Port{rid, pathName, std::move(inst)});
        } catch (failure &e) {
            fprintf(stderr, "RID %d: %s\n", rid, e.what());
        }
    }

    std::sort(ports.begin(), ports.end(),
              [](const Port &a, const Port &b) { return a.rid < b.rid; });

    if (ports.empty())
        throw failure("No matching devices");

    return ports;
}

std::string ConnectionType(HPMPluginInstance &inst)
{
    auto t = inst.readRegister(0, 0x3f);
    if (!(t[0] & 1))
        return "None";
    return (t[0] & 2) == 0 ? "Source" : "Sink";
}

std::string Status(HPMPluginInstance &inst)
{
    auto res = inst.readRegister(0, 0x03);
    auto end = res.find('\0');
    if (end != std::string::npos)
        res.erase(end);
    return res;
}

void UnlockAce(HPMPluginInstance &inst, int no, uint32_t key)
{
    printf("Unlocking... ");
    std::stringstream args;
    put(args, key);
    if (inst.command(no, 'LOCK', args.str())) {
        printf(" Failed.\n");
        printf("Trying to reset... ");
        if (inst.command(no, 'Gaid')) {
            printf("Failed.\n");
            throw failure("Failed to unlock device");
        }
        printf("OK.\nUnlocking... ");
        if (inst.command(no, 'LOCK', args.str())) {
            printf(" Failed.\n");
            throw failure("Failed to unlock device");
        }
    }

    printf("OK\n");
}

void EnterDBMa(HPMPluginInstance &inst, uint32_t key)
{
    auto status = Status(inst);
    printf("Status: %s\n", status.c_str());

    if (status == "DBMa") {
        inst.inDBMa = true;
        return;
    }

    UnlockAce(inst, 0, key);
    printf("Entering DBMa mode... ");

    if (inst.command(0, 'DBMa', "\x01"))
        throw failure("Failed to enter DBMa mode");
    inst.inDBMa = true;

    status = Status(inst);
    printf("Status: %s\n", status.c_str());
    if (status != "DBMa")
        throw failure("Failed to enter DBMa mode");
}

void DoVDM(HPMPluginInstance &inst, int no, std::vector<uint32_t> vdm)
{
    auto rs = inst.readRegister(no, 0x4d);
    uint8_t rxst = rs[0];

    std::stringstream args;
    put(args, (uint8_t)(((3 << 4) | vdm.size())));
    for (uint32_t i : vdm)
        put(args, i);

    if (inst.command(no, 'VDMs', args.str()))
        throw failure("Failed to send VDM");

    int i;
    for (i = 0; i < 16; i++) {
        rs = inst.readRegister(no, 0x4d);
        if ((uint8_t)rs[0] != rxst)
            break;
    }
    if (i >= 16)
        throw failure("Did not get a reply to VDM");

    uint32_t vdmhdr;
    std::stringstream reply;
    reply.str(rs);
    get(reply, rxst);
    get(reply, vdmhdr);

    if (vdmhdr != (vdm[0] | 0x40)) {
        printf("VDM failed (reply: 0x%08x)\n", vdmhdr);
        throw failure("VDM failed");
    }
}

int DoSerial(HPMPluginInstance &inst, int no)
{
    printf("Putting target into serial mode... ");

    std::vector<uint32_t> serial{0x5ac8012, 0x1840306};
    DoVDM(inst, no, serial);

    printf("OK\n");

    printf("Putting local end into serial mode... ");

    std::stringstream args;
    put(args, (uint32_t)0x1840306);

    if (inst.command(no, 'DVEn', args.str())) {
        printf("Failed.\n");
        return 1;
    }
    printf("OK\n");

    return 0;
}

int DoDebugUSB(HPMPluginInstance &inst, int no)
{
    printf("Switching target into debug USB mode... ");

    std::vector<uint32_t> dfu{0x5ac8012, 0x1824606};
    DoVDM(inst, no, dfu);

    printf("OK\n");
    return 0;
}

int DoReboot(HPMPluginInstance &inst, int no)
{
    printf("Rebooting target into normal mode... ");

    std::vector<uint32_t> reboot{0x5ac8012, 0x105, 0x80000000};
    DoVDM(inst, no, reboot);

    printf("OK\n");
    return 0;
}

int WaitConnected(HPMPluginInstance &inst, int no)
{
    printf("Waiting for connection...");
    fflush(stdout);

    sleep(1);
    int i;
    for (i = 0; i < 30; i++) {
        printf(".");
        fflush(stdout);
        auto t = inst.readRegister(no, 0x3f);
        if (t[0] & 1)
            break;
        usleep(100000);
    }
    if (i >= 30) {
        printf(" Timed out\n");
        return 1;
    }
    printf(" Connected\n");
    sleep(1);

    return 0;
}

int DoDFU(HPMPluginInstance &inst, int no)
{
    printf("Rebooting target into DFU mode... ");

    std::vector<uint32_t> dfu{0x5ac8012, 0x106, 0x80010000};
    DoVDM(inst, no, dfu);

    printf("OK\n");
    return 0;
}

Port &PortByRid(std::vector<Port> &ports, int32_t rid)
{
    for (auto &port : ports)
        if (port.rid == rid)
            return port;
    throw failure("No port with that RID. Run 'list' to see ports.");
}

/// Machine readable lines start with RESULT so the app can parse them.
int DfuAll(std::vector<Port> &ports, uint32_t key)
{
    int ok = 0;
    int tried = 0;

    for (auto &port : ports) {
        std::string type;
        try {
            type = ConnectionType(*port.inst);
        } catch (failure &) {
            printf("RESULT rid=%d status=skipped connection=Unreadable\n", port.rid);
            continue;
        }

        if (type == "None") {
            printf("RESULT rid=%d status=skipped connection=None\n", port.rid);
            continue;
        }

        tried++;
        printf("RID %d: connection %s\n", port.rid, type.c_str());
        try {
            EnterDBMa(*port.inst, key);
            DoDFU(*port.inst, 0);
            ok++;
            printf("RESULT rid=%d status=ok\n", port.rid);
        } catch (failure &e) {
            printf("RESULT rid=%d status=failed reason=%s\n", port.rid, e.what());
        }
        fflush(stdout);
    }

    if (tried == 0)
        throw failure("No connection detected");

    return ok > 0 ? 0 : 1;
}

int main2(int argc, char **argv)
{
    if (argc < 2) {
        printf("Usage: %s <command>\n", argv[0]);
        printf("Commands:\n");
        printf("  list - list host ports and their connection state\n");
        printf("  serial - enter serial mode on both ends\n");
        printf("  debugusb - enter debugusb mode on the target\n");
        printf("  reboot - reboot the target\n");
        printf("  reboot serial - reboot the target and enter serial mode\n");
        printf("  reboot debugusb - reboot the target and enter debugusb mode\n");
        printf("  dfu - put the target on RID 0 into DFU mode\n");
        printf("  dfu <rid> - put the target on that port into DFU mode\n");
        printf("  dfu all - put every connected target into DFU mode\n");
        printf("  restart <rid> - force restart the target on that port into normal mode\n");
        printf("  nop - do nothing\n");
        return 1;
    }

    std::string cmd = argv[1];
    std::string arg = argc >= 3 ? argv[2] : "";

    uint32_t key = GetUnlockKey();
    auto ports = FindPorts();

    if (cmd == "list") {
        for (auto &port : ports) {
            std::string type = "Unreadable";
            try {
                type = ConnectionType(*port.inst);
            } catch (failure &) {
            }
            printf("PORT rid=%d connection=%s path=%s\n", port.rid, type.c_str(), port.path.c_str());
        }
        return 0;
    }

    if (cmd == "dfu" && arg == "all")
        return DfuAll(ports, key);

    int32_t rid = 0;
    if ((cmd == "dfu" || cmd == "restart") && !arg.empty()) {
        char *end = nullptr;
        long value = strtol(arg.c_str(), &end, 10);
        if (!end || *end != '\0')
            throw failure("RID must be a number or 'all'");
        rid = (int32_t)value;
    }

    Port &port = PortByRid(ports, rid);
    auto &inst = *port.inst;
    printf("Found: %s\n", port.path.c_str());

    auto type = ConnectionType(inst);
    printf("Connection: %s\n", type.c_str());
    if (type == "None")
        throw failure("No connection detected");

    EnterDBMa(inst, key);

    int no = 0;
    if (cmd == "restart")
        return DoReboot(inst, no);
    if (cmd == "serial")
        return DoSerial(inst, no);
    else if (cmd == "debugusb")
        return DoDebugUSB(inst, no);
    else if (cmd == "reboot") {
        bool do_serial = arg == "serial";
        bool do_debugusb = arg == "debugusb";
        if (DoReboot(inst, no))
            return 1;
        if (do_serial || do_debugusb) {
            if (WaitConnected(inst, no))
                return 1;
            if (do_serial)
                return DoSerial(inst, no);
            return DoDebugUSB(inst, no);
        }
        return 0;
    } else if (cmd == "dfu")
        return DoDFU(inst, no);
    else if (cmd == "nop")
        return 0;

    printf("Unknown command\n");
    return 1;
}

int main(int argc, char **argv)
{
    // Returning normally makes sure the HPMPluginInstance destructors run.
    try {
        return main2(argc, argv);
    } catch (failure &e) {
        printf("ERROR: %s\n", e.what());
        return -1;
    } catch (std::exception &e) {
        printf("ERROR: %s\n", e.what());
        return -1;
    }
}
