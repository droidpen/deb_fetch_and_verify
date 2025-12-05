#!/bin/bash
# check_deb31-fixed-reasoned.sh — SHA256 validation of .deb files with accurate stanza line reporting,
# clean CSV output (leakage fixed), and a 'reason' column explaining non-matches.

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <base-folder-with-deb-files>"
  exit 1
fi

INPUT_DIR="$1"
CACHE_DIR="./cache"
mkdir -p "$CACHE_DIR"
TEMP_DIR=$(mktemp -d -p /tmp checkdeb.XXXXXX)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PACKAGE_FILE="Packages"

# === minimal change: put logs & CSVs into a per-run metadata dir under INPUT_DIR ===
META_DIR="$INPUT_DIR/.verify_meta_${TIMESTAMP}"
mkdir -p "$META_DIR"

CSV_LOG="$META_DIR/verify_deb_${TIMESTAMP}.csv"
LOG_FILE="$META_DIR/verify_deb_${TIMESTAMP}.log"
GPG_WARN_FILE="$META_DIR/verify_gpg_failures_${TIMESTAMP}.txt"
# ================================================================================

exec > >(tee -a "$LOG_FILE") 2>&1

echo "Verifying .deb files in: $INPUT_DIR/"
echo "Metadata dir: $META_DIR"
echo "All downloaded Packages.gz will live under: $TEMP_DIR"
echo "------------------------------------------------------------"

# Optional retry path via env FORCE_SUITES (array)
FORCE_ONLY=(${FORCE_SUITES[@]:-})
GPG_FAILED_SUITES=()

if [ ${#FORCE_ONLY[@]} -eq 0 ]; then
  suites=(
    trusty trusty-updates trusty-security
    xenial xenial-updates xenial-security
    bionic bionic-updates bionic-security
    focal focal-updates focal-security
    jammy jammy-updates jammy-security
    kinetic kinetic-updates kinetic-security
    lunar lunar-updates lunar-security
    mantic mantic-updates mantic-security
    noble noble-updates noble-security
  )
else
  suites=("${FORCE_ONLY[@]}")
  echo -e "\e[36m▶ Retrying only forced GPG-failed suites: ${suites[*]}\e[0m"
fi

components=(main universe multiverse restricted)
ARCH=amd64

# Add 'reason' column
echo "folder,filename,package,version,architecture,sha256,match_found,suite/component,packages_txt_filename,match_start_line,reason" > "$CSV_LOG.unsorted"

# GPG pre-checks (only when not in forced-retry mode)
if [ ${#FORCE_ONLY[@]} -eq 0 ]; then
  for suite in "${suites[@]}"; do
    printf "▶ Verifying GPG for suite: %s…\n" "$suite"
    BASE_URL="https://archive.ubuntu.com/ubuntu/dists/$suite"
    RELEASE="$TEMP_DIR/Release"
    RELEASE_GPG="$TEMP_DIR/Release.gpg"

    if curl -fsSL "$BASE_URL/Release" -o "$RELEASE" &&
       curl -fsSL "$BASE_URL/Release.gpg" -o "$RELEASE_GPG"; then
      if gpgv --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg "$RELEASE_GPG" "$RELEASE"; then
        echo "✔"
      else
        echo "✖ GPG failed"
        GPG_FAILED_SUITES+=("$suite")
      fi
    else
      echo "✖ Missing Release or GPG files"
      GPG_FAILED_SUITES+=("$suite")
    fi
  done
fi

awk_escape() {
  sed 's/[][\/.^$*+?|(){}]/\\&/g' <<< "$1"
}

mapfile -t DEB_FILES < <(find "$INPUT_DIR" -type f -name "*.deb")

for DEB in "${DEB_FILES[@]}"; do
  [ -e "$DEB" ] || continue
  FILENAME=$(basename "$DEB")
  FOLDER=$(dirname "$DEB")
  echo ""
  echo "=== Checking: $FILENAME ==="

  PACKAGE=$(dpkg-deb -f "$DEB" Package)
  VERSION=$(dpkg-deb -f "$DEB" Version | tr -d '\r\n')
  ARCHITECTURE=$(dpkg-deb -f "$DEB" Architecture)
  SHA256=$(sha256sum "$DEB" | cut -d ' ' -f 1)

  echo "Package:   $PACKAGE"
  echo "Version:   $VERSION"
  hexdump -C <<< "$VERSION"
  echo "Arch:      $ARCHITECTURE"
  echo "SHA256:    $SHA256"

  MATCH_FOUND=0
  REASON=""

  # Keep regex-escaped (for info logs) BUT use raw values for awk equality matching
  PKG_RE=$(awk_escape "$PACKAGE")
  VER_RE=$(awk_escape "$VERSION")
  HASH_RE=$(awk_escape "$SHA256")

  [[ "$PACKAGE" != "$PKG_RE" ]] && echo -e "\e[33m[WARN] PACKAGE needs escaping: $PACKAGE => $PKG_RE\e[0m"
  [[ "$VERSION" != "$VER_RE" ]] && echo -e "\e[33m[WARN] VERSION needs escaping: $VERSION => $VER_RE\e[0m"
  [[ "$SHA256" != "$HASH_RE" ]] && echo -e "\e[33m[WARN] HASH needs escaping: $SHA256 => $HASH_RE\e[0m"

  # Raw (exact) values for safe cross-awk comparison
  PKG_EQ="$PACKAGE"
  VER_EQ="$VERSION"
  HASH_EQ="$SHA256"

  # Track what content we actually scanned (for reasons)
  PLAIN_FILES=()
  ANY_PLAIN_OK=0
  PKG_SEEN=0
  PKGVER_SEEN=0

  for suite in "${suites[@]}"; do
    # Skip suites that failed GPG (unless forcing)
    if [ ${#FORCE_ONLY[@]} -eq 0 ] && [[ " ${GPG_FAILED_SUITES[*]} " =~ " $suite " ]]; then
      continue
    fi

    for comp in "${components[@]}"; do
      REL_PATH="${comp}/binary-${ARCH}/Packages.gz"
      URL="https://archive.ubuntu.com/ubuntu/dists/${suite}/${REL_PATH}"
      DEST="$CACHE_DIR/${suite}-${comp}-Packages.gz"

      if [ ! -f "$DEST" ]; then
        echo -n "-> Downloading: $URL … "
        curl -fsSL "$URL" -o "$DEST" && echo "✔" || { echo "✖ (skipped)"; continue; }
      fi

      echo -n "   ↳ Decompressing… "
      if gunzip -fc "$DEST" > "$TEMP_DIR/${suite}-${comp}-Packages" 2>/dev/null; then
        PLAIN="$TEMP_DIR/${suite}-${comp}-Packages"
        ANY_PLAIN_OK=1
        PLAIN_FILES+=("$PLAIN")
        echo "✔"
      else
        echo "✖ (corrupted, retrying)"
        rm -f "$DEST"
        curl -fsSL "$URL" -o "$DEST" &&
        gunzip -fc "$DEST" > "$TEMP_DIR/${suite}-${comp}-Packages" 2>/dev/null &&
        { echo "   ↳ Re-decompression OK ✔"; PLAIN="$TEMP_DIR/${suite}-${comp}-Packages"; ANY_PLAIN_OK=1; PLAIN_FILES+=("$PLAIN"); } || continue
      fi

      echo -e "   ↳ Scanning ${suite}/${comp}… \n"

      # === PATCH: exact equality match inside stanza; no regex with user data ===
      MATCH_LINE=$(LC_ALL=C awk -v pkg="$PKG_EQ" -v ver="$VER_EQ" -v hash="$HASH_EQ" '
        BEGIN {
          pkg_match=ver_match=hash_match=0;
          stanza_start=1;
          printed=0;
        }
        {
          gsub(/\r/, "");  # normalize CRLF
        }
        /^$/ {
          if (!printed && pkg_match && ver_match && hash_match) {
            print stanza_start;
            printed=1;
          }
          pkg_match=ver_match=hash_match=0;
          stanza_start = NR + 1;
          next;
        }
        # Exact comparisons (no regex interpolation)
        /^Package:[[:space:]]+/ {
          v=$0; sub(/^Package:[[:space:]]+/, "", v);
          if (v==pkg) pkg_match=1;
          next;
        }
        /^Version:[[:space:]]+/ {
          v=$0; sub(/^Version:[[:space:]]+/, "", v);
          if (v==ver) ver_match=1;
          next;
        }
        /^SHA256:[[:space:]]+/ {
          v=$0; sub(/^SHA256:[[:space:]]+/, "", v);
          if (v==hash) hash_match=1;
          next;
        }
        END {
          if (!printed && pkg_match && ver_match && hash_match) {
            print stanza_start;
          }
        }
      ' "$PLAIN" || true)
      # === END PATCH ===

      if [ -n "$MATCH_LINE" ]; then
        echo -e "\e[32m✔ MATCH FOUND in ${suite}/${comp} at line $MATCH_LINE\e[0m"
        cp "$DEST" "$FOLDER/Packages_${suite}_${comp}.gz"
        cp "$PLAIN" "$FOLDER/Packages_${suite}_${comp}.txt"
        echo "$FOLDER,$FILENAME,$PACKAGE,$VERSION,$ARCHITECTURE,$SHA256,yes,${suite}/${comp},Packages_${suite}_${comp}.txt,$MATCH_LINE," >> "$CSV_LOG.unsorted"
        MATCH_FOUND=1
        break 2
      else
        echo "no match - pkg=0, ver=0, hash=0"
      fi
    done
  done

  # If not matched, derive a REASON with minimal extra scans (mawk-safe).
  if [ "$MATCH_FOUND" -eq 0 ]; then
    if [ "$ANY_PLAIN_OK" -eq 0 ]; then
      if [ ${#GPG_FAILED_SUITES[@]} -gt 0 ] && [ ${#FORCE_ONLY[@]} -eq 0 ]; then
        REASON="gpg_failed_suite_skipped"
      else
        REASON="packages_file_missing_for_suite"
      fi
    else
      # We have some PLAIN_FILES; check progressively for pkg and pkg+ver occurrences (exact match).
      for PLAIN in "${PLAIN_FILES[@]}"; do
        # Package present anywhere?
        if LC_ALL=C awk -v pkg="$PKG_EQ" '
          { gsub(/\r/,"") }
          /^Package:[[:space:]]+/ { v=$0; sub(/^Package:[[:space:]]+/,"",v); if (v==pkg) { exit 0 } }
          END { exit 1 }
        ' "$PLAIN"; then
          PKG_SEEN=1
        fi

        # Package + Version present in SAME stanza?
        if LC_ALL=C awk -v pkg="$PKG_EQ" -v ver="$VER_EQ" '
          BEGIN{pkg_match=ver_match=0}
          { gsub(/\r/,"") }
          /^$/ {
            if (pkg_match && ver_match) { print 1; exit 0 }
            pkg_match=ver_match=0; next
          }
          /^Package:[[:space:]]+/ { v=$0; sub(/^Package:[[:space:]]+/,"",v); if (v==pkg) pkg_match=1; next }
          /^Version:[[:space:]]+/ { v=$0; sub(/^Version:[[:space:]]+/,"",v); if (v==ver)  ver_match=1;  next }
          END { if (pkg_match && ver_match) exit 0; else exit 1 }
        ' "$PLAIN"; then
          PKGVER_SEEN=1
        fi
      done

      if [ "$PKGVER_SEEN" -eq 1 ]; then
        REASON="sha256_not_found_but_pkgver_present"
      elif [ "$PKG_SEEN" -eq 1 ]; then
        REASON="version_not_in_packages"
      else
        REASON="not_found_in_checked_packages"
      fi
    fi

    echo "Package/version/sha256 not found in any Packages.gz (reason: $REASON)"
    echo "$FOLDER,$FILENAME,$PACKAGE,$VERSION,$ARCHITECTURE,$SHA256,no,,,,$REASON" >> "$CSV_LOG.unsorted"
  fi
done

# Sort CSV by folder
{ head -n 1 "$CSV_LOG.unsorted"; tail -n +2 "$CSV_LOG.unsorted" | sort; } > "$CSV_LOG"
rm "$CSV_LOG.unsorted"

# Post-run: handle GPG-failed suites (only when not already forcing)
if [ ${#GPG_FAILED_SUITES[@]} -gt 0 ] && [ ${#FORCE_ONLY[@]} -eq 0 ]; then
  echo "✖ GPG failed for the following suites:" | tee "$GPG_WARN_FILE"
  printf '%s\n' "${GPG_FAILED_SUITES[@]}" | tee -a "$GPG_WARN_FILE"
  echo ""
  echo -n "▶ Retry using these failed suites? (y/N) [Timeout 10s]: "
  read -t 10 -n 1 answer || true
  echo ""
  if [[ "$answer" =~ [Yy] ]]; then
    echo "Re-running only failed suites..."
    FORCE_SUITES=("${GPG_FAILED_SUITES[@]}") exec "$0" "$INPUT_DIR"
  else
    echo "Skipped. Exiting."
  fi
fi

pushd $INPUT_DIR
dpkg-scanpackages . > $PACKAGE_FILE
gzip -k $PACKAGE_FILE
popd


echo ""
echo "Verification complete"
echo "Temp files: $TEMP_DIR"
echo "CSV log: $CSV_LOG"
echo "Log file: $LOG_FILE"
echo "GPG failures (if any): $GPG_WARN_FILE"
echo "Packages scanned into $PACKAGE_FILE.gz"


