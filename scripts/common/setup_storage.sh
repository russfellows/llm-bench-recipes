#!/usr/bin/env bash
# ==============================================================================
# NVMe storage setup for AI workloads (model cache / dataset scratch).
#
# Discovers UNUSED NVMe block devices, assembles them via mdadm (level chosen
# from the count), formats with XFS aligned to the RAID geometry, and mounts
# at $STORAGE_MOUNT (default /mnt/data). Persists via /etc/fstab + mdadm.conf.
#
# RAID level by device count:
#   1   : no RAID, XFS straight on the device
#   2   : RAID-1 mirror
#   3   : RAID-1 mirror + 1 hot spare
#   4   : RAID-10 (4 active)
#   5   : RAID-10 (4 active) + 1 hot spare
#   N>=6: RAID-10 over the largest even count <= N, any odd leftover -> spare
#
# Default mode: DRY-RUN. Pass --execute to actually do it.
# (No --yes flag, per project convention. --execute is the unmistakable verb.)
#
# Env vars:
#   STORAGE_MOUNT      Mount point (default /mnt/data)
#   STORAGE_MIN_GB     Min device size to consider, GB (default 100)
#   STORAGE_RAID_NAME  md array name (default "data" -> /dev/md/data)
#   EXCLUDE_DEVICES    Space-separated extra devices to skip, e.g. "/dev/nvme0n1"
#   CHUNK_KB           mdadm chunk size in KB (default 512)
#
# Safety: every candidate device is screened by MULTIPLE checks; if ANY
# tripwire fires, the device is excluded. The script will refuse to touch:
#   - The device hosting / (root filesystem)
#   - Anything currently mounted (the device or any partition of it)
#   - Anything carrying a filesystem/LVM/MD signature (wipefs -n)
#   - Anything already part of an md array (/proc/mdstat or mdadm --examine)
#   - Anything with existing partitions
#   - Anything used as swap
#   - Anything listed in $EXCLUDE_DEVICES
#   - Anything below STORAGE_MIN_GB
# Every decision is printed with a reason.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

STORAGE_MOUNT="${STORAGE_MOUNT:-/mnt/data}"
STORAGE_MIN_GB="${STORAGE_MIN_GB:-100}"
STORAGE_RAID_NAME="${STORAGE_RAID_NAME:-data}"
EXCLUDE_DEVICES="${EXCLUDE_DEVICES:-}"
CHUNK_KB="${CHUNK_KB:-512}"
MD_DEV="/dev/md/${STORAGE_RAID_NAME}"

EXECUTE=0
case "${1:-}" in
  --execute)       EXECUTE=1 ;;
  --dry-run|"")    EXECUTE=0 ;;
  -h|--help)
    sed -n '2,50p' "$0"
    exit 0
    ;;
  *) die "Unknown argument: $1 (expected --execute or --dry-run)" ;;
esac

need_root

# ---------- Required tools ----------
require_tools() {
  local missing=()
  for t in lsblk wipefs mdadm mkfs.xfs xfs_info blkid findmnt swapon; do
    have "$t" || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing required packages for: ${missing[*]}"
    if [ "$EXECUTE" -eq 1 ]; then
      DEBIAN_FRONTEND=noninteractive apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get -y install mdadm xfsprogs util-linux
    else
      log "  (dry-run) would: apt-get install mdadm xfsprogs util-linux"
    fi
  fi
}
require_tools

# ---------- Discover the root device (never touch it) ----------
root_disk() {
  local src pk
  src=$(findmnt -no SOURCE /)
  # PKNAME of the source gives the parent disk (e.g. nvme0n1p2 -> nvme0n1).
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)
  if [ -n "$pk" ]; then
    echo "/dev/$pk"
  else
    # Fallback: source itself may already be a disk.
    echo "$src"
  fi
}
ROOT_DISK="$(root_disk)"
log "Root filesystem lives on: $ROOT_DISK (will be excluded)"

# ---------- Per-device safety screen ----------
# Echoes "OK" if eligible, or "SKIP: reason" otherwise.
screen_device() {
  local dev="$1"

  [ -b "$dev" ] || { echo "SKIP: not a block device"; return; }

  local type
  type=$(lsblk -ndo TYPE "$dev" 2>/dev/null)
  [ "$type" = "disk" ] || { echo "SKIP: lsblk TYPE=$type (not a whole disk)"; return; }

  if [ "$dev" = "$ROOT_DISK" ]; then
    echo "SKIP: hosts the root filesystem"; return
  fi

  # In the user-provided exclusion list?
  for ex in $EXCLUDE_DEVICES; do
    if [ "$dev" = "$ex" ]; then
      echo "SKIP: in EXCLUDE_DEVICES"; return
    fi
  done

  # Any partition or the device itself mounted?
  local mounts
  mounts=$(lsblk -nrpo MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' || true)
  if [ -n "$mounts" ]; then
    echo "SKIP: has mounted partition(s): $(echo "$mounts" | tr '\n' ',' | sed 's/,$//')"; return
  fi

  # Any partitions at all?
  local parts
  parts=$(lsblk -nrpo NAME,TYPE "$dev" 2>/dev/null | awk '$2=="part"{print $1}')
  if [ -n "$parts" ]; then
    echo "SKIP: has existing partitions: $(echo "$parts" | tr '\n' ',' | sed 's/,$//')"; return
  fi

  # Any filesystem / LVM / MD / swap / etc. signature?
  local sigs
  sigs=$(wipefs -n "$dev" 2>/dev/null | awk 'NR>1{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//')
  if [ -n "$sigs" ]; then
    echo "SKIP: signature(s) present: $sigs"; return
  fi

  # Already in an active md array?
  if grep -q "$(basename "$dev")" /proc/mdstat 2>/dev/null; then
    echo "SKIP: appears in /proc/mdstat"; return
  fi
  if mdadm --examine "$dev" >/dev/null 2>&1; then
    echo "SKIP: mdadm metadata present (--examine succeeded)"; return
  fi

  # Used as swap?
  if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${dev}\b"; then
    echo "SKIP: in use as swap"; return
  fi

  # Size gate.
  local size_bytes size_gb
  size_bytes=$(lsblk -ndbo SIZE "$dev" 2>/dev/null)
  size_gb=$(( size_bytes / 1024 / 1024 / 1024 ))
  if [ "$size_gb" -lt "$STORAGE_MIN_GB" ]; then
    echo "SKIP: ${size_gb} GB < STORAGE_MIN_GB=${STORAGE_MIN_GB}"; return
  fi

  echo "OK: ${size_gb} GB"
}

# ---------- Enumerate NVMe whole-disks ----------
log "Scanning NVMe devices..."
ALL_NVME=$(lsblk -ndpo NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /^\/dev\/nvme[0-9]+n[0-9]+$/ {print $1}' | sort)

if [ -z "$ALL_NVME" ]; then
  die "No NVMe whole-disk devices found via lsblk."
fi

ELIGIBLE=()
echo
printf "  %-20s %s\n" "DEVICE" "DECISION"
printf "  %-20s %s\n" "------" "--------"
while IFS= read -r dev; do
  verdict=$(screen_device "$dev")
  printf "  %-20s %s\n" "$dev" "$verdict"
  if [[ "$verdict" == OK:* ]]; then
    ELIGIBLE+=("$dev")
  fi
done <<< "$ALL_NVME"
echo

N=${#ELIGIBLE[@]}
if [ "$N" -eq 0 ]; then
  die "No eligible NVMe devices after safety screen. Nothing to do."
fi

ok "$N eligible device(s): ${ELIGIBLE[*]}"

# ---------- Pre-existing mount check ----------
if findmnt -n "$STORAGE_MOUNT" >/dev/null 2>&1; then
  die "Mount point $STORAGE_MOUNT is already in use. Refusing to proceed."
fi
if [ -e "$MD_DEV" ]; then
  die "$MD_DEV already exists. Refusing to proceed."
fi

# ---------- Plan the array ----------
LEVEL=""; ACTIVE_COUNT=0; SPARE_COUNT=0
ACTIVE=(); SPARES=()

case "$N" in
  1)
    LEVEL="none"; ACTIVE_COUNT=1; ACTIVE=("${ELIGIBLE[0]}")
    ;;
  2)
    LEVEL="raid1"; ACTIVE_COUNT=2; ACTIVE=("${ELIGIBLE[@]}")
    ;;
  3)
    LEVEL="raid1"; ACTIVE_COUNT=2; SPARE_COUNT=1
    ACTIVE=("${ELIGIBLE[0]}" "${ELIGIBLE[1]}")
    SPARES=("${ELIGIBLE[2]}")
    ;;
  *)
    # 4+: largest even count goes to RAID-10, leftover odd becomes a spare.
    LEVEL="raid10"
    ACTIVE_COUNT=$(( N - (N % 2) ))
    SPARE_COUNT=$(( N - ACTIVE_COUNT ))
    ACTIVE=("${ELIGIBLE[@]:0:ACTIVE_COUNT}")
    SPARES=("${ELIGIBLE[@]:ACTIVE_COUNT}")
    ;;
esac

# ---------- XFS geometry ----------
# RAID-10 (default near=2): data drives = active / 2.
# RAID-1: no striping (sw=1, no su).
# none:  no striping.
XFS_SU=""; XFS_SW=""
if [ "$LEVEL" = "raid10" ]; then
  XFS_SU="${CHUNK_KB}k"
  XFS_SW=$(( ACTIVE_COUNT / 2 ))
fi

# ---------- Print plan ----------
cat <<EOF
==============================================================================
 PLAN
==============================================================================
 Eligible devices : ${#ELIGIBLE[@]}
 RAID level       : ${LEVEL}
 Active members   : ${ACTIVE_COUNT} -> ${ACTIVE[*]}
 Spare members    : ${SPARE_COUNT}$( [ "$SPARE_COUNT" -gt 0 ] && echo " -> ${SPARES[*]}" )
 mdadm chunk      : ${CHUNK_KB} KiB
 Array device     : ${MD_DEV}
 Filesystem       : XFS (block 4 KiB, sector 4 KiB, log 2 GiB)
EOF
if [ -n "$XFS_SU" ]; then
  echo " XFS stripe align : su=${XFS_SU}, sw=${XFS_SW}"
fi
cat <<EOF
 Mount point      : ${STORAGE_MOUNT}
 Mount opts       : defaults,noatime,nodiratime,largeio,inode64,allocsize=16m,logbufs=8,logbsize=256k
==============================================================================

EOF

# ---------- Build the exact commands ----------
declare -a CMDS
if [ "$LEVEL" = "none" ]; then
  TARGET_DEV="${ACTIVE[0]}"
  MKFS_CMD=(mkfs.xfs -f -b size=4096 -s size=4096 -l size=2g "$TARGET_DEV")
else
  TARGET_DEV="$MD_DEV"
  CREATE=(mdadm --create --verbose --run "$MD_DEV"
          --name="$STORAGE_RAID_NAME"
          --level="${LEVEL/raid/}"
          --chunk="$CHUNK_KB"
          --raid-devices="$ACTIVE_COUNT"
          "${ACTIVE[@]}")
  if [ "$SPARE_COUNT" -gt 0 ]; then
    CREATE+=(--spare-devices="$SPARE_COUNT" "${SPARES[@]}")
  fi
  CMDS+=("${CREATE[*]}")
  MKFS_CMD=(mkfs.xfs -f -b size=4096 -s size=4096 -l size=2g)
  if [ -n "$XFS_SU" ]; then
    MKFS_CMD+=(-d "su=${XFS_SU},sw=${XFS_SW}")
  fi
  MKFS_CMD+=("$TARGET_DEV")
fi
CMDS+=("${MKFS_CMD[*]}")
CMDS+=("mkdir -p $STORAGE_MOUNT")
CMDS+=("# /etc/fstab line uses UUID after mkfs")
CMDS+=("mount $STORAGE_MOUNT")

log "Steps that will run:"
i=1
for c in "${CMDS[@]}"; do
  printf "  %2d. %s\n" "$i" "$c"
  i=$((i+1))
done

if [ "$EXECUTE" -ne 1 ]; then
  echo
  warn "Dry-run only. Re-run with --execute to actually create the array and filesystem."
  exit 0
fi

# ---------- EXECUTE ----------
log "Proceeding with --execute."

if [ "$LEVEL" != "none" ]; then
  log "Creating md array..."
  # shellcheck disable=SC2046  # intentional: unquoted $() word-splits spare-device args for mdadm
  mdadm --create --verbose --run "$MD_DEV" \
        --name="$STORAGE_RAID_NAME" \
        --level="${LEVEL/raid/}" \
        --chunk="$CHUNK_KB" \
        --raid-devices="$ACTIVE_COUNT" \
        "${ACTIVE[@]}" \
        $( [ "$SPARE_COUNT" -gt 0 ] && printf -- '--spare-devices=%d %s' "$SPARE_COUNT" "${SPARES[*]}" )

  log "Updating /etc/mdadm/mdadm.conf..."
  install -d -m 0755 /etc/mdadm
  # Strip any prior entry for this array name, then append a fresh one.
  if [ -f /etc/mdadm/mdadm.conf ]; then
    sed -i "\#name=${STORAGE_RAID_NAME}#d" /etc/mdadm/mdadm.conf
  fi
  mdadm --detail --scan | grep "name=${STORAGE_RAID_NAME}" >> /etc/mdadm/mdadm.conf

  log "Rebuilding initramfs so the array assembles on boot..."
  update-initramfs -u
fi

log "Formatting $TARGET_DEV with XFS..."
"${MKFS_CMD[@]}"

log "Creating mount point $STORAGE_MOUNT..."
mkdir -p "$STORAGE_MOUNT"

UUID=$(blkid -s UUID -o value "$TARGET_DEV")
[ -n "$UUID" ] || die "Could not read UUID of $TARGET_DEV."

FSTAB_LINE="UUID=$UUID  $STORAGE_MOUNT  xfs  defaults,noatime,nodiratime,largeio,inode64,allocsize=16m,logbufs=8,logbsize=256k  0  2"
log "Adding fstab entry:"
echo "  $FSTAB_LINE"
# Replace any previous entry for the same mount point.
sed -i "\#[[:space:]]${STORAGE_MOUNT}[[:space:]]#d" /etc/fstab
echo "$FSTAB_LINE" >> /etc/fstab

log "Mounting..."
mount "$STORAGE_MOUNT"

REAL_USER="$(real_user)"
chown "$REAL_USER:$REAL_USER" "$STORAGE_MOUNT"

ok "Storage ready:"
df -hT "$STORAGE_MOUNT"
echo
xfs_info "$STORAGE_MOUNT" | sed 's/^/  /'
if [ "$LEVEL" != "none" ]; then
  echo
  log "md array status:"
  mdadm --detail "$MD_DEV" | sed 's/^/  /'
fi
