# Re-v-O-mate

> **Re-** = re-implementation. A native macOS remake of the Rev-O-mate config tool.

A macOS-native toolkit (Swift + IOKit) for configuring the Bit Trade One
**Rev-O-mate (BFROM11BK)** left-hand device — a pushable infinite-rotation dial
with 10 buttons. It replaces the official Windows (C#/WinForms) config tool, and
is built on the HID protocol reverse-engineered from the vendor's open source
([`bit-trade-one/BFROM11BK_Rev-O-mate`](https://github.com/bit-trade-one/BFROM11BK_Rev-O-mate)).

- Minimum target: **macOS 26 (Tahoe) / Apple Silicon**.
- The device is a standard USB-HID composite — **no kext or elevated privileges** required.
- Naming note: hyphens are not valid in Swift identifiers, so the package,
  targets and CLI use `RevOmate` / `revomate`.

## Layout

| Target | Role |
|---|---|
| `RevOmateKit` | Core: HID transport, wire protocol, flash model |
| `revomate` (CLI) | Connectivity spike: `version` / `probe` / `peek` / `dump` |
| `RevOmateApp` | SwiftUI app skeleton (connect, show version, flash backup) |

## Protocol at a glance

- Config traffic goes over the **vendor HID interface**
  (VID `0x22EA` / PID `0x004B` / UsagePage `0xFF00` / Usage `0x01`).
- Synchronous request/response: one **64-byte OUT** report → one **64-byte IN** report, **no Report ID**.
- Key commands: `0x11` flash read (≤62 B) · `0x12` write (≤58 B) · `0x13` 64 KiB sector erase · `0x56` version.
- All settings live in an external SPI flash (**M25P16, 2 MiB**).
  Command-header addresses are big-endian; scalars inside the flash are little-endian.
- Gotcha: matching on VID/PID alone makes `IOHIDManagerOpen` try to claim the
  keyboard/mouse interfaces (held exclusively by the OS) → `kIOReturnExclusiveAccess`.
  Match on UsagePage `0xFF00` too so only the vendor interface is opened.

## CLI usage

With the device connected:

```sh
swift run revomate version           # firmware version (0x56)
swift run revomate probe             # base/script headers + first scripts
swift run revomate peek 0x020000 64  # raw hex/ascii dump of a flash range
swift run revomate config            # readable config summary (dial/buttons/LED/scripts)
swift run revomate config dump.bin   #   ...parsed from a saved dump instead
swift run revomate dump backup.bin   # back up the whole 2 MiB flash
swift run revomate verify backup.bin # read flash and compare to a backup (read-only)
swift run revomate restore backup.bin  # restore a backup (only rewrites changed sectors)
```

> Writing is done with a full backup as the safety net: `restore` reads each
> sector first and only erases/rewrites the ones that differ, then the write path
> read-back-verifies. Take a `dump` before experimenting.

> On first run macOS may prompt for USB/Input-Monitoring access — grant it.
> (Launched via `swift run`, the permission attaches to the parent terminal.)

## App skeleton

```sh
swift run RevOmateApp
```

Connect opens the device and shows the firmware version and script count; Dump…
backs up the flash. The configuration UI (dial/button assignments, LED, macro
editor) is still to come.

## Status

- [x] M0 — connectivity (open vendor interface + `0x56`)
- [x] M1 — full flash dump (backup)
- [x] M2 — parsers for each settings region (Base / Function / Encoder / SW / Script), validated against a real dump; `config` command
- [x] M3 — write path (sector erase → page-aware write → read-back verify); `verify` / `restore-sector` / `restore`, validated on hardware
- [~] M4 — configuration UI (SwiftUI): LED editor with **live preview (0x63) + persist (flash)**, mode picker, dial/button viewer, and **dial CW/CCW keyboard-shortcut editing** (8-byte action records; serializer round-trip-validated). Non-keyboard action types & button editing still TODO.
- [ ] M5 — macro (script) editor

### Reflection model (important)

Raw flash writes **persist but do not update the live LED** until a mode change / power cycle
(the firmware runs off a RAM mirror). For instant feedback the app sends the structured live
command **`0x63` (set LED)**; the flash write makes it **persist**. So editing = live-preview via
structured command + save via flash. Confirmed on hardware.

## License

Not yet chosen. The upstream device firmware/app is published by Bit Trade One;
this project is an independent re-implementation of the host-side tooling.
