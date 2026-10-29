#!/usr/bin/env bash
set -euo pipefail

# This runs as root on a disposable CI runner. Each image is a separate 512 MB disk.
work=$(mktemp -d)
devices=()
mounts=()
cleanup() {
  local point device
  for point in "${mounts[@]}"; do
    mountpoint -q "$point" && umount "$point"
    python3 - "$point" <<'PY'
import pathlib
import sys
path = pathlib.Path('/etc/fstab')
point = sys.argv[1]
path.write_text(''.join(line for line in path.read_text().splitlines(keepends=True)
                        if len(line.split()) < 2 or line.split()[1] != point))
PY
  done
  for device in "${devices[@]}"; do losetup -d "$device"; done
  rm -rf "$work"
}
trap cleanup EXIT

fail() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
disk() {
  local name=$1 device
  truncate -s 512M "$work/$name.img"
  device=$(losetup --find --show "$work/$name.img")
  devices+=("$device")
  mkdir -p "$work/$name"
  mounts+=("$work/$name")
  disk_result=$device
}
play() {
  local file=$1 device=$2 point=$3
  if [[ -n $device ]]; then
    ansible-playbook -i localhost, "tests/hub_backup_disk/$file.yml" \
      -e "hub_backup_disk_device=$device" -e "hub_backup_mount_point=$point"
  else
    ansible-playbook -i localhost, "tests/hub_backup_disk/$file.yml" \
      -e "hub_backup_mount_point=$point"
  fi
}
fstab_count() { awk -v point="$1" '$2 == point { n++ } END { print n+0 }' /etc/fstab; }

disk fresh
fresh=$disk_result
point=$work/fresh
play setup "$fresh" "$point" >"$work/first.log" 2>&1 || { tail -30 "$work/first.log"; fail 'fresh setup play must pass'; }
[[ $(findmnt -n -o FSTYPE --mountpoint "$point") == xfs ]] || fail 'fresh disk mount must be xfs'
[[ $(fstab_count "$point") == 1 ]] || fail 'fresh disk must have exactly one fstab entry'
awk -v point="$point" -v device="$fresh" '$2 == point && $1 == device && $3 == "xfs" && ("," $4 ",") ~ /,nofail,/' /etc/fstab | grep -q . || fail 'fstab source, type and nofail must match'
echo 'PASS fresh XFS mount, fstab and verify'

play setup "$fresh" "$point" >"$work/second.log" 2>&1 || { tail -30 "$work/second.log"; fail 'second setup play must pass'; }
grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/second.log" || fail 'second play recap must report changed=0'
echo 'PASS second run changed=0 and verify'

umount "$point"
if play verify "$fresh" "$point" >"$work/unmounted.log" 2>&1; then fail 'verify must reject an unmounted disk'; fi
grep -Fq "$point" "$work/unmounted.log" || fail 'unmounted failure must name the mount point'
echo 'PASS unmounted verify failure'
play setup "$fresh" "$point" >"$work/remount.log" 2>&1 || { tail -30 "$work/remount.log"; fail 'setup must remount the disk'; }
python3 - "$point" <<'PY'
import pathlib
import sys
path = pathlib.Path('/etc/fstab')
point = sys.argv[1]
lines = []
for line in path.read_text().splitlines(keepends=True):
    fields = line.split()
    if len(fields) >= 4 and fields[1] == point:
        fields[3] = ','.join(opt for opt in fields[3].split(',') if opt != 'nofail')
        line = '\t'.join(fields) + '\n'
    lines.append(line)
path.write_text(''.join(lines))
PY
if play verify "$fresh" "$point" >"$work/nofail.log" 2>&1; then fail 'verify must reject a missing nofail option'; fi
grep -Fq nofail "$work/nofail.log" || fail 'fstab failure must name nofail'
echo 'PASS missing nofail verify failure'

disk existing-xfs
xfs=$disk_result
mkfs.xfs -f "$xfs" >"$work/mkfs-xfs.log"
mount "$xfs" "$work/existing-xfs"
printf 'original XFS contents\n' >"$work/existing-xfs/proof"
umount "$work/existing-xfs"
play setup "$xfs" "$work/existing-xfs" >"$work/existing-xfs.log" 2>&1 || { tail -30 "$work/existing-xfs.log"; fail 'existing XFS setup must pass'; }
[[ $(cat "$work/existing-xfs/proof") == 'original XFS contents' ]] || fail 'existing XFS file must survive unchanged'
echo 'PASS existing XFS file preserved'

disk existing-ext4
ext4=$disk_result
mkfs.ext4 -F "$ext4" >"$work/mkfs-ext4.log" 2>&1
mount "$ext4" "$work/existing-ext4"
printf 'original ext4 contents\n' >"$work/existing-ext4/proof"
umount "$work/existing-ext4"
if play setup "$ext4" "$work/existing-ext4" >"$work/existing-ext4.log" 2>&1; then fail 'existing ext4 must be rejected'; fi
[[ $(blkid -o value -s TYPE "$ext4") == ext4 ]] || fail 'existing ext4 filesystem must survive'
if mountpoint -q "$work/existing-ext4"; then fail 'existing ext4 must not be mounted'; fi
mount "$ext4" "$work/existing-ext4"
[[ $(cat "$work/existing-ext4/proof") == 'original ext4 contents' ]] || fail 'existing ext4 file must survive unchanged'
echo 'PASS existing ext4 rejected and file preserved'

disk missing-device
missing=$disk_result
if play setup '' "$work/missing-device" >"$work/missing.log" 2>&1; then fail 'missing device must fail argument validation'; fi
grep -Eq 'missing required arguments?:.*hub_backup_disk_device|hub_backup_disk_device.*required' "$work/missing.log" || fail 'missing device must fail at argument validation'
[[ -z $(blkid -o value -s TYPE "$missing") ]] || fail 'missing device must remain unformatted'
[[ $(fstab_count "$work/missing-device") == 0 ]] || fail 'missing device must not create fstab entry'
echo 'PASS missing device rejected without changes'

disk check-mode
check_device=$disk_result
check_point=$work/check-mode
fstab_before=$(sha256sum /etc/fstab | awk '{ print $1 }')
for file in setup verify; do
  if ! ansible-playbook --check -i localhost, "tests/hub_backup_disk/$file.yml" \
      -e "hub_backup_disk_device=$check_device" -e "hub_backup_mount_point=$check_point" \
      >"$work/check-$file.log" 2>&1; then
    tail -30 "$work/check-$file.log"
    fail "check-mode $file play must pass"
  fi
  grep -Eq 'localhost[[:space:]]+:.*failed=0' "$work/check-$file.log" || fail "check-mode $file recap must report failed=0"
done
[[ -z $(blkid -o value -s TYPE "$check_device") ]] || fail 'check-mode disk must remain unformatted'
if mountpoint -q "$check_point"; then fail 'check-mode mount point must remain unmounted'; fi
[[ $(sha256sum /etc/fstab | awk '{ print $1 }') == "$fstab_before" ]] || fail 'check-mode must leave fstab unchanged'
echo 'PASS check-mode setup and verify leave disk, mount and fstab unchanged'
