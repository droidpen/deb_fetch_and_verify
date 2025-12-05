#!/bin/bash
# Fetch .deb files using the CURRENT system APT config (apt-rdepends),
# save them under per-seed subfolders, and record provenance with minimal clutter.
#
# Per-run suite inventory derived from apt-cache policy:
#   - ${META_DIR}/suites_by_pkg_${TAG}.csv   (package,version,suite,codename,component,origin)
#   - ${META_DIR}/suites_${TAG}.txt          (unique "<suite>-<component>" like "jammy-main")
#
# Usage (seed packages ... then download-dir):
#   ./fetch_debs_with_provenance.sh binfmt-support make qemu-user-static ./dl
#   ./fetch_debs_with_provenance.sh --tag jammy --provenance min binfmt-support coreutils ./dl
#
# Requires: apt-rdepends, apt-get, apt-cache, dpkg-deb, sha256sum

set -euo pipefail

usage() {
  cat <<EOF
Usage:
  $0 [options] <seed1> [seed2 ...] <download-dir>

Options:
  --tag NAME            Group outputs under .fetch_meta_NAME (reusable). Default: timestamp.
  --provenance MODE     'full' (default) or 'min'.
                        full: sources snapshot, overall policy, per-package policy files, sources lines
                        min:  sources lines + overall policy only; no per-package policy files, no sources snapshot
  --meta-inline         Keep metadata files in <download-dir> root (legacy style). Default: off.
  -h, --help            Show help

Examples:
  $0 binfmt-support make ./test
  $0 --tag jammy --provenance min binfmt-support jq ./test
  $0 --meta-inline curl wget ./dl
EOF
}

# --- defaults / flags ---
TAG=""
PROVENANCE_MODE="full"   # full|min
META_INLINE=0

# --- parse flags ---
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --provenance) PROVENANCE_MODE="${2:-}"; shift 2 ;;
    --meta-inline) META_INLINE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *)
      ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"  # remaining positionals

# --- required args: at least 2 (seeds..., dir) ---
if [[ $# -lt 2 ]]; then
  usage; exit 1
fi

# Last positional is the download dir; the rest are seed packages
INPUT_DIR="${@: -1}"
readarray -t PKG_SEEDS < <(printf '%s\n' "${@:1:$#-1}")

# If user passed a single quoted string with spaces, split it into tokens too
if [[ ${#PKG_SEEDS[@]} -eq 1 && "$PKG_SEEDS" == *" "* ]]; then
  read -r -a PKG_SEEDS <<< "$PKG_SEEDS"
fi

# Normalize INPUT_DIR to absolute path
if command -v realpath >/dev/null 2>&1; then
  INPUT_DIR="$(realpath -m "$INPUT_DIR")"
else
  INPUT_DIR="$(cd "$INPUT_DIR" 2>/dev/null && pwd -P || echo "$INPUT_DIR")"
fi
mkdir -p "$INPUT_DIR"

# Tools
if ! command -v apt-rdepends >/dev/null 2>&1; then
  echo "Error: apt-rdepends is not installed. Please install it and re-run." >&2
  exit 2
fi

# Timestamp / tag
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
if [[ -z "$TAG" ]]; then
  TAG="$TIMESTAMP"
fi

# Decide metadata location (ensure it exists before logging)
if [[ "$META_INLINE" -eq 1 ]]; then
  META_DIR="$INPUT_DIR"
else
  META_DIR="$INPUT_DIR/.fetch_meta_${TAG}"
fi
mkdir -p "$META_DIR"

# Log (put logs in meta dir so the deb folder stays clean)
LOG_FILE="$META_DIR/fetch_debs_${TAG}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Fetch using current system APT environment ==="
echo "Seed packages:  ${PKG_SEEDS[*]}"
echo "Download dir:    $INPUT_DIR"
echo "Meta dir:        $META_DIR"
echo "Tag:             $TAG"
echo "Provenance:      $PROVENANCE_MODE"
echo "Timestamp:       $TIMESTAMP"
echo "--------------------------------------------------"

# Host env facts
DISTRO="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME $VERSION}")"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
KERNEL="$(uname -sr)"
ARCH="$(dpkg --print-architecture || true)"

# Provenance: always write the flattened sources lines + overall policy summary
SOURCES_TXT="$META_DIR/apt_sources_lines_${TAG}.txt"
echo "▶ Capturing enabled APT sources → $(basename "$SOURCES_TXT")"
{
  echo "# 'deb' lines snapshot (time: $TIMESTAMP)"
  echo "# Host: $(hostname) | Distro: $DISTRO | Codename: $CODENAME | Kernel: $KERNEL | Arch: $ARCH"
  grep -RhsE '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
} > "$SOURCES_TXT"

POLICY_SUMMARY="$META_DIR/apt_policy_summary_${TAG}.txt"
echo "▶ Saving 'apt-cache policy' summary → $(basename "$POLICY_SUMMARY")"
apt-cache policy > "$POLICY_SUMMARY" || true

# Optional: sources snapshot + per-package policy files (full mode only)
SNAP_DIR=""
PKG_POLICY_DIR=""
if [[ "$PROVENANCE_MODE" == "full" ]]; then
  SNAP_DIR="$META_DIR/sources_snapshot_${TAG}"
  mkdir -p "$SNAP_DIR"
  echo "▶ Copying /etc/apt/sources files → $(basename "$SNAP_DIR")/"
  cp -a /etc/apt/sources.list "$SNAP_DIR/" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "$SNAP_DIR/" 2>/dev/null || true

  PKG_POLICY_DIR="$META_DIR/policy_by_pkg_${TAG}"
  mkdir -p "$PKG_POLICY_DIR"
fi

# Suite inventory outputs
SUITES_BY_PKG="$META_DIR/suites_by_pkg_${TAG}.csv"
ALL_SUITES_TMP="$META_DIR/.suites_tmp_${TAG}.txt"
if [[ ! -f "$SUITES_BY_PKG" ]]; then
  printf "package,version,suite,codename,component,origin\n" > "$SUITES_BY_PKG"
fi
: > "$ALL_SUITES_TMP"

# Manifest (single file per tag; append if exists)
MANIFEST="$META_DIR/fetch_manifest_${TAG}.csv"
if [[ ! -f "$MANIFEST" ]]; then
  printf "filename,package,version,architecture,sha256,candidate_version,policy_file\n" > "$MANIFEST"
fi

# Helper: parse a repo line under "Version table:" that contains an HTTP(S) URL
parse_policy_line() {
  local pkg="$1" policy_file="$2"
  if [[ -n "$policy_file" && -s "$policy_file" ]]; then
    cat "$policy_file"
  else
    apt-cache policy "$pkg" 2>/dev/null || true
  fi | awk '
    BEGIN{vt=0}
    /^  Version table:/{vt=1; next}
    vt && /^[[:space:]]*[0-9]+[[:space:]]+https?:\/\// {print; exit}
  '
}

# === MAIN: per-SEED loop (each seed gets its own subfolder) ===
for seed in "${PKG_SEEDS[@]}"; do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "▶ Seed: $seed"
  CUR_SEED_DIR="$INPUT_DIR/$seed"
  mkdir -p "$CUR_SEED_DIR"

  # Resolve the seed's dependency set (including itself)
  echo "↳ Resolving deps for $seed with apt-rdepends…"
  mapfile -t PKG_SET < <(apt-rdepends "$seed" 2>/dev/null \
    | awk '/^[A-Za-z0-9][A-Za-z0-9.+-]*$/{print}' \
    | sort -u)

  if [[ ${#PKG_SET[@]} -eq 0 ]]; then
    echo "  (warning) No packages resolved for seed '$seed' — skipping."
    continue
  fi

  # Download each package into THIS seed's folder
  pushd "$CUR_SEED_DIR" >/dev/null

  for pkg in "${PKG_SET[@]}"; do
    echo ""
    echo "=== $seed :: $pkg ==="

    # Per-package policy file only in full mode (kept in meta dir)
    POLICY_FILE=""
    if [[ "$PROVENANCE_MODE" == "full" ]]; then
      POLICY_FILE="$PKG_POLICY_DIR/${pkg}.policy.txt"
      mkdir -p "$(dirname "$POLICY_FILE")"
      echo "↳ Capturing 'apt-cache policy $pkg' → $(basename "$POLICY_FILE")"
      apt-cache policy "$pkg" > "$POLICY_FILE" 2>&1 || echo "  (warning) apt-cache policy failed for $pkg"
    fi

    # Candidate version
    CANDIDATE=""
    if [[ -n "$POLICY_FILE" && -s "$POLICY_FILE" ]]; then
      CANDIDATE="$(awk -F': ' '/^  Candidate:/{print $2; exit}' "$POLICY_FILE" 2>/dev/null || true)"
    else
      CANDIDATE="$(apt-cache policy "$pkg" 2>/dev/null | awk -F': ' '/^  Candidate:/{print $2; exit}')"
    fi
    [[ -z "${CANDIDATE:-}" ]] && CANDIDATE=""

    echo "↳ apt-get download $pkg (into $seed/)"
    if ! apt-get download "$pkg"; then
      echo "  (warning) apt-get download failed for $pkg — maybe virtual or not available" >&2
      continue
    fi

    # Find downloaded files for this package (in the seed folder)
    shopt -s nullglob
    FILES=()
    if [[ -n "$CANDIDATE" ]]; then
      FILES=( ./${pkg}_${CANDIDATE}_*.deb )
    fi
    if [[ ${#FILES[@]} -eq 0 ]]; then
      FILES=( ./${pkg}_*.deb )
    fi
    shopt -u nullglob

    if [[ ${#FILES[@]} -eq 0 ]]; then
      echo "  (warning) No .deb file located for $pkg after download" >&2
      continue
    fi

    # Parse policy info for suite/component/origin mapping
    url_line="$(parse_policy_line "$pkg" "${POLICY_FILE:-}")" || true
    suite=""; comp=""; origin=""; name=""
    if [[ -n "$url_line" ]]; then
      suitecomp="$(printf "%s\n" "$url_line" | awk '{print $3}')"
      suite="${suitecomp%%/*}"
      comp="${suitecomp##*/}"
      origin="$(printf "%s\n" "$url_line" | awk '{print $2}' | sed -E 's#^[a-z]+://##; s#/.*$##')"
      name="$(printf "%s\n" "$suite" | sed -E 's/-(updates|security|backports|proposed)$//')"
    fi
    if [[ -n "$suite" || -n "$comp" || -n "$origin" ]]; then
      printf "%s,%s,%s,%s,%s,%s\n" \
        "$pkg" "$CANDIDATE" "${suite:-}" "${name:-}" "${comp:-}" "${origin:-}" >> "$SUITES_BY_PKG"
      if [[ -n "$suite" && -n "$comp" ]]; then
        echo "${suite}-${comp}" >> "$ALL_SUITES_TMP"
      elif [[ -n "$suite" ]]; then
        echo "${suite}" >> "$ALL_SUITES_TMP"
      fi
    else
      echo "  (note) No suite parsed for $pkg@$CANDIDATE (local/virtual/held or non-HTTP source?)"
    fi

    # Record each file in the manifest (paths relative to INPUT_DIR)
    for file in "${FILES[@]}"; do
      [[ -f "$file" ]] || continue
      FILENAME="$(basename "$file")"
      PKGNAME="$(dpkg-deb -f "$file" Package 2>/dev/null || echo "$pkg")"
      VERSION="$(dpkg-deb -f "$file" Version 2>/dev/null || echo "${CANDIDATE:-}")"
      ARCHPKG="$(dpkg-deb -f "$file" Architecture 2>/dev/null || echo "")"
      SHA256="$(sha256sum "$file" | awk '{print $1}')"

      if command -v realpath >/dev/null 2>&1; then
        REL_DEB_PATH="$(realpath --relative-to="$INPUT_DIR" "$file" 2>/dev/null || echo "$seed/$FILENAME")"
        REL_POLICY_FILE=""
        if [[ "$PROVENANCE_MODE" == "full" && -n "${POLICY_FILE:-}" ]]; then
          REL_POLICY_FILE="$(realpath --relative-to="$INPUT_DIR" "$POLICY_FILE" 2>/dev/null || echo "$POLICY_FILE")"
        fi
      else
        REL_DEB_PATH="$seed/$FILENAME"
        REL_POLICY_FILE="$(basename "${POLICY_FILE:-}")"
      fi

      printf "%s,%s,%s,%s,%s,%s,%s\n" \
        "$REL_DEB_PATH" "$PKGNAME" "$VERSION" "$ARCHPKG" "$SHA256" "$CANDIDATE" "${REL_POLICY_FILE:-}" >> "$MANIFEST"
    done
  done

  popd >/dev/null   # leave seed folder
done

# Finalize unique suites list
sort -u "$ALL_SUITES_TMP" > "$META_DIR/suites_${TAG}.txt" || true
rm -f "$ALL_SUITES_TMP" 2>/dev/null || true

# High-level provenance summary (single file, per tag)
PROVENANCE="$META_DIR/PROVENANCE_${TAG}.txt"
{
  echo "Provenance for fetched .deb files"
  echo "Tag: $TAG"
  echo "Timestamp: $TIMESTAMP"
  echo "Host: $(hostname)"
  echo "Distro: $DISTRO"
  echo "Codename: $CODENAME"
  echo "Kernel: $KERNEL"
  echo "Architecture: $ARCH"
  echo ""
  echo "Artifacts in meta dir: $(basename "$META_DIR")/"
  echo "  - $(basename "$SOURCES_TXT")            (flattened 'deb' lines)"
  echo "  - $(basename "$POLICY_SUMMARY")         (apt-cache policy overall)"
  echo "  - fetch_manifest_${TAG}.csv             (CSV manifest)"
  if [[ "$PROVENANCE_MODE" == "full" ]]; then
    echo "  - sources_snapshot_${TAG}/              (copy of sources.list and sources.list.d/)"
    echo "  - policy_by_pkg_${TAG}/                (per-package apt-cache policy)"
  else
    echo "  - (per-package policy files omitted; provenance=min)"
  fi
  echo "  - suites_by_pkg_${TAG}.csv              (package→suite mapping)"
  echo "  - suites_${TAG}.txt                     (unique <suite>-<component> values)"
} > "$PROVENANCE"

echo ""
echo "=== Done ==="
echo "Downloads (deb files): $INPUT_DIR/<seed>/*.deb"
echo "Metadata:              $META_DIR/"
echo "Manifest:              $MANIFEST"
echo "Suites by pkg:         $SUITES_BY_PKG"
echo "Suites (unique):       $META_DIR/suites_${TAG}.txt"
echo "Provenance:            $PROVENANCE"
echo "Log:                   $LOG_FILE"
