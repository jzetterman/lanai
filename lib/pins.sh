# Pinned downloads (spec req 26): the one source for every file Lanai
# fetches itself, each checked against its SHA-256 here before use. Values
# from phase 1 (docs/plugin/proofs.md, "Pinned downloads"). lanai
# build-client uses the Looking Glass source; lanai setup-guest the IDD and
# the guest files (guest_pins in lib/setup.sh); the proof kit all of them.
# Source this file; it defines variables only.
# shellcheck shell=bash disable=SC2034

# Looking Glass client source and IDD: one build for both (spec req 8).
# looking-glass.io's per-build source tarball includes every submodule.
LG_BUILD=B7-826-236efcb1
LG_COMMIT=236efcb155f952f5d7d9fcd5891a3060ad254e68
LG_SOURCE_URL=https://looking-glass.io/artifact/$LG_BUILD/source
LG_SOURCE_SHA=e396d923172ff3e6e88a1c6906a0e5e87a298ddb5a18aa4d8cb4da37e78ce250
LG_IDD_URL=https://looking-glass.io/artifact/$LG_BUILD/idd
LG_IDD_SHA=34daa6ddb403c1f503fb2ace94360159818fda1795fc5c2be5cec1f4391d5d57
# The submodule folders of that build's tree (the tarball has no
# .gitmodules). lanai build-client refuses a tree where any is missing or
# empty. Update with the pin.
LG_SUBMODULES=(repos/LGMP repos/LGProtocol repos/PureSpice repos/gui repos/nanosvg
  repos/wayland-protocols)

# SPICE guest agent (clipboard and input helpers), from the spike.
VDAGENT_VERSION=0.10.0
VDAGENT_URL=https://www.spice-space.org/download/windows/vdagent/vdagent-win-$VDAGENT_VERSION/spice-vdagent-x64-$VDAGENT_VERSION.msi
VDAGENT_SHA=77629435705bc27dd7d2525e9d2084f72dbab5fdbf310e812f91332fe18d00eb

# WinFsp, the file system layer the virtio-fs client needs (spec req 15).
# SHA-256 matches the digest GitHub publishes for the release asset.
WINFSP_VERSION=2.1.25156
WINFSP_URL=https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-$WINFSP_VERSION.msi
WINFSP_SHA=073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a

# QEMU guest agent for Windows (clock sync, spec req 21). The build that
# virtio-win's latest-qemu-ga link pointed to on 2026-09-28.
QEMU_GA_VERSION=110.2.3-2.el10
QEMU_GA_URL=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-qemu-ga/qemu-ga-win-$QEMU_GA_VERSION/qemu-ga-x86_64.msi
QEMU_GA_SHA=19dcf8abc30f70c2eb6e87282601fd0476e4e0b19936f63d9c80be30db0796ed

# virtio-win driver ISO (the viofs driver and virtiofs.exe, spec req 15). The
# release virtio-win's stable-virtio link pointed to on 2026-09-28.
VIRTIO_WIN_VERSION=0.1.302-1
VIRTIO_WIN_URL=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$VIRTIO_WIN_VERSION/virtio-win-0.1.302.iso
VIRTIO_WIN_SHA=303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d
