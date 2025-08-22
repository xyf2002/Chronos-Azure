#!/usr/bin/env bash
#
# change-uvtool-pool.sh
# Relocates the “uvtool” libvirt storage pool to /storage/uvtool
# ------------------------------------------------------------------
set -euo pipefail

POOL_NAME="uvtool"
NEW_PATH="/storage/uvtool"
XML_TMP="/tmp/${POOL_NAME}.xml"

echo "🔍 Checking that the pool exists…"
if ! sudo  virsh pool-info "$POOL_NAME" &>/dev/null; then
  echo "❌ Pool \"$POOL_NAME\" not found. Aborting." >&2
  exit 1
fi

echo "📦 Stopping the pool (harmless if already inactive)…"
sudo virsh pool-destroy "$POOL_NAME" || true

echo "📂 Creating new target directory $NEW_PATH"
mkdir -p "$NEW_PATH"

echo "📝 Re-defining the pool with the new path…"
cat >"$XML_TMP" <<EOF
<pool type='dir'>
  <name>${POOL_NAME}</name>
  <target>
    <path>${NEW_PATH}</path>
  </target>
</pool>
EOF

# Remove old definition and define the new one
sudo virsh pool-undefine "$POOL_NAME"
sudo virsh pool-define "$XML_TMP"

echo "🔧 Building and starting the pool…"
sudo virsh pool-build    "$POOL_NAME"
sudo virsh pool-start    "$POOL_NAME"
sudo virsh pool-autostart "$POOL_NAME"

echo "✅ Pool \"$POOL_NAME\" now points to $NEW_PATH"
echo "👉 Remember to move any existing volume files into the new directory if needed:"
echo "   # rsync -a /var/lib/uvtool/libvirt/images/ ${NEW_PATH}/"
