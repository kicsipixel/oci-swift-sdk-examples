#!/usr/bin/env bash
# Builds the BucketRelay image for the architecture of your chosen shape and
# pushes it to the public registry named in config.env ($IMAGE).
# You must be logged into that registry (e.g. `docker login`) with push rights.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/config.env"

case "$SHAPE" in
  *A1*)  PLATFORM="linux/arm64" ;;   # Ampere
  *)     PLATFORM="linux/amd64" ;;   # E4 / x86
esac

echo "==> docker build ($PLATFORM) -> $IMAGE"
docker build --platform "$PLATFORM" -t "$IMAGE" "$here/.."

echo "==> docker push $IMAGE"
docker push "$IMAGE"

echo ""
echo "Pushed $IMAGE. Make sure the repository is PUBLIC so the container instance can pull it"
echo "anonymously (otherwise you must attach an image-pull secret in 3-deploy.sh)."
