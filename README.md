# Linux VMs on half-shipped Android devices

Tooling from an evening spent booting Alpine Linux inside a hardware VM on an
**unrooted, bootloader-locked, mid-range MediaTek phone** — using only binaries
Android already ships.

No root. No custom ROM. No unlocked bootloader. No computer (adb pairs to the
device over its own loopback).

Write-up: [**Nine Hours, Four Seconds**](POST.md)

Tested on a HONOR 600 Lite (Android 16, MediaTek, GenieZone hypervisor). It
should apply to any device where the AVF package ships disabled and the vendor
never wired up the display and network HALs — which appears to be common.

## Is your device a candidate?

Thirty seconds, on any Android 15+ device:

```sh
adb shell pm list packages -a | grep virtualization
adb shell getprop | grep hypervisor
adb shell pm enable com.android.virtualization.terminal
adb shell /apex/com.android.virt/bin/vm info
```

If `vm info` says *"Both protected and non-protected VMs are supported"*, you
have everything that matters. The stock Terminal app may still fail — it needs a
display backend and a working network tap, and this approach needs neither.

## Quick start

```sh
pkg install e2fsprogs proot android-tools openssh netcat-openbsd   # Termux
vmbuild                  # fetch Alpine, provision with apk under proot, seal an ext4 image
vmdeploy                 # pair adb, push, boot, self-test
vmconnect setup          # forward the guest's vsock ports
vmconnect shell          # interactive PTY
vmconnect ssh / cp       # full session and file transfer
vmconnect web            # ttyd in a browser
```

`VM_PKGS="rust cargo" vmbuild` builds a different package set. The guest has no
network, so everything is installed before the image is sealed.

## Scripts

| | |
|---|---|
| `vmbuild` | fetch Alpine, provision with `apk` under proot, seal an ext4 image |
| `vmdeploy` | pair adb, push the image, boot, verify the toolchain |
| `vmconnect` | vsock forwarding; `shell` / `ssh` / `cp` / `web` |
| `vmsh` | fallback shell over a raw block device, for when vsock is refused |
| `vmrun` | one-shot batch execution via a job disk |
| `guest-init.sh` | the guest's `/init` — all the device-node and service setup |
| `phantom-test` | measure whether Android's phantom-process killer is actually on |

## The five things that will bite you

**1. The microdroid kernel has no devtmpfs.** The guest sees an empty `/dev`
even though the kernel enumerated every disk, and root still mounts because
`root=` resolves by device number. Create the nodes by hand — virtio_blk is
major 254, sixteen minors per disk:

```sh
mknod /dev/vda b 254 0 ; mknod /dev/vdb b 254 16 ; mknod /dev/vsock c 10 121
```

**2. proot's two workarounds fight each other.** `apk` writes its database via
hardlink+rename, which plain proot cannot emulate — without `--link2symlink` the
install looks fine but the database is never written, and a later `apk fix` will
"restore" the rootfs to its base packages and delete everything else. *With*
`--link2symlink`, every hardlink becomes an absolute symlink into the build
host's directory, so the binaries dangle inside the VM. You need the flag **and**
a pass afterwards that materialises each stub back into a real file. `vmbuild`
does this. **A proot-built rootfs can look perfect and be structurally wrong —
verify by executing something, not by listing it.**

**3. `mke2fs -d` copies the build host's ownership.** Everything ends up owned by
the builder's uid, and sshd refuses to start (`/var/empty must be owned by
root`). `guest-init.sh` does a one-time `chown -R 0:0` behind a sentinel file.

**4. Console input is SELinux-blocked**, and FIFOs can't be created in
`/data/local/tmp`. Use vsock instead — it crosses the hypervisor boundary
without touching Android's console or network stacks, and `adb forward
tcp:N vsock:CID:P` is a supported path.

**5. Wireless debugging rotates its port and drops pairing constantly.** Run
`adb tcpip 5555` once and it stays put until reboot. Do **not** port-scan for
adbd — a wide concurrent scan will make it disable wireless debugging entirely,
which looks exactly like a hardware fault.

## What works, and what doesn't

Works: VM boot, custom kernel and rootfs, persistent ext4, interactive PTY,
ssh/scp/sftp, a browser terminal, and a full toolchain (gcc, Python, Node).

Blocked, on this device: guest networking (vendor tethering HAL rejects
`avf_tap_fixed`), crosvm console input (SELinux), and any display backend. The
stock Terminal app cannot be fixed — its VM config lives in a private data
directory and no display knob is exposed.

## Should you use this?

Probably not, for daily work. [Termux](https://termux.dev) is better at almost
everything on a phone: Android API access, instant startup, no adb, a package
repository you can reach from inside it.

The VM earns its place in three cases: running binaries that assume Linux rather
than bionic, wanting something disposable you can rebuild in thirty seconds, and
needing a real kernel — modules, iptables, containers. If none of those apply,
read the write-up and enjoy it as a curiosity. That is roughly what happened
here.

## License

Public domain / CC0. Take what's useful.
