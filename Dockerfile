FROM golang:1.22-alpine AS builder

# Build cosmprund for snapshot pruning
RUN apk add --no-cache git make gcc musl-dev
RUN git clone https://github.com/binaryholdings/cosmprund /cosmprund && \
    cd /cosmprund && \
    go build -o /usr/local/bin/cosmprund .

FROM alpine:3.19

LABEL org.opencontainers.image.source=https://github.com/bryanlabs/cosmos-snapshotter

# Install required tools
RUN apk add --no-cache \
    bash \
    lz4 \
    jq \
    curl \
    bc \
    tar \
    ca-certificates

# Install kubectl
RUN wget https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Install MinIO client
RUN wget https://dl.min.io/client/mc/release/linux-amd64/mc && \
    chmod +x mc && \
    mv mc /usr/local/bin/

# Copy cosmprund from builder
COPY --from=builder /usr/local/bin/cosmprund /usr/local/bin/cosmprund

# Copy scripts
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# Create non-root user
RUN adduser -D -u 1000 snapshots
USER snapshots

ENTRYPOINT ["/bin/bash"]