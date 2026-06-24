#!/bin/bash
# Usage: setup-ramdisk.sh [mount_path] [size_percent]
# Sets up a tmpfs ramdisk using a percentage of total VM memory.
# Examples:
#   setup-ramdisk.sh                    - mount at /mnt/ramdisk using 50% memory
#   setup-ramdisk.sh /mnt/ramdisk 50   - same as above (explicit)
#   setup-ramdisk.sh /mnt/ramdisk 75   - use 75% of memory
set -e
source /opt/deploy-actions/config.env

MOUNT_PATH="${1:-$RAMDISK_DIR}"
SIZE_PERCENT="${2:-50}"

TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAMDISK_KB=$(( TOTAL_MEM_KB * SIZE_PERCENT / 100 ))
RAMDISK_MB=$(( RAMDISK_KB / 1024 ))

echo "==== Setting up ramdisk ===="
echo "  Total memory: $(( TOTAL_MEM_KB / 1024 )) MB"
echo "  Ramdisk size: ${RAMDISK_MB} MB (${SIZE_PERCENT}%)"
echo "  Mount path:   ${MOUNT_PATH}"

# Create mount point
mkdir -p "$MOUNT_PATH"

# Unmount if already mounted
if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
    echo "  Ramdisk already mounted, remounting..."
    umount "$MOUNT_PATH"
fi

# Mount tmpfs
mount -t tmpfs -o size=${RAMDISK_MB}m tmpfs "$MOUNT_PATH"

# Set ownership
chown -R $DEPLOY_USER:$DEPLOY_USER "$MOUNT_PATH"

# Add to fstab for persistence across reboots (idempotent)
FSTAB_ENTRY="tmpfs ${MOUNT_PATH} tmpfs size=${RAMDISK_MB}m,uid=$(id -u $DEPLOY_USER),gid=$(id -g $DEPLOY_USER) 0 0"
if ! grep -qF "$MOUNT_PATH" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
    echo "  Added fstab entry for persistence"
fi

echo "==== Ramdisk ready at ${MOUNT_PATH} (${RAMDISK_MB} MB) ===="
