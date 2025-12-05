README — Debian Package Fetch & Verify Artifacts

This folder contains metadata produced by two helper scripts:

Fetcher: fetch_deb.sh

Verifier: verify_deb.sh

It’s safe to keep or delete these meta folders without affecting the .deb files themselves.

1) Fetcher (.fetch_meta_<TAG>/)
What the fetcher does

Uses your current APT environment to resolve recursive dependencies for one or more seed packages.

Downloads each seed’s .deb files (and its deps) into <dest>/<seed>/ subfolders.

Records provenance (which repos/suites were used) into this .fetch_meta_<TAG>/ folder.

Typical folder contents
.fetch_meta_<TAG>/
  fetch_debs_<TAG>.log              # Full run log
  fetch_manifest_<TAG>.csv          # Manifest of downloaded .debs (one row per file)
  apt_sources_lines_<TAG>.txt       # Flattened snapshot of active 'deb' lines
  apt_policy_summary_<TAG>.txt      # Output of `apt-cache policy`
  suites_by_pkg_<TAG>.csv           # Map of package -> suite/component/origin
  suites_<TAG>.txt                  # Unique "<suite>-<component>" values
  sources_snapshot_<TAG>/           # (full mode) Copy of /etc/apt/sources*
  policy_by_pkg_<TAG>/              # (full mode) Per-package `apt-cache policy` files
  PROVENANCE_<TAG>.txt              # Human-readable summary of what’s above
  README.md                         # This file


If you ran the fetcher with --provenance min, the sources_snapshot_*/ and policy_by_pkg_*/ directories are omitted to reduce clutter.

How to read the key files
fetch_manifest_<TAG>.csv

Columns:

filename — path to the .deb relative to the destination root (e.g., make/make_4.3-..._amd64.deb)

package — Debian package name

version — Debian version (may include an epoch, e.g., 1:1.2.3-1)

architecture — e.g., amd64

sha256 — checksum of the file you downloaded

candidate_version — what apt-cache policy <pkg> reported as Candidate at fetch time

policy_file — (full provenance only) relative path to policy_by_pkg_<TAG>/<pkg>.policy.txt

Use this file to:

Hash-pin builds (reproducibility): sha256sum -c

Confirm you got exact versions expected

Cross-reference to the suite info below

suites_by_pkg_<TAG>.csv

Columns:

package

version (candidate)

suite — e.g., jammy, jammy-updates, noble-security

codename — base codename (e.g., jammy), without pocket suffix

component — main | universe | multiverse | restricted

origin — repo host (e.g., archive.ubuntu.com)

This comes from parsing the first HTTP(S) repository line in the apt-cache policy “Version table”. It’s a hint to where APT resolved the package from under your environment (codename + pocket + component).

suites_<TAG>.txt

A deduplicated list like:

jammy-main
jammy-updates-main
jammy-security-main


This helps you see which pockets/components were actually used in the run.

PROVENANCE_<TAG>.txt

Human summary of:

Host distro/codename/architecture

Which files this run produced

Whether per-package policy and source snapshots were captured

apt_sources_lines_<TAG>.txt

A snapshot of active deb lines from your /etc/apt/sources.list and sources.list.d/*.list. This captures which repos and which suites your APT was configured to use.

policy_by_pkg_<TAG>/*.policy.txt (full mode)

Raw apt-cache policy <pkg> dumps. Useful for auditing why APT chose a particular version/suite.

2) Verifier (/.verify_meta_<TIMESTAMP>/)
What the verifier does

Scans your destination folder for .deb files.

Looks each one up in Ubuntu’s official Packages.gz indexes across many suites/pockets.

Confirms that Package + Version + SHA256 appear together in the same stanza.

Writes a CSV with a reason when a match can’t be found.

Packages_*.gz and Packages_*.txt copies are placed next to the .deb that matched, for transparency and offline auditing.

Typical folder contents
.verify_meta_<TIMESTAMP>/
  verify_deb_<TIMESTAMP>.log        # Full run log
  verify_deb_<TIMESTAMP>.csv        # Results table (sorted)
  verify_gpg_failures_<TS>.txt      # Only if some suite Release signatures failed
  README.md                         # This file

How to read verify_deb_<TIMESTAMP>.csv

Columns:

folder — folder that contained the .deb

filename — the .deb filename

package — Debian name (from control)

version — Debian version (from control)

architecture

sha256 — hash of the file on disk

match_found — yes or no

suite/component — e.g., jammy/main, jammy-updates/main (only for matches)

packages_txt_filename — the text copy saved next to the .deb (for matches)

match_start_line — stanza start line inside the saved Packages_*.txt (for matches)

reason — why it didn’t match (when match_found=no)

Common reasons:

gpg_failed_suite_skipped — A suite’s Release/Release.gpg failed signature check, so it was skipped.

packages_file_missing_for_suite — We couldn’t download/decompress Packages.gz for any suite.

sha256_not_found_but_pkgver_present — Package: and Version: were found in at least one stanza, but not the exact SHA256 of your file.

version_not_in_packages — Package: exists in the index, but your exact Version: does not.

not_found_in_checked_packages — Nothing matched at all in the scanned suites/components.

Audit a successful match:

Open the Packages_<suite>_<component>.txt saved next to the .deb.

Jump to match_start_line and inspect that stanza; it should contain the exact Package, Version, and SHA256.

GPG verification & retries

At the start, the verifier GPG-checks each suite’s Release with the system keyring:
/usr/share/keyrings/ubuntu-archive-keyring.gpg.

Suites that fail are listed in verify_gpg_failures_<TS>.txt.

After the run, you’ll be prompted to retry using only the failed suites (or you can set an environment variable):

FORCE_SUITES="jammy jammy-updates" ./verify_deb.sh <dest>

3) Typical workflows
A) Fresh fetch + verify
# 1) Fetch into per-seed folders
./fetch_debs_with_provenance.sh binfmt-support make qemu-user-static ./dl

# 2) Verify everything under ./dl
./verify_deb.sh ./dl


Open:

./dl/.fetch_meta_<TAG>/fetch_manifest_<TAG>.csv

./dl/.fetch_meta_<TAG>/suites_by_pkg_<TAG>.csv

./dl/.verify_meta_<TS>/verify_deb_<TS>.csv

B) Confirm the suite/pocket for a specific file

Find the file row in fetch_manifest_<TAG>.csv.

In suites_by_pkg_<TAG>.csv, look up the package name + version.

If necessary, inspect policy_by_pkg_<TAG>/<pkg>.policy.txt for the full apt-cache policy context.

From verify results, confirm suite/component matched and inspect the saved Packages_*.txt stanza.

C) Reproducibility / integrity check
# Using manifest (from fetch)
cd <dest> && sha256sum -c .fetch_meta_<TAG>/fetch_manifest_<TAG>.csv \
   --text 2>/dev/null | grep -E 'OK|FAILED'   # (or build a small checker)


(Or use the verify CSV as the source of truth for matched hashes.)

4) Notes & tips

Seeds vs dependencies (fetcher): only seed packages get their own subfolder under the destination; their dependencies are downloaded into the same seed folder, not top-level.

Multiple runs: If you want to accumulate results into one meta folder during fetch, use --tag <name> to reuse .fetch_meta_<name>. Otherwise, a new timestamped folder is created.

Network variety: suites_by_pkg relies on HTTP(S) lines in apt-cache policy; if your mirror is local/flat file, suite mapping may be blank (the .deb still downloads).

HGFS/VM shares: If you see odd timestamp or newline behavior, try running into a local path (e.g., /tmp/dltest) to rule out host filesystem quirks.

Cleanup: You can safely delete .fetch_meta_* / .verify_meta_* folders when you no longer need the audit trail.

5) Glossary

Suite / Pocket: e.g., jammy, jammy-updates, jammy-security.

Component: main, universe, multiverse, restricted.

Stanza: A block of fields in Packages (separated by blank lines) describing one package version, including Package:, Version:, Architecture:, SHA256:, etc.