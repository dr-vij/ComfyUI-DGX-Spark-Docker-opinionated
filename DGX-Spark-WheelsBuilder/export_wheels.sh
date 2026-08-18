#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${ROOT_DIR}/Wheels"
IMAGE_TAG="${IMAGE_TAG:-dgx-spark-wheelsbuilder}"

mkdir -p "$OUTPUT_DIR"

docker buildx build --progress=plain \
    -t "$IMAGE_TAG" \
    -o type=local,dest="$OUTPUT_DIR" \
    "$ROOT_DIR"
