# Nine Hours, Four Seconds

*In which a £200 phone turns out to have a hypervisor, I spend an evening
proving it, and the problem I started with is solved by a package manager in the
time it takes to sneeze.*

HONOR 600 Lite · Android 16 · no root · one evening

---

The whole thing started because Mason wouldn't install a language server.

If you haven't met Mason, it's the bit of Neovim that fetches language servers
for you. It works by downloading prebuilt binaries, which is a perfectly
sensible design right up until you run it on a phone, at which point it
downloads binaries built against glibc and hands them to Android, which uses
bionic, and the two of them stare at each other like guests who have both turned
up to the wrong wedding.

The correct fix takes four seconds. I'll come back to that. First I want to tell
you about the nine hours.

## Everyone says it's Pixel only

Android 16 ships a Linux Terminal — an actual Debian virtual machine running
under the Android Virtualization Framework. Every article I could find said the
same two things: Pixel devices only, and Samsung never. My phone is a HONOR 600
Lite, a mid-range MediaTek handset I bought precisely because it was cheap
enough to experiment on.

So naturally I checked. And there it was:

```
$ pm list packages -d | grep virtualization
package:com.android.virtualization.terminal   ← disabled

$ getprop | grep hypervisor
[ro.boot.hypervisor.protected_vm.supported]: [1]
[ro.boot.hypervisor.vm.supported]: [1]
[ro.boot.hypervisor.version]: [GenieZone]
```

The package was *right there*. Shipped, present, and switched off, with the
Developer Options entry that would normally enable it quietly removed from the
menu. GenieZone, incidentally, is MediaTek's own hypervisor rather than Google's
pKVM, which is why there's no `/dev/kvm` — it lives at `/dev/gzvm` instead.
crosvm has supported it upstream for years.

One command later it was enabled, and one command after that it launched,
downloaded 525 MB of Debian, booted a virtual machine that reached 349 MB of
resident memory, and then died.

```
E crosvm  : failed to open display: unsupported by the implementation
E Tethering: addDownstream(avf_tap_fixed, 10.194.2.0/24) failed:
          IllegalArgumentException: Invalid interface name
```

Here is the thing about that error. The hypervisor worked. crosvm worked. The VM
booted. What didn't work were two vendor HALs — the display backend and the
network tap — which were never wired up on this device. That is what you would
expect of a feature shipped switched off, with its Developer Options entry
removed: nothing downstream of the menu was ever exercised.

There's an in-app "Recovery" button. It is the saddest button I have ever
pressed. It restarts the VM, which boots, which asks for a display, which isn't
there, which fails, which offers you the Recovery button. I pressed it several
times in case it was building up to something.

## The single most important error message of the evening

The app was a dead end, but the app is not the only way to start a VM. Buried in
the AVF apex there's a command-line tool:

```
$ ls -l /apex/com.android.virt/bin/vm
-rwxr-xr-x 1 root shell 1155976 vm
```

Mode `rwxr-xr-x`, group `shell`. That's the group adb runs as. So I could execute
it. The question — the only question that actually mattered all evening — was
whether it would let me hand it my own virtual machine configuration, or whether
it would check a signature and tell me to go away.

I pointed it at a config file referring to a kernel that did not exist, on the
theory that the error message would tell me which kind of "no" I was getting.

```
$ vm run /data/local/tmp/probe.json
Error: Failed to open "/data/local/tmp/nonexistent-kernel"
Caused by:
    No such file or directory (os error 2)
```

It complained about the *file*. Not the permissions. Not a signature. It was
perfectly happy to run a virtual machine of my own design; it just wanted me to
supply a kernel that was actually there.

Everything after this point is plumbing. Enjoyable plumbing, occasionally
humiliating plumbing, but plumbing.

## Two things I didn't have to build

I assumed the hard part would be getting a kernel. It was not, because Android
ships one and leaves it readable:

```
/apex/com.android.virt/etc/fs/microdroid_kernel   12 MB, arm64 Image
/apex/com.android.virt/etc/microdroid.json        the config schema, by example
```

Then I assumed the hard part would be building a root filesystem, since making an
ext4 image traditionally involves a loop mount, which involves root, which I did
not have. It was not, because `mke2fs` has a flag called `-d` that populates an
image directly from a directory. No loop device, no privileges, no ceremony. If
there's one command in this whole piece worth stealing, it's that one.

Alpine's aarch64 minirootfs is four megabytes compressed. Twenty minutes later I
had an image.

## The kernel could see the disks. The guest could not.

The first boots got as far as running my init and then found absolutely nothing
to work with.

```
virtio_blk virtio3: [vda] 819200 512-byte logical blocks (419 MB)
virtio_blk virtio4: [vdb]  16384 512-byte logical blocks (8.39 MB)
blockdevs:            ← nothing
```

Read that again, because it took me an embarrassing while. The kernel enumerates
both disks. It prints their sizes. And `/dev` is empty.

The microdroid kernel has no devtmpfs. Microdroid brings its own init which
creates the device nodes it needs, so nobody ever noticed, and a normal root
filesystem walks in expecting `/dev` to populate itself and finds a bare room.
The root filesystem had mounted fine because the kernel resolves `root=` by
device *number*, which made the whole thing look like a disk problem rather than
a `/dev` problem.

virtio_blk is major 254 with sixteen minors per disk. Three `mknod` calls and it
booted.

```
#############################################
##  ALPINE ON HONOR 600 LITE / GenieZone   ##
#############################################
Linux (none) 6.6.77-android15-8 aarch64
MemTotal:  1015844 kB
uid=0(root) gid=0(root)
```

I would like to report that I responded to this with professional composure.

---

## An interlude, in which I attack myself twice

I should mention the two occasions on which the obstacle was me.

Android's Wireless Debugging rotates its port every time it restarts, and it
restarts often. Rather than bother anyone, I wrote a scanner to find the new
port. The scanner opened four hundred simultaneous connections to my own phone.
My phone, reasonably, concluded it was under attack and switched wireless
debugging off entirely. I did this twice before the pattern occurred to me.

The proper fix, for the record, is `adb tcpip 5555`, which pins adbd to a fixed
port until reboot and ends the whole miserable cycle. I found this on hour seven.

> **The second one.** `curl` started returning `405 Method Not Allowed` from a
> server running on the same machine, half a metre from itself. I checked the
> server. I rewrote the server. I wrote a *smaller* server to prove the first
> server wasn't mad. The small one also returned 405.
>
> My own tooling had set `http_proxy=127.0.0.1:33747`, and curl was dutifully
> routing localhost traffic through a proxy that had opinions about it. The same
> proxy later ate an entire package installation and reported it as a network
> failure.

I mention these because write-ups tend to present a clean line from problem to
solution, and the actual line spent a meaningful fraction of the evening running
away from me.

## The clever solution that was completely unnecessary

Now the good part, and by good I mean simultaneously my favourite thing I built
all evening and entirely superfluous.

I had output from the VM — the console writes to a file — but no way to type into
it. crosvm's console input needs an epoll context that SELinux won't grant the
shell domain. Named pipes are forbidden in `/data/local/tmp`. The network doesn't
exist because of that broken tethering HAL. I had built a computer I could watch
but not talk to, which is a fairly pure form of frustration.

Then it occurred to me that the host and the guest both hold a file descriptor to
the same disk image, and crosvm never replaces that file. Which makes a raw disk
with no filesystem on it a shared buffer. SELinux inspects the descriptor when it
is opened; it has nothing to say about the sectors you write afterwards.

```
offset 0       "SEQ<n>"              request header, written LAST
offset 1 KiB   command body, ending "__EOC__"
offset 64 KiB  "DONE<n>" + output    response
```

The guest polls the header; when the sequence number changes, it runs the command
and writes the answer back. Three problems had to be solved to make it reliable,
and each one is a decent little lesson:

- **The guest caches the block device** and cheerfully re-reads its own stale copy
  forever. `blockdev --flushbufs` isn't enough. You need
  `echo 3 > /proc/sys/vm/drop_caches` on every poll, which is roughly as elegant
  as it sounds.
- **Torn reads.** Polling mid-write delivers half a command. My favourite symptom
  of the evening was `true` arriving in the guest as `ue`. Fixed by writing the
  body first and the header last, so a new header proves the body is already
  complete.
- **Lost shell state.** Running the command through `$(...)` or a pipe forks a
  subshell, so every `cd` and `export` evaporated between commands. Plain
  redirection keeps them.

It worked. Round trip: 981 milliseconds. A shell, of sorts, into a Linux virtual
machine on an unrooted budget phone, over a block device, at roughly the speed of
a thoughtful person.

I was quite pleased with myself for about an hour.

## Then somebody read my own logs better than I did

I showed the write-up to someone, who pointed out that both of my blockers — the
tethering HAL and the console epoll — are properties of Android's *networking*
and *console* stacks, and that vsock is neither. vsock crosses the hypervisor
boundary directly. And adb, it turns out, forwards it natively.

The evidence had been in my own terminal for hours. The guest printed
`NET: Registered PF_VSOCK protocol family` at every single boot.
`/dev/vhost-vsock` existed on the host. `vm list` was handing every virtual
machine a Context ID and showing it to me in a column. I had read all three and
joined up precisely none of them.

```sh
# guest
mknod /dev/vsock c 10 121          # ← the devtmpfs thing again
socat VSOCK-LISTEN:5555,fork EXEC:'/bin/bash -l',pty,stderr,setsid,ctty

# host
adb forward tcp:8032 vsock:$CID:5555
```

```
$ printf 'uname -rm; tty; exit\n' | nc 127.0.0.1 8032
[?2004h alpine-vm:~#          ← bracketed paste: readline is live
6.6.77-android15-8 aarch64
/dev/pts/0                    ← a real PTY, not a pipe
```

A proper terminal. Job control, line editing, signals, the lot. A second listener
bridged to sshd, which brought `scp` — so a guest with no network could still
exchange files with the phone it lives inside. Round trip went from 981 ms to
about 100, and an interactive session is simply instant.

The block-device mailbox remains in the repository as a fallback, and I have not
deleted it, because I am only human.

---

## The rootfs will lie to you

The genuinely nasty part of the evening wasn't the VM at all. It was building a
root filesystem with packages in it, because the guest has no network and
everything must be installed beforehand, from the phone, using proot.

Two workarounds are required, and they actively fight each other.

`apk` writes its package database using hardlink-and-rename, which plain proot
cannot emulate. Without `--link2symlink` the install appears to succeed — 110
packages, 478 MB, no errors you'd notice — while the database is never written.
Your reward comes later, when `apk fix` helpfully restores the filesystem to the
sixteen packages it believes are installed, deleting the other 470 MB.

*With* `--link2symlink`, every hardlink becomes an absolute symlink pointing into
the build directory on the host:

```
/usr/bin/gcc -> /data/data/com.termux/.../root/usr/bin/.l2s..apk.7b938909...
```

That path does not exist inside the virtual machine. So fifty binaries, gcc among
them, were elegant little signposts pointing at nothing. The filesystem listing
looked perfect. Right names, right sizes, right permissions. `apk` reported a
clean 124 packages. It only surfaced when I actually tried to compile something
and got `gcc: not found`.

> A root filesystem built under proot can look completely correct and be
> structurally wrong. Verify it by executing something, not by listing it.

There's a third one, smaller and funnier: `mke2fs -d` copies the build host's
file ownership, so every file in the image belonged to my Termux user rather than
root, and sshd refused to start on the grounds that `/var/empty must be owned by
root`. I found this by starting sshd by hand through the vsock shell I had just
built, which was a pleasing use of it.

## The joke at the end

Having got all this working, I went back to look at the stock Terminal app,
because whatever else you say about it, it has a nicer interface than anything I
built. Native tabs. A settings gear. Its own entry in the app switcher.

And here is what that app actually does, once you look: it runs `ttyd` inside the
guest and displays it in a WebView.

It was a web terminal the whole time. The beautiful native app with the tabs was
a browser pointed at a virtual machine, reached over the one HAL this vendor
never wired up. Its display backend failure wasn't even the interesting part of
its problem.

So I ran the same `ttyd`, bridged it over vsock, forwarded a port, and opened it
in Chrome. Same architecture, same program, same interface, routed around both
failures. Add to Home Screen gives it an icon and its own task, and honestly you
cannot tell the difference.

## So: nine hours. Was it worth it?

Let me deal with the four seconds first.

```
$ pkg install lua-language-server
✓ done
```

Termux builds language servers natively for aarch64 and puts them in its own
repository, because of course it does. The entire Mason problem — the thing that
started all this — evaporates if you stop asking Mason to do it and ask the
package manager instead. I knew this by hour two. I kept going anyway.

And for daily use, Termux wins on essentially every axis. It talks to Android:
clipboard, notifications, the share sheet, Tasker, the camera. It needs no adb,
no pairing, no forwarded ports. It starts instantly, costs no extra memory, and
can reach its own package repository, which the VM notably cannot.

The VM wins in exactly three situations, and they're real ones: when you need to
run a binary that assumes Linux rather than Android, when you want something
disposable you can destroy and rebuild in thirty seconds, and when you need a
genuine kernel — modules, iptables, containers — which Termux will never give
you. If none of those describe your week, this is a curiosity.

But I don't think "was it worth it" is quite the right question, and I want to
push back on my own framing a little, because the honest answer isn't *no*, it's
*not for the reason I started*.

Three things came out of the evening that outlast the virtual machine:

- **The phantom process killer was never switched on.** I'd blamed an earlier
  SIGKILL on it, written a script to disable it, and drafted instructions for
  enabling adb to do so. Then I actually measured: ninety processes spawned,
  ninety survived. It had been plain memory pressure from eleven parallel `clang`
  instances the whole time. I had built a tool to solve a problem I never had.
- **A raw block device is an IPC channel** whenever two processes hold descriptors
  to the same file. It is slow and undignified and it works when nothing else
  will. Worth knowing as a last resort.
- **vsock ignores the Android network stack entirely**, and when a vendor breaks
  the network HAL — which many of them have — that door is usually still standing
  open.

And the finding that might actually be useful to someone else: this shape of
half-shipped AVF is probably common. The package present but disabled, the vendor
HALs unwired, the hypervisor underneath working perfectly. Every article said
Pixel only. It took thirty seconds to find out otherwise on a cheap MediaTek
handset, and the same thirty seconds is worth spending on any Android 15-or-later
device you happen to own.

I have since stopped the VM and deleted the images, freeing five gigabytes. The
tooling remains, and rebuilds the whole thing in about thirty seconds, and I
expect I will never run it again.

Best evening I've had in months.

---

*Written from a live session on the phone itself. Every command, timing and error
message above is real, including the ones where I am the antagonist.*

*Scripts: [README.md](README.md)*
