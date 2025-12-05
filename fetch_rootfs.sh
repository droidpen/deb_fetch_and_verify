#!/bin/bash
# Fetch an Ubuntu Base rootfs tarball + SHA256SUMS + SHA256SUMS.gpg
# for a specific release (e.g., 20.04.5, 22.04.3) and architecture (amd64|arm64).
#
# If you pass only MAJOR.MINOR (e.g., 20.04), the script will discover the latest
# point release (e.g., 20.04.6) from the official index.
#
# Usage:
#   ./fetch_rootfs.sh 20.04.5 arm64 [base-dir]
#   ./fetch_rootfs.sh 22.04 amd64 [base-dir]      # auto-picks latest 22.04.x
#
# Default base-dir: ./rootfs_dl
# Destination created as: <base-dir>/<resolved_release>_<arch>
#
# After download, verify with your verifier:
#   ./verify_rootfs.sh "<base-dir>/<resolved_release>_<arch>"

set -euo pipefail

usage() {
  cat <<EOF
Usage:
  $0 <release> <arch> [base-dir]

Positional arguments:
  <release>   Ubuntu point release (e.g. 20.04.5, 22.04.3)
              Or MAJOR.MINOR (e.g. 20.04) to auto-pick latest point release (20.04.x).
  <arch>      Architecture: amd64 | arm64 (aliases: x86_64->amd64, aarch64->arm64)
  [base-dir]  Optional base directory. Default: ./rootfs_dl

Notes:
- Downloads from:
    https://cdimage.ubuntu.com/ubuntu-base/releases/<resolved_release>/release/
- Files fetched into: <base-dir>/<resolved_release>_<arch>/
    ubuntu-base-<resolved_release>-base-<arch>.tar.gz
    SHA256SUMS
    SHA256SUMS.gpg
EOF
}

if [[ $# -lt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

RELEASE_RAW="$1"
ARCH_IN="$2"
BASE_DIR="${3:-./rootfs_dl}"

# --- arch normalization ---
case "${ARCH_IN,,}" in
  amd64|x86_64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *)
    echo "Unsupported arch: $ARCH_IN (use amd64 or arm64)" >&2
    exit 2
    ;;
esac

# --- resolve release (support MAJOR.MINOR -> latest point release) ---
resolve_release() {
  local input="$1"

  # If it's already MAJOR.MINOR.PATCH, keep as-is
  if [[ "$input" =~ ^[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]]; then
    printf "%s" "$input"
    return 0
  fi

  # If it's MAJOR.MINOR, scrape index to find highest MAJOR.MINOR.x
  if [[ "$input" =~ ^[0-9]{2}\.[0-9]{2}$ ]]; then
    local base="https://cdimage.ubuntu.com/ubuntu-base/releases/"
    echo "Discovering latest point release for $input …"
    # Grab the index and extract versions like 20.04.1, 20.04.6, etc.
    # Then keep only those that start with "<input>." and sort -V to pick the highest.
    local latest
    latest="$(
      curl -fsSL "$base" \
        | grep -oE '>[0-9]{2}\.[0-9]{2}\.[0-9]+/' \
        | tr -d '>/ ' \
        | grep -E "^${input}\.[0-9]+$" \
        | sort -V \
        | tail -n 1
    )" || true

    if [[ -z "$latest" ]]; then
      echo "Could not discover a point release for $input at $base" >&2
      exit 3
    fi
    printf "%s" "$latest"
    return 0
  fi

  echo "Release must be MAJOR.MINOR or MAJOR.MINOR.PATCH, got: $input" >&2
  exit 2
}

RELEASE="$(resolve_release "$RELEASE_RAW")"

# --- destination dir = base dir + subfolder ---
DEST="$BASE_DIR/${RELEASE}_${ARCH}"
mkdir -p "$DEST"

BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${RELEASE}/release"
TARBALL="ubuntu-base-${RELEASE}-base-${ARCH}.tar.gz"
SUMS="SHA256SUMS"
SUMS_GPG="SHA256SUMS.gpg"

echo "Resolved release: ${RELEASE}  (requested: ${RELEASE_RAW})"
echo "Arch:             ${ARCH}"
echo "Source URL:       ${BASE_URL}/"
echo "Base dir:         ${BASE_DIR}"
echo "Destination:      ${DEST}"
echo "--------------------------------------------------"

# --- quick URL existence checks (HEAD) ---
curl -fsI "${BASE_URL}/${TARBALL}"    >/dev/null || { echo "Not found: ${BASE_URL}/${TARBALL}"; exit 4; }
curl -fsI "${BASE_URL}/${SUMS}"       >/dev/null || { echo "Not found: ${BASE_URL}/${SUMS}"; exit 4; }
curl -fsI "${BASE_URL}/${SUMS_GPG}"   >/dev/null || { echo "Not found: ${BASE_URL}/${SUMS_GPG}"; exit 4; }

# --- download ---
pushd "$DEST" >/dev/null
echo "Downloading files into: $(pwd)"

download_one() {
  local url="$1"; local fname="$2"
  if [[ -f "$fname" ]]; then
    echo "✔ Exists: $fname"
  else
    echo "↳ Fetch:  $fname"
    curl -fL --remote-time -o "$fname" "$url"
  fi
}

download_one "${BASE_URL}/${TARBALL}"  "${TARBALL}"
download_one "${BASE_URL}/${SUMS}"     "${SUMS}"
download_one "${BASE_URL}/${SUMS_GPG}" "${SUMS_GPG}"

popd >/dev/null

echo ""
echo "Done."
echo "Next: verify the rootfs against the signed checksums:"
echo "  ./verify_rootfs.sh \"$DEST\""
