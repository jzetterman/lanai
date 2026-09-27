# Windows on Omarchy

Run Windows in a window on Omarchy, through [Looking Glass](https://github.com/gnif/LookingGlass).

Status: research spike. Nothing here is ready to install.

## Why

Omarchy's built-in `omarchy-windows-vm` runs Windows in Docker and connects over RDP.
This project tests a different path: a plain QEMU VM that runs as your user, with the
Windows screen shared into Linux through Looking Glass.

Looking Glass's new IDD (Indirect Display Driver) can render in software, so it works
without GPU passthrough. The target users need Windows apps such as Office, or
Windows-only admin tools such as the Active Directory PowerShell modules. Neither needs
a GPU.

## Plan

1. **Spike:** measure Looking Glass software mode against RDP on the same Windows VM.
   See [docs/spike-software-mode.md](docs/spike-software-mode.md).
2. If software mode clearly wins, spec an Omarchy plugin for
   [plugins.omarchy.org](https://plugins.omarchy.org).

Out of v1: GPU passthrough, and a dedicated partition or NVMe for Windows.
