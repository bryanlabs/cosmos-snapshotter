# Cosmos Snapshotter

Automated tool for processing Kubernetes VolumeSnapshots of Cosmos blockchain nodes, creating compressed archives, and uploading them to MinIO object storage.

## Features

- Finds VolumeSnapshots in Kubernetes cluster
- Creates PVCs from snapshots for processing
- Optionally prunes data using cosmprund
- Compresses to tar.lz4 format
- Uploads to MinIO with metadata
- Tracks processed snapshots to avoid duplicates
- Cleans up old snapshots based on retention policy

## Scripts

- `process-snapshots.sh` - Main script that finds and processes all snapshots
- `process-single-snapshot.sh` - Processes a single snapshot
- `cleanup-old-snapshots.sh` - Removes old snapshots based on retention

## Environment Variables

- `MINIO_ENDPOINT` - MinIO server endpoint (default: minio-snapshots:9000)
- `MINIO_BUCKET` - Bucket name (default: snapshots)
- `MINIO_ACCESS_KEY` - MinIO access key
- `MINIO_SECRET_KEY` - MinIO secret key
- `ENABLE_PRUNING` - Enable cosmprund pruning (default: true)
- `PRUNE_BLOCKS` - Number of blocks to keep (default: 1000)
- `PRUNE_VERSIONS` - Number of versions to keep (default: 1000)
- `KEEP_LAST` - Number of snapshots to keep per chain (default: 5)

## Docker Image

```bash
docker build -t ghcr.io/bryanlabs/cosmos-snapshotter:latest .
docker push ghcr.io/bryanlabs/cosmos-snapshotter:latest
```

## Usage in Kubernetes

See the [bare-metal](https://github.com/bryanlabs/bare-metal) repository for Kubernetes deployment manifests.