#!/data/data/com.termux/files/usr/bin/bash

set -e

echo "================================"
echo "       tgSojol.com Installer"
echo "================================"

INSTALL_DIR="$PREFIX/bin"
SOURCE="$(cd "$(dirname "$0")" && pwd)/tgSojol.com"

if [ ! -f "$SOURCE" ]; then
    echo "❌ tgSojol.com file পাওয়া যায়নি।"
    exit 1
fi

echo "📦 Installing tgSojol.com..."

cp "$SOURCE" "$INSTALL_DIR/tgSojol"
chmod 755 "$INSTALL_DIR/tgSojol"

echo ""
echo "✅ tgSojol successfully installed!"
echo ""
echo "চালাতে:"
echo "  tgSojol"
echo ""
