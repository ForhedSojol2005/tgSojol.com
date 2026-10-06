#!/data/data/com.termux/files/usr/bin/bash

set -e

echo "================================"
echo "       tgSojol.com Installer"
echo "================================"

URL="https://raw.githubusercontent.com/ForhedSojol2005/tgSojol.com/main/tgSojol.com"
INSTALL_DIR="$PREFIX/bin"
TARGET="$INSTALL_DIR/tgSojol"

echo "📥 GitHub থেকে tgSojol download হচ্ছে..."

if ! command -v curl >/dev/null 2>&1; then
    echo "📦 curl install করা হচ্ছে..."
    pkg install -y curl
fi

curl -fL "$URL" -o "$TARGET"

chmod 755 "$TARGET"

echo ""
echo "✅ tgSojol successfully installed!"
echo ""
echo "চালাতে:"
echo "  tgSojol"
echo ""
