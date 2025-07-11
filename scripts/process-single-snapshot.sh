#!/bin/bash
set -euo pipefail

SNAPSHOT_NAME="$1"
CHAIN_ID="$2"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
WORKDIR="/tmp/snapshot-${SNAPSHOT_NAME}-${TIMESTAMP}"

echo "[$(date)] Processing snapshot $SNAPSHOT_NAME for chain $CHAIN_ID"

# Create working directory
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Create PVC from VolumeSnapshot
cat > pvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: snapshot-pvc-${TIMESTAMP}
  namespace: apps
spec:
  dataSource:
    name: ${SNAPSHOT_NAME}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
  - ReadWriteOnce
  storageClassName: topolvm-ssd-xfs
  resources:
    requests:
      storage: 100Gi
EOF

# Create the PVC
kubectl apply -f pvc.yaml

# Wait for PVC to be bound
echo "Waiting for PVC to be bound..."
kubectl wait --for=condition=Bound "pvc/snapshot-pvc-${TIMESTAMP}" -n apps --timeout=300s

# Create processing job
cat > job.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: process-${SNAPSHOT_NAME}-${TIMESTAMP}
  namespace: apps
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: processor
        image: ghcr.io/bryanlabs/cosmos-snapshotter:latest
        command:
        - /bin/bash
        - -c
        - |
          set -euo pipefail
          
          # Get block height
          if [ -f "/snapshot/data/priv_validator_state.json" ]; then
            BLOCK_HEIGHT=\$(jq -r '.height // "0"' /snapshot/data/priv_validator_state.json)
          else
            BLOCK_HEIGHT="unknown"
          fi
          
          echo "Block height: \$BLOCK_HEIGHT"
          
          # Get data size
          DATA_SIZE=\$(du -sb /snapshot/data 2>/dev/null | cut -f1 || echo "0")
          echo "Data size: \$(numfmt --to=iec-i --suffix=B \$DATA_SIZE)"
          
          # Run cosmprund if configured
          if [ "${ENABLE_PRUNING:-false}" == "true" ]; then
            echo "Running cosmprund..."
            cosmprund prune /snapshot/data \
              --blocks ${PRUNE_BLOCKS:-1000} \
              --versions ${PRUNE_VERSIONS:-1000}
          fi
          
          # Create tar.lz4 archive
          echo "Creating archive..."
          cd /snapshot
          DIRS="data"
          [ -d "wasm" ] && DIRS="\$DIRS wasm"
          
          tar cf - \$DIRS | lz4 -9 > /tmp/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4
          
          # Calculate checksum
          sha256sum /tmp/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4 > /tmp/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4.sha256
          
          # Get compressed size
          COMPRESSED_SIZE=\$(stat -c%s /tmp/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4)
          
          # Create metadata
          cat > /tmp/metadata.json <<JSON
          {
            "chain_id": "${CHAIN_ID}",
            "snapshot_name": "${SNAPSHOT_NAME}",
            "block_height": "\$BLOCK_HEIGHT",
            "timestamp": "\$(date -u +%Y-%m-%dT%H:%M:%SZ)",
            "data_size_bytes": \$DATA_SIZE,
            "compressed_size_bytes": \$COMPRESSED_SIZE,
            "compression_ratio": \$(echo "scale=2; \$DATA_SIZE / \$COMPRESSED_SIZE" | bc),
            "sha256": "\$(cut -d' ' -f1 /tmp/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4.sha256)"
          }
JSON
          
          # Upload to MinIO
          mc alias set snapshots "http://${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}"
          
          # Upload files
          mc cp /tmp/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4 snapshots/${MINIO_BUCKET}/${CHAIN_ID}/
          mc cp /tmp/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4.sha256 snapshots/${MINIO_BUCKET}/${CHAIN_ID}/
          mc cp /tmp/metadata.json snapshots/${MINIO_BUCKET}/${CHAIN_ID}/${CHAIN_ID}-\$BLOCK_HEIGHT.json
          
          # Update latest symlinks
          mc cp snapshots/${MINIO_BUCKET}/${CHAIN_ID}/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4 \
            snapshots/${MINIO_BUCKET}/${CHAIN_ID}/latest.tar.lz4
          mc cp snapshots/${MINIO_BUCKET}/${CHAIN_ID}/${CHAIN_ID}-\$BLOCK_HEIGHT.tar.lz4.sha256 \
            snapshots/${MINIO_BUCKET}/${CHAIN_ID}/latest.tar.lz4.sha256
          mc cp snapshots/${MINIO_BUCKET}/${CHAIN_ID}/${CHAIN_ID}-\$BLOCK_HEIGHT.json \
            snapshots/${MINIO_BUCKET}/${CHAIN_ID}/latest.json
          
          # Mark as processed
          echo "${SNAPSHOT_NAME}" | mc pipe snapshots/${MINIO_BUCKET}/${CHAIN_ID}/.processed/${SNAPSHOT_NAME}
          
          echo "Snapshot processing completed successfully!"
        env:
        - name: MINIO_ENDPOINT
          value: "${MINIO_ENDPOINT}"
        - name: MINIO_BUCKET
          value: "${MINIO_BUCKET}"
        - name: MINIO_ACCESS_KEY
          value: "${MINIO_ACCESS_KEY}"
        - name: MINIO_SECRET_KEY
          value: "${MINIO_SECRET_KEY}"
        - name: ENABLE_PRUNING
          value: "${ENABLE_PRUNING:-true}"
        - name: PRUNE_BLOCKS
          value: "${PRUNE_BLOCKS:-1000}"
        - name: PRUNE_VERSIONS
          value: "${PRUNE_VERSIONS:-1000}"
        volumeMounts:
        - name: snapshot
          mountPath: /snapshot
          readOnly: true
        resources:
          requests:
            cpu: 2
            memory: 8Gi
          limits:
            cpu: 4
            memory: 16Gi
      volumes:
      - name: snapshot
        persistentVolumeClaim:
          claimName: snapshot-pvc-${TIMESTAMP}
EOF

# Create the job
kubectl apply -f job.yaml

# Wait for job to complete
echo "Waiting for processing job to complete..."
kubectl wait --for=condition=complete "job/process-${SNAPSHOT_NAME}-${TIMESTAMP}" -n apps --timeout=3600s

# Cleanup
echo "Cleaning up resources..."
kubectl delete job "process-${SNAPSHOT_NAME}-${TIMESTAMP}" -n apps
kubectl delete pvc "snapshot-pvc-${TIMESTAMP}" -n apps

# Clean up working directory
cd /
rm -rf "$WORKDIR"

echo "[$(date)] Completed processing snapshot $SNAPSHOT_NAME"