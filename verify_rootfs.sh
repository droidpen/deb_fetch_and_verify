#!/bin/bash
set -euo pipefail

show_help() {
#heredoc: indentation must be TAB, not whitespaces.
cat << EOF
Usage: $0 [options] <directory-containing-rootfs-and-sums>

Options:
  -h, --help        Show more detailed help

Description:
  This script verifies a rootfs against its checksum files.
  You must pass the directory that contains both the rootfs
  and the corresponding checksum files.
  Example:
  ubuntu_22.04.03/
  ├── SHA256SUMS
  ├── SHA256SUMS.gpg
  └── ubuntu-base-22.04.3-base-arm64.tar.gz

EOF
}

# === Step 0: Argument check ===
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <directory-containing-rootfs-and-sums>"
    echo "Try '$0 --help' for more information."
    exit 1
fi

# === Step 0.1: Check for --help ===
case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
esac

DOWNLOAD_DIR="$1"
cd "$DOWNLOAD_DIR"

# === Step 1: Setup logging ===
DATETIME=$(date '+%Y%m%d_%H%M%S')

# Minimal change: put artifacts under a per-run meta dir
META_DIR=".meta_verify_rootfs_${DATETIME}"
mkdir -p "$META_DIR"

LOGFILE="${META_DIR}/verify_rootfs_${DATETIME}.log"
CSVFILE="${META_DIR}/verify_rootfs_${DATETIME}.csv"

exec > >(tee "$LOGFILE") 2>&1

# === Step 2: Constants ===
SUMS="SHA256SUMS"
SUMS_GPG="SHA256SUMS.gpg"
KEYRING_SYS="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
# Minimal change: download Canonical keyring into meta dir
KEYRING_DL="${META_DIR}/ubuntu.gpg"

echo "Working directory: $DOWNLOAD_DIR"
echo "Meta dir: $META_DIR"
echo "Log file: $LOGFILE"
echo "CSV output: $CSVFILE"
echo

# === Step 3: Ensure required files exist ===
for f in "$SUMS" "$SUMS_GPG"; do
    if [[ ! -f "$f" ]]; then
        echo "Missing file: $f"
        exit 1
    fi
done

# === Step 4: Ensure system keyring is installed ===
if [[ ! -f "$KEYRING_SYS" ]]; then
    echo "Installing ubuntu-archive-keyring..."
    sudo apt-get update
    sudo apt-get install -y ubuntu-archive-keyring
fi

# === Step 5: Download Canonical keyring ===
echo "Downloading Canonical keyring..."
curl -fsSLo "$KEYRING_DL" "https://archive.ubuntu.com/ubuntu/project/ubuntu-archive-keyring.gpg"

# === Step 6: Compare key fingerprints ===
echo "Verifying key fingerprints..."

MISSING_KEYS=$(gpg --quiet --with-colons --no-default-keyring --keyring "$KEYRING_DL" --list-keys 2>/dev/null \
  | awk -F: '$1 == "fpr" { print $10 }' \
  | xargs -I{} sh -c "gpg --no-default-keyring --keyring '$KEYRING_SYS' --list-keys {} >/dev/null 2>&1 || echo {}")

if [[ -n "$MISSING_KEYS" ]]; then
    echo "✖ Some keys from Canonical are NOT in the trusted system keyring:"
    echo "$MISSING_KEYS"
    exit 1
else
    echo "✔ All fingerprints match."
fi

# === Step 7: Verify signature ===
echo "Verifying GPG signature..."
if gpgv --keyring "$KEYRING_SYS" "$SUMS_GPG" "$SUMS"; then
    echo "SHA256SUMS signature verified."
else
    echo "Signature verification FAILED!"
    exit 1
fi

# === Step 8: Check all .tar.gz files listed in SHA256SUMS ===
echo "Checking .tar.gz files..."
echo "filename,status,message" > "$CSVFILE"

FOUND_ANY=false
FAILED_ANY=false

for file in *.tar.gz; do
    [[ -f "$file" ]] || continue

    # Grep for filename at line end, allowing optional asterisk
    if grep -Eq -- "\*?$file\$" "$SUMS"; then
        echo "Verifying: $file"
        if sha256sum -c --ignore-missing "$SUMS" 2>&1 | grep -qF "$file: OK"; then
            echo "$file: SHA256 OK"
            echo "$file,OK,Verified successfully" >> "$CSVFILE"
            FOUND_ANY=true
        else
            echo "$file: Checksum mismatch!"
            echo "$file,FAIL,Checksum mismatch" >> "$CSVFILE"
            FAILED_ANY=true
        fi
    else
        echo "$file: Not listed in SHA256SUMS, skipping"
        echo "$file,SKIP,Not listed in SHA256SUMS" >> "$CSVFILE"
    fi
done

# === Final Summary ===
if ! $FOUND_ANY; then
    echo "No matching .tar.gz files found in SHA256SUMS."
    exit 1
fi

if $FAILED_ANY; then
    echo "One or more files failed verification."
    exit 1
else
    echo "All matching .tar.gz files verified successfully."
    echo "Artifacts saved under: $META_DIR/"
fi
