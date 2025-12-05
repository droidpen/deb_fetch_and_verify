=========================================================================================================
How to use fetch_deb.sh to build the offline USB/CD/DVD repo
=========================================================================================================

=========================================================================================================
Step 1 — Prepare your seeds.txt containing your required base packages
=========================================================================================================

Example:
Create a file:
cat > seeds.txt << 'EOF'
linux-image-generic
linux-firmware
xserver-xorg-input-libinput
xserver-xorg-input-synaptics
i2c-tools
EOF


⚠️ If your target machine needs a specific kernel version, replace linux-image-generic with:

linux-image-6.x.x-xx-generic
linux-modules-6.x.x-xx-generic
linux-modules-extra-6.x.x-xx-generic


This ensures the correct target machine trackpad drivers are included.

=========================================================================================================
Step 2 — Run your secure fetch and verify script
=========================================================================================================
mkdir -p ~/offline_repo
./fetch_deb.sh --tag hp640 --provenance full $(cat seeds.txt) ~/offline_repo

Then:
./verify_deb.sh offline_repo

What this does:

downloads .deb for all seed packages

recurses through dependency tree

verifies GPG signature of InRelease

verifies SHA256 from Packages

verifies .deb integrity

stores provenance metadata in .fetch_meta_hp640/

All packages in ~/offline_repo/ are trusted and cryptographically validated.

This is the most secure method possible without direct APT access.


=========================================================================================================
Step 3 — Convert that folder into an offline APT repository
=========================================================================================================

Inside the download directory:

cd ~/offline_repo
dpkg-scanpackages . > Packages
gzip -k Packages


This produces:

Packages

Packages.gz

All verified .deb files

Exactly what apt needs.

=========================================================================================================
Step 4 — Copy to USB or other boot media (e.g. CD / DVD ROM)
=========================================================================================================
For USB:
cp -a ~/offline_repo/* /media/$USER/YOUR_USB/

For CD/DVD:
genisoimage -o output.iso -r -J /path/to/folder
sha256sum output.iso
growisofs -dvd-compat -Z /dev/sr0=output.iso

Where /dev/sr0 is your optical drive (check with lsblk).

=========================================================================================================
Step 5 — Use it offline on the target machine
=========================================================================================================
On the target machine:

sudo mkdir -p /mnt/ext-repo
sudo mount /dev/sdX1 /mnt/ext-repo
echo "deb [trusted=yes] file:/mnt/ext-repo ./" | sudo tee /etc/apt/sources.list.d/ext-offline.list

sudo apt update
sudo apt install linux-firmware linux-image-generic xserver-xorg-input-libinput


(Replace with your specific kernel version if needed.)

This will install everything from the external media only, using packages you already verified cryptographically.

No Internet needed.

Why this method is ideal (security defender mindset)

The script does:

1) GPG validation of Ubuntu archive metadata

2) SHA256 validation of Packages lists

3) SHA256 validation of each .deb

4) Full provenance snapshot

5) Repeatable, auditable, offline-friendly output

This is stronger than what most security teams implement.

You're essentially building a signed, trusted Ubuntu micro-mirror.


