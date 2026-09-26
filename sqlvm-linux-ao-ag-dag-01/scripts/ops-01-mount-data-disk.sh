#!/usr/bin/env bash
# Mounts the stack's data disk (Bicep's sqlDataDiskSizeGB disk, LUN 0) on /sqldata. Idempotent.
# Azure names the disk differently by VM generation (/dev/sdc on SCSI sizes, /dev/nvme0n2 on NVMe
# sizes such as the v6/v7 families), so it is found by LUN - or, without the Azure udev links, as the
# largest whole disk that holds nothing (no partition mounted, not an LVM member like the OS disk).
# Usage: sudo ./ops-01-mount-data-disk.sh
set -euo pipefail

if mountpoint -q /sqldata; then
  echo "SQLDATA=already mounted ($(findmnt -no SOURCE /sqldata))"
  df -m --output=size,avail /sqldata | tail -1 | awk '{print "SQLDATA_MB=" $1 "|" $2}'
  exit 0
fi

DEV=""
for p in /dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0; do
  if [ -e "$p" ]; then DEV=$(readlink -f "$p"); break; fi
done
if [ -z "$DEV" ]; then
  best=0
  while read -r name size; do
    # skip disks with anything mounted or used by LVM (the OS disk), and small disks
    if lsblk -nro MOUNTPOINT "$name" | grep -q .; then continue; fi
    if lsblk -nro FSTYPE "$name" | grep -q LVM2_member; then continue; fi
    if [ "$size" -lt $((64 * 1024 * 1024 * 1024)) ]; then continue; fi
    if [ "$size" -gt "$best" ]; then best=$size; DEV=$name; fi
  done < <(lsblk -dnbpo NAME,SIZE,TYPE | awk '$3 == "disk" {print $1, $2}')
fi
if [ -z "$DEV" ]; then echo "ERROR=no unused data disk found"; lsblk; exit 1; fi
echo "DATA_DISK=$DEV"

if ! blkid "$DEV" >/dev/null 2>&1; then
  mkfs.xfs -q "$DEV"
  echo "FORMATTED=$DEV"
fi
mkdir -p /sqldata
UUID=$(blkid -s UUID -o value "$DEV")
sed -i '\# /sqldata #d' /etc/fstab
echo "UUID=$UUID /sqldata xfs defaults,nofail 0 2" >> /etc/fstab
systemctl daemon-reload || true
mount /sqldata
echo "SQLDATA=mounted $DEV"
df -m --output=size,avail /sqldata | tail -1 | awk '{print "SQLDATA_MB=" $1 "|" $2}'
