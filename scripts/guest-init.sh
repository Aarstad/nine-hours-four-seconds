#!/bin/sh
# Guest init for an Alpine rootfs booted on Android's microdroid kernel.
# Installed to /init in the image; the kernel is told `init=/init`.
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root TERM=xterm-256color

# The microdroid kernel has NO devtmpfs -- microdroid ships its own init which
# creates the nodes it needs. A normal rootfs finds /dev completely empty even
# though the kernel enumerated every disk. virtio_blk is major 254, sixteen
# minors per disk. This is the single most confusing failure in the whole build.
mkdir -p /dev /dev/pts /dev/shm /tmp /mnt/job /work
[ -b /dev/vda ]     || mknod /dev/vda b 254 0
[ -b /dev/vdb ]     || mknod /dev/vdb b 254 16
[ -b /dev/vdc ]     || mknod /dev/vdc b 254 32
[ -c /dev/null ]    || mknod /dev/null    c 1 3
[ -c /dev/zero ]    || mknod /dev/zero    c 1 5
[ -c /dev/random ]  || mknod /dev/random  c 1 8
[ -c /dev/urandom ] || mknod /dev/urandom c 1 9
[ -c /dev/ptmx ]    || mknod /dev/ptmx    c 5 2
[ -c /dev/tty ]     || mknod /dev/tty     c 5 0
[ -c /dev/vsock ]   || mknod /dev/vsock   c 10 121
chmod 666 /dev/null /dev/zero /dev/urandom /dev/ptmx /dev/tty /dev/vsock 2>/dev/null
mount -t devpts devpts /dev/pts -o gid=5,mode=620 2>/dev/null
mount -t tmpfs tmpfs /dev/shm 2>/dev/null
hostname alpine-vm 2>/dev/null
ip link set lo up 2>/dev/null

# mke2fs -d copies the BUILD HOST's ownership, so every file belongs to the
# builder's uid rather than root and sshd refuses to start. Fix once, then
# leave a sentinel so later boots skip it.
if [ ! -f /.ownership-fixed ]; then
  echo "first boot: normalising file ownership to root..."
  for d in /bin /sbin /lib /usr /etc /var /opt /srv /root /work /init; do
    [ -e "$d" ] && chown -R 0:0 "$d" 2>/dev/null
  done
  chown 0:0 / 2>/dev/null
  chmod 700 /var/empty 2>/dev/null
  chmod 700 /root/.ssh 2>/dev/null; chmod 600 /root/.ssh/authorized_keys 2>/dev/null
  touch /.ownership-fixed
fi
cd /root

# Optional one-shot job disk (vdb): run a script and print the result.
if mount -t ext4 /dev/vdb /mnt/job 2>/dev/null; then
  if [ -f /mnt/job/job.sh ]; then
    echo "===VM_JOB_BEGIN==="; sh /mnt/job/job.sh 2>&1; echo "===VM_JOB_END==="
  fi
  umount /mnt/job 2>/dev/null
fi

# vsock services. vsock crosses the hypervisor boundary directly, so it needs
# neither the vendor tethering HAL nor crosvm's console input -- the two paths
# that are unavailable on this class of device.
#   host: adb forward tcp:8032 vsock:<CID>:5555
if [ -c /dev/vsock ]; then
  socat VSOCK-LISTEN:5555,fork,reuseaddr \
        EXEC:'/bin/bash -l',pty,stderr,setsid,ctty,echo=0 >/dev/null 2>&1 &
  if [ -x /usr/sbin/sshd ]; then
    /usr/sbin/sshd -o ListenAddress=127.0.0.1 -o Port=22 2>/dev/null
    socat VSOCK-LISTEN:5556,fork,reuseaddr TCP:127.0.0.1:22 >/dev/null 2>&1 &
  fi
  # ttyd: the same thing the stock AOSP Terminal app runs inside its guest.
  if [ -x /usr/bin/ttyd ]; then
    ttyd -p 7681 -i 127.0.0.1 -W -t titleFixed="Alpine VM" \
         -t fontSize=13 tmux new -A -s vm >/dev/null 2>&1 &
    sleep 1
    socat VSOCK-LISTEN:5557,fork,reuseaddr TCP:127.0.0.1:7681 >/dev/null 2>&1 &
  fi
  echo "===VM_VSOCK_UP=== shell:5555 ssh:5556 ttyd:5557"
fi

# Fallback channel over a raw disk, for devices where adb refuses vsock
# forwarding. Also keeps init alive.
if [ -b /dev/vdc ]; then
  echo "===VM_CHANNEL_UP==="
  last=""
  while : ; do
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null   # or we re-read our own stale copy
    hdr=$(dd if=/dev/vdc bs=1024 count=1 2>/dev/null | tr -d '\000' | head -1)
    if [ -n "$hdr" ] && [ "$hdr" != "$last" ]; then
      body=$(dd if=/dev/vdc bs=1024 skip=1 count=63 2>/dev/null | tr -d '\000')
      case "$body" in
        *__EOC__*)
          last="$hdr"
          cmd=$(printf '%s' "$body" | sed '/^__EOC__$/,$d')
          eval "$cmd" > /tmp/out 2>&1     # NOT $(...) -- that forks and loses cd/export
          printf 'DONE%s\n' "${hdr#SEQ}" > /tmp/resp
          head -c 900000 /tmp/out >> /tmp/resp
          dd if=/dev/zero of=/dev/vdc bs=1024 seek=64 count=940 2>/dev/null
          dd if=/tmp/resp  of=/dev/vdc bs=1024 seek=64 conv=notrunc 2>/dev/null
          sync ;;
      esac
    fi
    usleep 150000 2>/dev/null || sleep 1
  done
fi
sync; poweroff -f 2>/dev/null || halt -f 2>/dev/null
exec /bin/sh
