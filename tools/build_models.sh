#!/usr/bin/env bash
# Converts the PyTorch weights to Core ML and compiles them to .mlmodelc for the app bundle.
#   tools/build_models.sh            # convert + compile (compile step needs macOS / Xcode)
#   SKIP_COMPILE=1 tools/build_models.sh
set -euo pipefail
cd "$(dirname "$0")/.."

python3 tools/convert_models.py --weights weights --out build/mlpackages

if [[ "${SKIP_COMPILE:-0}" == "1" ]]; then
  exit 0
fi

rm -rf build/Models
mkdir -p build/Models
for package in build/mlpackages/*.mlpackage; do
  xcrun coremlcompiler compile "$package" build/Models
done
ls -la build/Models
