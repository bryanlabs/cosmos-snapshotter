#!/bin/bash
set -euo pipefail

# Keep last N snapshots per chain
KEEP_LAST="${KEEP_LAST:-5}"

echo "[$(date)] Starting cleanup of old snapshots"

# Configure MinIO client
mc alias set snapshots "http://${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}"

# Get list of chains
CHAINS=$(mc ls "snapshots/${MINIO_BUCKET}/" | grep "DIR" | awk '{print $5}' | sed 's/\///')

for chain in $CHAINS; do
  echo "Cleaning up snapshots for chain: $chain"
  
  # Get list of snapshots sorted by date (newest first)
  SNAPSHOTS=$(mc ls "snapshots/${MINIO_BUCKET}/${chain}/" | \
    grep ".tar.lz4$" | \
    grep -v "latest.tar.lz4" | \
    sort -k2,3 -r | \
    awk '{print $5}')
  
  # Count snapshots
  COUNT=0
  for snapshot in $SNAPSHOTS; do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -gt "$KEEP_LAST" ]; then
      echo "Removing old snapshot: $snapshot"
      mc rm "snapshots/${MINIO_BUCKET}/${chain}/${snapshot}"
      mc rm "snapshots/${MINIO_BUCKET}/${chain}/${snapshot}.sha256" || true
      mc rm "snapshots/${MINIO_BUCKET}/${chain}/${snapshot%.tar.lz4}.json" || true
    fi
  done
done

echo "[$(date)] Cleanup completed"