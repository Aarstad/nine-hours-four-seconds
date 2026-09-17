# Recipe: Alpine Linux VM on an unrooted Android phone

Working notes from the session, kept as written. Device: HONOR 600 Lite,
Android 16, MediaTek/GenieZone. Achieved 2026-09-16.

Achieved 2026-09-16. A real Linux VM runs on this unrooted HONOR 600 Lite using
only adb + binaries Android already ships. No root, no custom ROM, no unlocked
bootloader. Driver: `~/.local/bin/vmrun 'shell command'`.

**Recipe**
1. `adb shell pm enable com.android.virtualization.terminal` (ships disabled).
2. `/apex/com.android.virt/bin/vm` is executable by the `shell` group and does
   NOT gate custom raw configs — it only errors on missing files.
3. Reuse Android's own kernel: `/apex/com.android.virt/etc/fs/microdroid_kernel`
   (arm64 Image, shell-readable). Schema reference: `/apex/com.android.virt/etc/microdroid.json`.
4. Build a rootfs image WITHOUT root using `mke2fs -d <dir>` (e2fsprogs) from an
   Alpine aarch64 minirootfs.
5. `vm run config.json --console <file>` — console to a FILE bypasses the broken
   display backend entirely.

**Four gotchas that cost the most time**
- The microdroid kernel has **no devtmpfs**; microdroid's init makes its own
  nodes. Must `mknod /dev/vda b 254 0`, `/dev/vdb b 254 16` (virtio_blk = major
  254, 16 minors per disk) or the guest sees no block devices at all.
- Console **input** is dead: `console input thread exited: failed creating
  WaitContext: Operation not permitted` (SELinux, shell domain). No interactive
  shell. FIFOs also can't be created in /data/local/tmp (SELinux). Hence jobs
  are delivered on a second virtio disk (vdb) and output read from the console.
- `--network-supported` attaches no interface (guest sees only lo/sit0);
  HONOR's tethering HAL rejects `avf_tap_fixed`. So no SSH, no apk fetch.
- `adb shell 'cmd &'` SIGHUPs the child when the session closes — must `setsid`
  from a script file on the device.

**Verified working:** Alpine 3.24.0, kernel 6.6.77, 1GB RAM, uid=0, rootfs
persists across boots, 692MB/s disk I/O, musl dynamic linking, apk-tools present
(but offline — no network).

**vsock supersedes the disk channel (2026-09-16, later).** The disk mailbox was
unnecessary. vsock crosses the hypervisor boundary without the tethering HAL or
crosvm's console, and adb forwards it natively:
  guest: `socat VSOCK-LISTEN:5555,fork EXEC:'/bin/bash -l',pty,stderr,setsid,ctty`
         `socat VSOCK-LISTEN:5556,fork TCP:127.0.0.1:22`  (sshd bridge)
  host:  `adb forward tcp:8032 vsock:<CID>:5555`
Gives a REAL PTY (/dev/pts/0, job control), plus ssh/scp. ~100ms per ssh call
with ControlMaster multiplexing vs 981ms for the disk channel.
Needs `mknod /dev/vsock c 10 121` in the guest (devtmpfs gap again).
`vm list` reports the VM as "VmRun", not the config's name — match on that.

**Two more build gotchas:**
- `proot --link2symlink` is REQUIRED for apk's DB write but rewrites hardlinks
  into absolute symlinks into the Termux build dir (`.l2s..` stubs), so gcc et al
  dangle inside the VM. vmbuild materialises them back afterwards (50 links).
- `mke2fs -d` copies the BUILD HOST's ownership, so everything belongs to uid
  10242, not root — sshd refuses to start. Fixed by a first-boot `chown -R 0:0`
  guarded by a `/.ownership-fixed` sentinel.
- Alpine's sshd has no `UsePAM`; leaving it in sshd_config aborts startup.

**Browser terminal (the stock app's own architecture).** The AOSP Terminal app
renders its VM by running ttyd in the guest and showing it in a WebView, reached
over the VM network — which is exactly the HAL that is broken here. Running ttyd
ourselves and bridging it over vsock gives the same UI and works:
  guest: `ttyd -p 7681 -i 127.0.0.1 -W tmux new -A -s vm` +
         `socat VSOCK-LISTEN:5557,fork TCP:127.0.0.1:7681`
  host:  `adb forward tcp:8034 vsock:<CID>:5557` -> http://localhost:8034
tmux behind it means the session survives closing the browser tab.
The stock app itself cannot be fixed: its VM config lives in its private data
dir (unreadable as uid 2000) and no display knob is exposed.

**Tooling:** `vmbuild` (provision+seal), `vmdeploy` (pair/push/boot/test),
`vmsh` (disk-channel fallback), `vmconnect` (vsock setup|web|shell|ssh|cp).
adbd is pinned to port 5555 via `adb tcpip 5555` — no more pairing churn until
reboot. DO NOT port-scan for adb: 400-way scans made adbd disable Wireless
debugging twice.

**Why it matters:** many OEMs half-ship AVF (package present but disabled, no
display/network HAL). This recipe works anyway, so it likely generalises to other
MediaTek/GenieZone devices.
