# ReRNDIS

Userspace RNDIS (USB tethering) driver for modern macOS on Apple Silicon.

Replaces the old HoRNDIS kext.
(no SIP changes required)

## Compatibility

- Android phones (USB tethering)
- Embedded Linux boards (Raspberry Pi, BeagleBone, f_rndis)
- macOS 15+ (Apple Silicon or Intel)
- Xcode Command Line Tools installed

## Quick Start

Build and install the daemon:

```sh
make build
sudo make install
```

Optionally build the menu bar app:

```sh
make app
```

Once installed:
1. Connect your device via USB and enable **USB Tethering**.
2. The network interface will configure automatically within a few seconds. Note: It will not appear in **System Settings > Network**, but `ifconfig` and internet routing will work normally.

Check connection status:

```sh
rerndisctl status
```

## Uninstall

```sh
sudo make uninstall
```

## Troubleshooting

If you encounter issues, run the daemon manually in debug mode to check logs:

```sh
RERNDIS_DEBUG=1 .build/debug/ReRNDISDaemon run
```

## License

GPL-2.0-or-later
