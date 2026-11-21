#!/usr/bin/env bash
# Isolated, destructive-only-to-new-test-images filesystem acceptance.
# NOT for a production SD card. No device path or recorder directory is used.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v mkfs.vfat >/dev/null
command -v mkfs.exfat >/dev/null
command -v mkfs.ext4 >/dev/null
command -v sudo >/dev/null
command -v mountpoint >/dev/null

scratch="$(mktemp -d -t finalizer-fs-matrix-XXXXXXXX)"
cleanup() {
  local mounted
  for mounted in "$scratch"/mount-*; do
    if mountpoint -q "$mounted"; then
      sudo umount -- "$mounted" || true
    fi
  done
  rm -rf -- "$scratch"
}
trap cleanup EXIT

helper="$scratch/finalizer_noreplace"
cc -std=c11 -O2 -Wall -Wextra -Werror -o "$helper" \
   "$root/tools/finalizer_noreplace.c"

user_id="$(id -u)"
group_id="$(id -g)"
for fs in ext4 vfat exfat; do
  image="$scratch/fs-$fs.img"
  mounted="$scratch/mount-$fs"
  mkdir "$mounted"
  truncate -s 128M "$image"

  case "$fs" in
    ext4)
      mkfs.ext4 -F -q "$image"
      sudo mount -t ext4 -o loop "$image" "$mounted"
      sudo chown "$user_id:$group_id" "$mounted"
      ;;
    vfat)
      mkfs.vfat -F 32 "$image" >/dev/null
      sudo mount -t vfat -o "loop,uid=$user_id,gid=$group_id,umask=022" \
        "$image" "$mounted"
      ;;
    exfat)
      mkfs.exfat "$image" >/dev/null
      sudo mount -t exfat -o "loop,uid=$user_id,gid=$group_id,umask=022" \
        "$image" "$mounted"
      ;;
  esac
  mountpoint -q "$mounted"

  # Existing final must survive colliding staged content on all 3 filesystems.
  original="$mounted/VD3001_20261029_205000-ch0.mp4"
  staged="$mounted/VD3001_20261029_205000-ch0.mp4.part"
  printf '%s' KEEP-EXISTING-BYTES > "$original"
  printf '%s' NEW-CANDIDATE-BYTES > "$staged"
  if "$helper" "$staged" "$original"; then
    echo "ERROR $fs: existing finalized video overwritten" >&2
    exit 1
  fi
  test "$(cat "$original")" = KEEP-EXISTING-BYTES
  test "$(cat "$staged")" = NEW-CANDIDATE-BYTES

  # Publish once; staged name disappears and final matches source.
  rm -- "$original" # exclusively test image fixture
  "$helper" "$staged" "$original"
  test ! -e "$staged"
  test "$(cat "$original")" = NEW-CANDIDATE-BYTES

  # Subtitle collision must never replace an already finalized SRT.
  source_srt="$mounted/VD3001_20261029_205000-data.srt.part"
  final_srt="$mounted/VD3001_20261029_205000-data.srt"
  printf '%s' ORIGINAL-SRT > "$final_srt"
  printf '%s' NEW-SRT > "$source_srt"
  if "$helper" "$source_srt" "$final_srt"; then
    echo "ERROR $fs: existing finalized SRT overwritten" >&2
    exit 1
  fi
  test "$(cat "$final_srt")" = ORIGINAL-SRT
  test "$(cat "$source_srt")" = NEW-SRT

  # Cross-device rename is prohibited; must preserve original source.
  other="$scratch/cross-device-$fs.mp4.part"
  printf '%s' CROSS-DEVICE-SOURCE > "$other"
  if "$helper" "$other" "$mounted/other-final.mp4"; then
    echo "ERROR $fs: cross-device rename accepted" >&2
    exit 1
  fi
  test -e "$other"
  test ! -e "$mounted/other-final.mp4"

  echo "PASS filesystem=$fs kernel=$(uname -r) no-clobber video+SRT+EXDEV"
  sudo umount -- "$mounted"
done
echo "PASS Finalizer FS matrix ext4/vfat/exfat (isolated runner loop images)"
