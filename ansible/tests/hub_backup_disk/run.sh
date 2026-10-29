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
failures=0
check_failure() {
  local label=$1 device=$2 point=$3 expected=$4 log="$work/$1.log" actual
  if play verify "$device" "$point" >"$log" 2>&1; then
    printf 'ASSERTION FAILED: %s: verify passed\n' "$label" >&2
    failures=$((failures + 1))
    return
  fi
  actual=$(python3 - "$log" <<'PY'
import json
import pathlib
import sys
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('fatal: [localhost]: FAILED! => '):
        print(json.loads(line.split(' => ', 1)[1]).get('msg', ''))
        break
PY
)
  if [[ $actual != "$expected" ]]; then
    printf 'ASSERTION FAILED: %s: expected <%s>, got <%s>\n' "$label" "$expected" "$actual" >&2
    failures=$((failures + 1))
  else
    printf 'PASS %s\n' "$label"
  fi
}
set_fstab_field() {
  python3 - "$1" "$2" "$3" <<'PY'
import pathlib
import sys
point, column, value = sys.argv[1], int(sys.argv[2]), sys.argv[3]
path = pathlib.Path('/etc/fstab')
lines = []
for line in path.read_text().splitlines(keepends=True):
    fields = line.split()
    if len(fields) >= 4 and fields[1] == point:
        fields[column] = value
        line = '\t'.join(fields) + '\n'
    lines.append(line)
path.write_text(''.join(lines))
PY
}
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
check_failure unmounted "$fresh" "$point" "Nothing is mounted at $point."
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
check_failure nofail "$fresh" "$point" "The /etc/fstab entry for $point is missing nofail."

disk symlink
symlink_device=$disk_result
symlink_point=$work/symlink
ln -s "$symlink_device" "$work/backup-by-id"
play setup "$work/backup-by-id" "$symlink_point" >"$work/symlink-first.log" 2>&1 || { tail -30 "$work/symlink-first.log"; fail 'symlink setup and verify must pass'; }
awk -v point="$symlink_point" -v device="$work/backup-by-id" '$2 == point && $1 == device { found++ } END { exit found != 1 }' /etc/fstab || fail 'symlink fstab source must be the supplied path'
play setup "$work/backup-by-id" "$symlink_point" >"$work/symlink-second.log" 2>&1 || { tail -30 "$work/symlink-second.log"; fail 'symlink second play must pass'; }
grep -Eq 'localhost[[:space:]]+:.*changed=0' "$work/symlink-second.log" || fail 'symlink second play must report changed=0'
echo 'PASS symlink source and second run changed=0'

disk wrong-source
source_device=$disk_result
source_point=$work/wrong-source
play setup "$source_device" "$source_point" >"$work/wrong-source-setup.log" 2>&1 || { tail -30 "$work/wrong-source-setup.log"; fail 'wrong-source setup must pass'; }
disk other-source
other_source=$disk_result
mkfs.xfs -f "$other_source" >"$work/other-source-mkfs.log"
umount "$source_point"
mount "$other_source" "$source_point"
check_failure wrong-source "$source_device" "$source_point" "$source_point has $other_source mounted, not the backup disk $source_device."

disk wrong-fstype
type_device=$disk_result
type_point=$work/wrong-fstype
play setup "$type_device" "$type_point" >"$work/wrong-fstype-setup.log" 2>&1 || { tail -30 "$work/wrong-fstype-setup.log"; fail 'wrong-fstype setup must pass'; }
umount "$type_point"
mkfs.ext4 -F "$type_device" >"$work/wrong-fstype-mkfs.log" 2>&1
mount "$type_device" "$type_point"
check_failure wrong-fstype "$type_device" "$type_point" "$type_point is mounted as ext4, not xfs."

disk duplicate-fstab
duplicate_device=$disk_result
duplicate_point=$work/duplicate-fstab
play setup "$duplicate_device" "$duplicate_point" >"$work/duplicate-setup.log" 2>&1 || { tail -30 "$work/duplicate-setup.log"; fail 'duplicate setup must pass'; }
duplicate_line=$(awk -v point="$duplicate_point" '$2 == point { print }' /etc/fstab)
printf '%s\n' "$duplicate_line" >> /etc/fstab
check_failure duplicate-fstab "$duplicate_device" "$duplicate_point" "/etc/fstab needs exactly one entry for $duplicate_point, and it has 2."

disk fstab-source
fstab_source_device=$disk_result
fstab_source_point=$work/fstab-source
play setup "$fstab_source_device" "$fstab_source_point" >"$work/fstab-source-setup.log" 2>&1 || { tail -30 "$work/fstab-source-setup.log"; fail 'fstab-source setup must pass'; }
set_fstab_field "$fstab_source_point" 0 "$other_source"
check_failure fstab-source "$fstab_source_device" "$fstab_source_point" "The /etc/fstab entry for $fstab_source_point names $other_source, not the backup disk $fstab_source_device."

disk fstab-fstype
fstab_type_device=$disk_result
fstab_type_point=$work/fstab-fstype
play setup "$fstab_type_device" "$fstab_type_point" >"$work/fstab-fstype-setup.log" 2>&1 || { tail -30 "$work/fstab-fstype-setup.log"; fail 'fstab-fstype setup must pass'; }
set_fstab_field "$fstab_type_point" 2 ext4
check_failure fstab-fstype "$fstab_type_device" "$fstab_type_point" "The /etc/fstab entry for $fstab_type_point has type ext4, not xfs."

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

mkdir -p "$work/missing-device"
mounts+=("$work/missing-device")
missing_fstab_before=$(sha256sum /etc/fstab | awk '{ print $1 }')
if play setup '' "$work/missing-device" >"$work/missing.log" 2>&1; then fail 'missing device must fail argument validation'; fi
grep -Eq 'missing required arguments?:.*hub_backup_disk_device|hub_backup_disk_device.*required' "$work/missing.log" || fail 'missing device must fail at argument validation'
[[ $(sha256sum /etc/fstab | awk '{ print $1 }') == "$missing_fstab_before" ]] || fail 'missing device must leave fstab unchanged'
if mountpoint -q "$work/missing-device"; then fail 'missing device must not mount the path'; fi
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
(( failures == 0 )) || fail "$failures verify message cases"
