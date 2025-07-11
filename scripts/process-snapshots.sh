#!/bin/bash
set -euo pipefail

echo "[$(date)] Starting snapshot processing run"

# MinIO configuration
MINIO_ENDPOINT="${MINIO_ENDPOINT:-minio-snapshots:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-snapshots}"

# Configure MinIO client
mc alias set snapshots "http://${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}"

# Create bucket if it doesn't exist
mc mb "snapshots/${MINIO_BUCKET}" --ignore-existing

# Set public download policy
mc policy set download "snapshots/${MINIO_BUCKET}"

# Get list of VolumeSnapshots from fullnodes namespace
echo "Finding VolumeSnapshots in fullnodes namespace..."
SNAPSHOTS=$(kubectl get volumesnapshots -n fullnodes -o json | \
  jq -r '.items[] | select(.status.readyToUse==true) | 
  {name: .metadata.name, chain: (.metadata.labels."blockchain.bryanlabs.net/chain-id" // "unknown")} | 
  @base64')

if [ -z "$SNAPSHOTS" ]; then
  echo "No ready VolumeSnapshots found"
  exit 0
fi

# Process each snapshot
for snapshot_data in $SNAPSHOTS; do
  # Decode snapshot data
  SNAPSHOT_INFO=$(echo "$snapshot_data" | base64 -d)
  SNAPSHOT_NAME=$(echo "$SNAPSHOT_INFO" | jq -r '.name')
  CHAIN_ID=$(echo "$SNAPSHOT_INFO" | jq -r '.chain')
  
  echo "Processing snapshot: $SNAPSHOT_NAME for chain: $CHAIN_ID"
  
  # Check if already processed
  PROCESSED_FILE="${CHAIN_ID}/.processed/${SNAPSHOT_NAME}"
  if mc stat "snapshots/${MINIO_BUCKET}/${PROCESSED_FILE}" >/dev/null 2>&1; then
    echo "Snapshot $SNAPSHOT_NAME already processed, skipping"
    continue
  fi
  
  # Process this snapshot
  /scripts/process-single-snapshot.sh "$SNAPSHOT_NAME" "$CHAIN_ID"
done

echo "[$(date)] Snapshot processing run completed"