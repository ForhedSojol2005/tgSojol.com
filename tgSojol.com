#!/data/data/com.termux/files/usr/bin/bash

set -u

CHAT_ID="7154341340"
BASE="$HOME/storage/shared"
WORK="$HOME/tgSojol_tmp"
TOKEN_FILE="$HOME/.config/tgSojol/token"

# Telegram-এর 50 MB সীমার নিচে নিরাপদভাবে রাখা
LIMIT=$((48 * 1024 * 1024))

mkdir -p "$WORK"

# ==========================================
# TOKEN
# ==========================================

if [ ! -r "$TOKEN_FILE" ]; then
    echo "❌ Token file পাওয়া যায়নি:"
    echo "$TOKEN_FILE"
    exit 1
fi

TG_BOT_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"

if [ -z "$TG_BOT_TOKEN" ]; then
    echo "❌ Token file খালি"
    exit 1
fi

# ==========================================
# CLEANUP
# Ctrl+C / Termux process বন্ধ হলে
# incomplete/temporary files delete হবে
# ==========================================

cleanup() {
    echo
    echo "🛑 Backup বন্ধ করা হয়েছে"
    echo "🧹 Temporary files পরিষ্কার হচ্ছে..."

    rm -f \
        "$WORK"/.building_*.zip \
        "$WORK"/.test_*.zip \
        "$WORK"/.contacts.vcf \
        "$WORK"/.contacts.json \
        "$WORK"/.filelist_*

    echo "✅ Cleanup complete"
    exit 130
}

trap cleanup INT TERM HUP

# ==========================================
# TELEGRAM UPLOAD WITH AUTO RETRY
# ==========================================

upload_zip() {

    local ZIP="$1"
    local NAME
    NAME="$(basename "$ZIP")"

    if [ ! -f "$ZIP" ]; then
        return 1
    fi

    # ZIP সম্পূর্ণ/valid কিনা
    if ! unzip -tq "$ZIP" >/dev/null 2>&1; then
        echo "❌ ZIP integrity check ব্যর্থ:"
        echo "$NAME"
        rm -f "$ZIP"
        return 1
    fi

    echo
    echo "📦 $NAME"
    echo "📏 Size: $(du -h "$ZIP" | cut -f1)"

    while true; do

        echo "📤 Telegram-এ পাঠানো হচ্ছে..."

        RESPONSE=$(curl --fail-with-body -sS \
            --connect-timeout 15 \
            --max-time 300 \
            -X POST \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
            -F "chat_id=${CHAT_ID}" \
            -F "document=@${ZIP}" 2>&1)

        if echo "$RESPONSE" | grep -q '"ok":true'; then

            echo "✅ Telegram upload সফল"
            rm -f "$ZIP"
            echo "🗑️ ZIP delete হয়েছে"

            return 0
        fi

        echo "⚠️ Upload ব্যর্থ:"
        echo "$RESPONSE"

        echo
        echo "🌐 নেটওয়ার্ক পাওয়া যাচ্ছে না বা connection বিচ্ছিন্ন।"
        echo "⏳ 15 সেকেন্ড পর আবার চেষ্টা করা হবে..."
        echo "💡 নেট ফিরে এলে একই ZIP থেকেই আবার শুরু হবে।"

        sleep 15
    done
}

# ==========================================
# FILE ZIP + UPLOAD
# ==========================================

make_and_send_category() {

    local NAME="$1"
    shift

    local LIST="$WORK/.filelist_${NAME}"
    local PART=1
    local BUILD="$WORK/.building_${NAME}_${PART}.zip"
    local TEST="$WORK/.test_${NAME}_${PART}.zip"
    local FINAL="$WORK/${NAME}_${PART}.zip"

    rm -f "$LIST"
    rm -f "$WORK"/.building_${NAME}_*.zip
    rm -f "$WORK"/.test_${NAME}_*.zip

    echo
    echo "================================"
    echo "🔎 $NAME"
    echo "================================"

    "$@" > "$LIST" 2>/dev/null

    if [ ! -s "$LIST" ]; then
        echo "⚠️ $NAME-এ কোনো ফাইল পাওয়া যায়নি"
        rm -f "$LIST"
        return 0
    fi

    while IFS= read -r FILE; do

        [ -f "$FILE" ] || continue

        # ----------------------------------
        # প্রথম file
        # ----------------------------------

        if [ ! -f "$BUILD" ]; then

            rm -f "$BUILD"

            if ! zip -q "$BUILD" "$FILE" 2>/dev/null; then
                echo "❌ ZIP তৈরিতে সমস্যা:"
                echo "$FILE"

                rm -f "$BUILD" "$LIST"
                return 1
            fi

            SIZE=$(stat -c %s "$BUILD" 2>/dev/null || echo 0)

            if [ "$SIZE" -gt "$LIMIT" ]; then
                echo "⚠️ একক ফাইল 48 MB-এর বেশি:"
                echo "$FILE"
                echo "⏭️ এই ফাইলটি বাদ দেওয়া হলো"

                rm -f "$BUILD"
            fi

            continue
        fi

        # ----------------------------------
        # Temporary ZIP দিয়ে পরীক্ষা
        # ----------------------------------

        rm -f "$TEST"

        if ! cp "$BUILD" "$TEST" 2>/dev/null; then
            echo "❌ Temporary ZIP copy ব্যর্থ"
            rm -f "$BUILD" "$TEST" "$LIST"
            return 1
        fi

        if ! zip -q "$TEST" "$FILE" 2>/dev/null; then
            rm -f "$TEST"

            echo "❌ ZIP update ব্যর্থ:"
            echo "$FILE"

            rm -f "$BUILD" "$LIST"
            return 1
        fi

        SIZE=$(stat -c %s "$TEST" 2>/dev/null || echo 0)

        # ----------------------------------
        # Limit-এর মধ্যে আছে
        # ----------------------------------

        if [ "$SIZE" -le "$LIMIT" ]; then
            mv -f "$TEST" "$BUILD"
            continue
        fi

        # ----------------------------------
        # Limit ছাড়িয়েছে
        # বর্তমান ZIP complete
        # ----------------------------------

        rm -f "$TEST"

        echo
        echo "📦 ${NAME}-${PART} প্রস্তুত"
        echo "📏 Size: $(du -h "$BUILD" | cut -f1)"

        FINAL="$WORK/${NAME}_${PART}.zip"

        # BUILD → FINAL
        mv -f "$BUILD" "$FINAL"

        # Upload সফল না হওয়া পর্যন্ত
        # এখানে function অপেক্ষা করবে
        upload_zip "$FINAL"

        # ----------------------------------
        # পরের ZIP
        # ----------------------------------

        PART=$((PART + 1))

        BUILD="$WORK/.building_${NAME}_${PART}.zip"
        TEST="$WORK/.test_${NAME}_${PART}.zip"

        rm -f "$BUILD" "$TEST"

        if ! zip -q "$BUILD" "$FILE" 2>/dev/null; then
            echo "❌ নতুন ZIP তৈরি ব্যর্থ:"
            echo "$FILE"

            rm -f "$BUILD" "$LIST"
            return 1
        fi

        SIZE=$(stat -c %s "$BUILD" 2>/dev/null || echo 0)

        if [ "$SIZE" -gt "$LIMIT" ]; then
            echo "⚠️ একক ফাইল 48 MB-এর বেশি:"
            echo "$FILE"
            echo "⏭️ বাদ দেওয়া হলো"

            rm -f "$BUILD"
        fi

    done < "$LIST"

    # ======================================
    # শেষ ZIP
    # ======================================

    if [ -f "$BUILD" ]; then

        SIZE=$(stat -c %s "$BUILD" 2>/dev/null || echo 0)

        if [ "$SIZE" -gt 0 ] && [ "$SIZE" -le "$LIMIT" ]; then

            echo
            echo "📦 ${NAME}-${PART} প্রস্তুত"
            echo "📏 Size: $(du -h "$BUILD" | cut -f1)"

            FINAL="$WORK/${NAME}_${PART}.zip"

            mv -f "$BUILD" "$FINAL"

            upload_zip "$FINAL"

        else
            rm -f "$BUILD"
        fi
    fi

    rm -f "$TEST" "$LIST"

    echo "✅ $NAME backup শেষ"
}

# ==========================================
# PHOTOS
# ==========================================

make_and_send_category "Photos" find \
    "$BASE/DCIM" "$BASE/Pictures" \
    -type f \
    \( \
        -iname "*.jpg" \
        -o -iname "*.jpeg" \
        -o -iname "*.png" \
        -o -iname "*.webp" \
    \) \
    ! -name ".trashed-*" \
    ! -path "*/.thumbnails/*" \
    ! -path "*/.watermark/*" \
    -print

# ==========================================
# DOCUMENTS
# ==========================================

make_and_send_category "Documents" find \
    "$BASE/Documents" \
    -type f \
    \( \
        -iname "*.pdf" \
        -o -iname "*.doc" \
        -o -iname "*.docx" \
        -o -iname "*.xls" \
        -o -iname "*.xlsx" \
        -o -iname "*.ppt" \
        -o -iname "*.pptx" \
        -o -iname "*.txt" \
        -o -iname "*.csv" \
        -o -iname "*.rtf" \
        -o -iname "*.odt" \
    \) \
    -print

# ==========================================
# CONTACTS
# ==========================================

echo
echo "================================"
echo "👥 CONTACTS"
echo "================================"

if command -v termux-contact-list >/dev/null 2>&1; then

    echo "Contacts backup করবেন? (y/n)"
    read -r CONTACT_PERMISSION

    case "$CONTACT_PERMISSION" in

        y|Y)

            CONTACT_JSON="$WORK/.contacts.json"
            CONTACT_VCF="$WORK/.contacts.vcf"
            CONTACT_BUILD="$WORK/.building_Contacts_1.zip"
            CONTACT_FINAL="$WORK/Contacts_1.zip"

            rm -f \
                "$CONTACT_JSON" \
                "$CONTACT_VCF" \
                "$CONTACT_BUILD" \
                "$CONTACT_FINAL"

            echo "📱 Contacts permission পরীক্ষা করা হচ্ছে..."

            if ! termux-contact-list > "$CONTACT_JSON" 2>/dev/null; then

                echo "⚠️ Contacts permission পাওয়া যায়নি"
                rm -f "$CONTACT_JSON"

            elif grep -q '"error"' "$CONTACT_JSON" 2>/dev/null; then

                echo "⚠️ Contacts permission দেওয়া হয়নি"
                rm -f "$CONTACT_JSON"

            else

                echo "✅ Contacts পাওয়া গেছে"
                echo "📄 Temporary VCF তৈরি হচ্ছে..."

                python - "$CONTACT_JSON" "$CONTACT_VCF" <<'PY'
import json
import sys

src = sys.argv[1]
dst = sys.argv[2]

with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

if isinstance(data, dict):
    data = [data]

def clean(value):
    value = str(value or "")
    value = value.replace("\\", "\\\\")
    value = value.replace(";", "\\;")
    value = value.replace(",", "\\,")
    value = value.replace("\n", "\\n")
    return value

count = 0

with open(dst, "w", encoding="utf-8", newline="\n") as out:

    for contact in data:

        if not isinstance(contact, dict):
            continue

        name = clean(contact.get("name", ""))
        number = clean(contact.get("number", ""))

        if not name and not number:
            continue

        # শুধু নাম + নাম্বার
        out.write("BEGIN:VCARD\n")
        out.write("VERSION:3.0\n")
        out.write("FN:" + name + "\n")
        out.write("TEL:" + number + "\n")
        out.write("END:VCARD\n")

        count += 1

print(f"VCF_CONTACT_COUNT={count}")
PY

                if [ -s "$CONTACT_VCF" ]; then

                    echo "📦 Contacts ZIP তৈরি হচ্ছে..."

                    if zip -q "$CONTACT_BUILD" "$CONTACT_VCF" 2>/dev/null; then

                        SIZE=$(stat -c %s "$CONTACT_BUILD" 2>/dev/null || echo 0)

                        if [ "$SIZE" -le "$LIMIT" ]; then

                            mv -f "$CONTACT_BUILD" "$CONTACT_FINAL"

                            upload_zip "$CONTACT_FINAL"

                            echo "🗑️ Temporary VCF delete হয়েছে"

                        else
                            echo "❌ Contacts ZIP limit-এর বেশি"
                            rm -f "$CONTACT_BUILD"
                        fi

                    else
                        echo "❌ Contacts ZIP তৈরি ব্যর্থ"
                        rm -f "$CONTACT_BUILD"
                    fi

                else
                    echo "⚠️ কোনো contact পাওয়া যায়নি"
                fi

                rm -f "$CONTACT_JSON" "$CONTACT_VCF"

            fi

            ;;

        n|N)
            echo "⏭️ Contacts skipped"
            ;;

        *)
            echo "⚠️ ভুল input — Contacts skipped"
            ;;

    esac

else
    echo "⚠️ termux-contact-list পাওয়া যায়নি"
    echo "⏭️ Contacts skipped"
fi

# ==========================================
# DOWNLOADS
# ==========================================

DOWNLOAD_DIR=""

if [ -d "$BASE/Download" ]; then
    DOWNLOAD_DIR="$BASE/Download"
elif [ -d "$BASE/Downloads" ]; then
    DOWNLOAD_DIR="$BASE/Downloads"
fi

if [ -n "$DOWNLOAD_DIR" ]; then

    make_and_send_category "Downloads" find \
        "$DOWNLOAD_DIR" \
        -type f \
        ! -path "*/tgSojol_tmp/*" \
        -print

else
    echo
    echo "⚠️ Download folder পাওয়া যায়নি"
fi

# ==========================================
# FINAL CLEANUP
# ==========================================

rm -f \
    "$WORK"/.building_*.zip \
    "$WORK"/.test_*.zip \
    "$WORK"/.contacts.vcf \
    "$WORK"/.contacts.json \
    "$WORK"/.filelist_*

echo
echo "================================"
echo "🎉 BACKUP COMPLETE"
echo "================================"
