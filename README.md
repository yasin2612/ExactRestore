# Exact Restore

Erase or reinstall macOS on connected Macs from a host Mac.

## Requirements

* Host: any Mac on macOS 14 or later. Remote DFU needs an Apple Silicon host; on Intel hosts, put targets into DFU manually
* Targets: Apple Silicon and T2 Intel Macs (older Intel Macs are not supported)
* Targets cabled by their **DFU port**, directly to any USB C port on the host (not through a hub)
* **USB C data or Thunderbolt cables**. Charge only cables pass the DFU command, but the Mac never shows up
* Targets signed out of Find My (Activation Lock survives an erase)

## Build once

On one Apple Silicon Mac with Xcode installed:

```sh
./scripts/build-app.sh
```

This produces `build/Exact Restore.zip` with macvdmtool bundled inside.

## Set up each host

1. Copy `Exact Restore.zip` to the host, unzip, and move the app to Applications.
2. First launch: macOS blocks unsigned apps. Open **System Settings > Privacy & Security** and click **Open Anyway**.
3. Install **Apple Configurator** from the Mac App Store, open it, and choose **Apple Configurator > Install Automation Tools**.
4. Apple Silicon hosts only: in Exact Restore, click **Set up this Mac** and enter your password once. After installing a rebuilt app, click it again to update the DFU tool.

## Use

1. Cable the targets. The **Host ports** row shows each port: *Not in DFU* (orange), *In DFU* (blue), *Empty*, or *Connected, may be a charger*.
   Select the ports to put into DFU (or click **Select waiting**), then click **Enter DFU**. Ports are handled one at a time so each Mac card shows which port it is on.
2. Select one or more devices.
3. **Restore**: erases everything. Apple Silicon Macs get the latest signed macOS (or the dropped IPSW). T2 Intel Macs get firmware only; install macOS afterwards from Recovery or a USB installer.
   **Revive**: updates firmware and recoveryOS only. Keeps macOS and data.

## Employees and KPIs

* Every station asks **Who is working?** before any DFU, Restore or Revive. Add names there or in **Settings > Employees**.
* Each DFU, Restore and Revive is recorded with the employee, station, port, model, ECID, result and duration.
* **KPIs** in the header shows totals for this station (today, 7 days, 30 days) and exports CSV.

### KPI API contract

Set the URL and key in **Settings > KPI sync**. The app sends batches of up to 100 events:

```
POST <API URL>
Authorization: Bearer <API key>
Content-Type: application/json

{
  "station": "Exact Station 1",
  "events": [
    {
      "id": "6F1C2D3E-...",              // UUID, unique per event: use it to ignore duplicates
      "kind": "dfu | restore | revive",
      "result": "succeeded | failed",
      "employee": "Employee name",
      "station": "Exact Station 1",
      "port": "Left front",              // optional
      "ecid": "0x114DA20C418026",        // optional
      "deviceType": "iBridge2,15",       // optional
      "deviceName": "Intel Mac (T2)",    // optional
      "ipsw": "UniversalMac_15.6.ipsw",  // optional
      "activation": "locked | clear | unknown", // optional, jobs only
      "error": "…",                      // optional, failures only
      "startedAt": "2026-10-01T09:12:03Z",
      "finishedAt": "2026-10-01T09:31:40Z",
      "durationSeconds": 1177
    }
  ]
}
```

Answer with any 2xx status once the batch is stored. Anything else keeps the events queued and they are sent again later, so the server must treat `id` as unique.

## Credits

* Remote DFU and restart use a modified [macvdmtool](https://github.com/AsahiLinux/macvdmtool) (Apache License 2.0). See `vendor/macvdmtool/NOTICE.md`.
* Restore and Revive use Apple Configurator's `cfgutil`.
