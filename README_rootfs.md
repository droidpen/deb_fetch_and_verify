README — Rootfs Fetch & Verify Artifacts

This folder contains metadata produced by two helper scripts:

Fetcher: fetch_rootfs.sh

Verifier: verify_rootfs.sh

It is safe to delete these .meta_* folders without affecting the .tar.gz rootfs itself. They exist to provide provenance and audit logs.

1) Rootfs Fetcher (fetch_rootfs.sh)
What the fetcher does

Downloads the Ubuntu Base rootfs tarball for a specific release (e.g., 20.04.5, 22.04.3) and architecture (amd64, arm64).

Also downloads the matching SHA256SUMS and SHA256SUMS.gpg from the official Canonical image server.

Organizes the files into:

<base-dir>/<release>_<arch>/
  ubuntu-base-<release>-base-<arch>.tar.gz
  SHA256SUMS
  SHA256SUMS.gpg
  .meta_<timestamp>/

Typical .meta_* contents
.meta_20250907_020000/
  fetch_rootfs_20250907_020000.log     # Full run log
  README.md                            # This file

Example usage
# Fetch rootfs for Ubuntu 20.04.5 arm64
./fetch_rootfs.sh 20.04.5 arm64 ./rootfs_dl

# Fetch rootfs for latest 22.04.x amd64
./fetch_rootfs.sh 22.04 amd64 ./rootfs_dl


This will create:

./rootfs_dl/20.04.5_arm64/
  ubuntu-base-20.04.5-base-arm64.tar.gz
  SHA256SUMS
  SHA256SUMS.gpg
  .meta_20250907_020000/

2) Rootfs Verifier (verify_rootfs.sh)
What the verifier does

Verifies that the downloaded SHA256SUMS file matches its GPG signature (using Canonical’s official signing key).

Validates each .tar.gz file against the checksums in SHA256SUMS.

Produces logs, CSV results, and a copy of the Canonical keyring in a .meta_* folder.

Typical .meta_* contents
.meta_20250907_015211/
  verify_rootfs_20250907_015211.log   # Full run log
  verify_rootfs_20250907_015211.csv   # Results (filename,status,message)
  ubuntu.gpg                          # Downloaded Canonical keyring for verification
  README.md                           # This file

How to read the CSV

Columns:

filename — the .tar.gz being checked

status — OK | FAIL | SKIP

message — human-readable explanation

OK — hash matches checksum and checksum list is signed correctly.

FAIL — file is listed but the checksum does not match.

SKIP — file not listed in SHA256SUMS.

Example usage
# Verify everything in a release/arch subfolder
./verify_rootfs.sh ./rootfs_dl/20.04.5_arm64

3) Typical Workflow
A) Fetch + verify
./fetch_rootfs.sh 22.04 amd64 ./rootfs_dl
./verify_rootfs.sh ./rootfs_dl/22.04.3_amd64

B) Audit run logs

Check the .meta_* folder for the detailed log:

Fetcher: fetch_rootfs_<timestamp>.log

Verifier: verify_rootfs_<timestamp>.log

C) Inspect keyring and signature

The verifier saves ubuntu.gpg (downloaded Canonical keyring).

Signature verification is logged and summarized in the .log file.

4) Notes

If you pass only a major.minor release (e.g., 22.04), the fetcher auto-discovers the latest point release (e.g., 22.04.3).

Verification requires the system package ubuntu-archive-keyring. The script will install it if missing.

All metadata (log, csv, gpg) is placed in .meta_<timestamp> to avoid clutter.

You can safely delete the .meta_* folders after you’ve reviewed or archived them.