#!/bin/bash
# Usage: setup-cluster-dir.sh <system> [nodes] [--ramdisk]
# Examples:
#   setup-cluster-dir.sh valkey           - create ~/valkey-cluster/ with one folder per CPU core
#   setup-cluster-dir.sh valkey 16        - create ~/valkey-cluster/ with 16 port folders
#   setup-cluster-dir.sh valkey --ramdisk - create port folders under ramdisk + ~/valkey-cluster/
#   setup-cluster-dir.sh garnet           - create ~/garnet-cluster/ (single folder)
set -e
source /opt/deploy-actions/config.env

SYSTEM="${1:?Usage: setup-cluster-dir.sh <system> [nodes] [--ramdisk]}"
shift

# Parse remaining args
NUM_NODES=""
USE_RAMDISK=false
for arg in "$@"; do
  case "$arg" in
    --ramdisk) USE_RAMDISK=true ;;
    *) NUM_NODES="$arg" ;;
  esac
done
NUM_NODES="${NUM_NODES:-$(nproc)}"

case "$SYSTEM" in
  redis|valkey)
    DIR="$HOME/valkey-cluster"
    mkdir -p "$DIR"
    for (( i=0; i<NUM_NODES; i++ )); do
      PORT=$(( BASE_PORT + i ))
      mkdir -p "$DIR/$PORT"
      if $USE_RAMDISK; then
        mkdir -p "$RAMDISK_DIR/valkey-cluster/$PORT"
      fi
    done
    chown -R $DEPLOY_USER:$DEPLOY_USER "$DIR"
    if $USE_RAMDISK; then
      chown -R $DEPLOY_USER:$DEPLOY_USER "$RAMDISK_DIR/valkey-cluster"
      echo "Created $DIR + $RAMDISK_DIR/valkey-cluster with $NUM_NODES port folders (${BASE_PORT}-$(( BASE_PORT + NUM_NODES - 1 )))"
    else
      echo "Created $DIR with $NUM_NODES port folders (${BASE_PORT}-$(( BASE_PORT + NUM_NODES - 1 )))"
    fi
    ;;
  garnet)
    DIR="$HOME/garnet-cluster"
    mkdir -p "$DIR"
    if $USE_RAMDISK; then
      mkdir -p "$RAMDISK_DIR/garnet-cluster"
      chown -R $DEPLOY_USER:$DEPLOY_USER "$RAMDISK_DIR/garnet-cluster"
    fi
    chown -R $DEPLOY_USER:$DEPLOY_USER "$DIR"
    echo "Created $DIR (single instance, multi-threaded)"
    ;;
  *)
    echo "Unknown system: $SYSTEM (use redis, valkey, or garnet)"
    exit 1
    ;;
esac
