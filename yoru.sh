#!/bin/bash
set -Eeuo pipefail

# ================= COLOR =================
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
white='\033[0m'

# ================= VARIANT =================
VARIANT="${1:-KSU}"

# ================= PATH =================
DEFCONFIG="rolex_defconfig"
TEMP_DEFCONFIG="rolex_temp_defconfig"

ROOTDIR="$(pwd)"
OUTDIR="$ROOTDIR/out/arch/arm64/boot"
ANYKERNEL_DIR="$ROOTDIR/AnyKernel"

KIMG_DTB="$OUTDIR/Image.gz-dtb"
KIMG="$OUTDIR/Image.gz"

# ================= TOOLCHAIN =================
export PATH="$ROOTDIR/zyc-clang/bin:$PATH"

# ================= INFO =================
KERNEL_NAME="Yoru"
DEVICE="rolex"

# ================= DATE =================
DATE_TITLE=$(TZ=Asia/Jakarta date +"%d%m%Y")
TIME_TITLE=$(TZ=Asia/Jakarta date +"%H%M%S")
BUILD_DATETIME=$(TZ=Asia/Jakarta date +"%d %B %Y %H:%M:%S")

# ================= API =================
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

export PIXELDRAIN_API_KEY="${PIXELDRAIN_API_KEY}"
export TELE_API_ID="${TELE_API_ID}"
export TELE_API_HASH="${TELE_API_HASH}"
export TELE_SESSION="${TELE_SESSION}"

# ================= GLOBAL =================
BUILD_TIME="unknown"
KERNEL_VERSION="unknown"
IMG_USED="unknown"
ZIP_NAME=""
PD_LINK="Upload Failed"
SL_LINK="Generation Failed"
MSG_ID=""

# ================= LOG =================
LOG_DIR="$ROOTDIR/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/build-${VARIANT}-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG_FILE")
exec 2>&1

timestamp() {
    TZ=Asia/Jakarta date '+%d-%m-%Y %H:%M:%S'
}

info() {
    echo -e "[$(timestamp)] ${yellow}[INFO]${white} $*"
}

success() {
    echo -e "[$(timestamp)] ${green}[SUCCESS]${white} $*"
}

warn() {
    echo -e "[$(timestamp)] ${yellow}[WARN]${white} $*"
}

error() {
    echo -e "[$(timestamp)] ${red}[ERROR]${white} $*"
}

telegram() {
    curl -s \
        --retry 5 \
        --retry-delay 10 \
        --retry-all-errors \
        --connect-timeout 30 \
        --max-time 600 \
        "$@"
}

# ================= ERROR HANDLER =================
build_failed() {
    LINE="$1"

    error "Build failed at line ${LINE}"

    send_telegram_error

    exit 1
}

trap 'build_failed $LINENO' ERR

# ================= FUNCTION =================
clone_anykernel() {
    if [ ! -d "$ANYKERNEL_DIR" ]; then
        info "Cloning AnyKernel3..."

        git clone \
            -b main \
            https://github.com/rahmatsobrian/AnyKernel3.git \
            "$ANYKERNEL_DIR"
    fi
}

get_kernel_version() {
    if [ -f Makefile ]; then
        VERSION=$(grep '^VERSION =' Makefile | awk '{print $3}')
        PATCHLEVEL=$(grep '^PATCHLEVEL =' Makefile | awk '{print $3}')
        SUBLEVEL=$(grep '^SUBLEVEL =' Makefile | awk '{print $3}')

        KERNEL_VERSION="${VERSION}.${PATCHLEVEL}.${SUBLEVEL}"
    fi
}

# Kirim pesan awal SEKALI, simpan message_id-nya buat di-edit nanti
send_telegram_start() {

    CLANG_VERSION=$(clang --version | head -n1)

    RESPONSE=$(telegram \
        -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode=Markdown \
        -d text="🚀 *Kernel Build Started*

📱 Device : \`${DEVICE}\`
🏷 Variant : \`${VARIANT}\`
🌿 Kernel : \`${KERNEL_NAME}\`

🛠 Compiler
\`${CLANG_VERSION}\`

🕒 Started
\`${BUILD_DATETIME}\`
")

    MSG_ID=$(echo "$RESPONSE" | jq -r '.result.message_id // empty')

    if [ -z "$MSG_ID" ]; then
        warn "Gagal ambil message_id, fallback ke pesan baru untuk update status"
    fi
}

# Edit pesan yang sudah dikirim di send_telegram_start.
# Kalau MSG_ID kosong (misal gagal kirim start), fallback kirim pesan baru.
edit_telegram_status() {
    local TEXT="$1"

    if [ -n "$MSG_ID" ]; then
        telegram \
            -X POST \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText" \
            -d chat_id="${TG_CHAT_ID}" \
            -d message_id="${MSG_ID}" \
            -d parse_mode=Markdown \
            -d text="${TEXT}"
    else
        telegram \
            -X POST \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d parse_mode=Markdown \
            -d text="${TEXT}"
    fi
}

send_telegram_log() {

    [ ! -f "$LOG_FILE" ] && return

    telegram \
        -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${LOG_FILE}" \
        -F caption="📄 Build Log"
}

send_telegram_error() {

    edit_telegram_status "❌ *Kernel Build Failed*

📱 Device : \`${DEVICE}\`
🏷 Variant : \`${VARIANT}\`

📄 Build log attached below."

    send_telegram_log
}

# ================= BUILD =================
build_kernel() {

    send_telegram_start

    info "Removing old out folder..."
    rm -rf out

    mkdir -p out

    info "Preparing defconfig..."

    cp \
        arch/arm64/configs/${DEFCONFIG} \
        arch/arm64/configs/${TEMP_DEFCONFIG}

    if [ "$VARIANT" = "NonKSU" ]; then
        warn "Disabling KernelSU..."

        sed -i \
            's/CONFIG_KSU=y/# CONFIG_KSU is not set/g' \
            arch/arm64/configs/${TEMP_DEFCONFIG}
    fi

    make O=out ARCH=arm64 ${TEMP_DEFCONFIG}

    BUILD_START=$(date +%s)

    info "Building kernel..."

    make -j"$(nproc --all)" \
        ARCH=arm64 \
        O=out \
        CC=clang \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_ARM32=arm-linux-gnueabi-

    BUILD_END=$(date +%s)

    DIFF=$((BUILD_END - BUILD_START))

    BUILD_TIME="$((DIFF / 60)) min $((DIFF % 60)) sec"

    get_kernel_version

    ZIP_NAME="${KERNEL_NAME}-${VARIANT}-${DEVICE}-${KERNEL_VERSION}-${DATE_TITLE}-${TIME_TITLE}.zip"
}

# ================= PACK =================
pack_kernel() {

    clone_anykernel

    cd "$ANYKERNEL_DIR"

    rm -f Image* *.zip

    if [ -f "$KIMG_DTB" ]; then
        cp "$KIMG_DTB" Image.gz-dtb
        IMG_USED="Image.gz-dtb"

    elif [ -f "$KIMG" ]; then
        cp "$KIMG" Image.gz
        IMG_USED="Image.gz"

    else
        error "Kernel image not found"
        exit 1
    fi

    info "Creating zip..."

    zip -r9 "$ZIP_NAME" . \
        -x ".git*" \
        -x "README.md"

    success "Zip created : $ZIP_NAME"
}

# ================= UPLOAD =================
upload_telegram() {

    ZIP_PATH="$ANYKERNEL_DIR/$ZIP_NAME"

    [ ! -f "$ZIP_PATH" ] && return

    info "Uploading to Pixeldrain..."

    PD_RESPONSE=$(
        curl \
            --retry 5 \
            --retry-delay 15 \
            --retry-all-errors \
            --connect-timeout 60 \
            --max-time 7200 \
            -s \
            -T "${ZIP_PATH}" \
            -u :"${PIXELDRAIN_API_KEY}" \
            "https://pixeldrain.com/api/file/${ZIP_NAME}"
    )

    PD_ID=$(echo "$PD_RESPONSE" | jq -r '.id // empty')

    if [[ -n "$PD_ID" && "$PD_ID" != "null" ]]; then

        PD_LINK="https://pixeldrain.com/u/${PD_ID}"

        success "Pixeldrain : ${PD_LINK}"

    else
        error "Pixeldrain upload failed"
        error "$PD_RESPONSE"
    fi

    export PD_LINK

    info "Generating Safelinku..."

    SL_LINK=$(python3 << 'EOF'
import asyncio
import os
import re
import logging
from telethon import TelegramClient, events
from telethon.sessions import StringSession

logging.basicConfig(level=logging.ERROR)

api_id=os.getenv("TELE_API_ID")
api_hash=os.getenv("TELE_API_HASH")
session=os.getenv("TELE_SESSION")
pd_link=os.getenv("PD_LINK")

async def main():

    if not api_id:
        print("Generation Failed")
        return

    client=TelegramClient(
        StringSession(session),
        int(api_id),
        api_hash
    )

    await client.start()

    loop=asyncio.get_event_loop()
    future=loop.create_future()

    @client.on(events.NewMessage(chats="@safelinku_com_bot"))
    async def handler(event):

        txt=event.message.message

        urls=re.findall(
            r'https?://[^\s]+',
            txt
        )

        if urls and not future.done():
            future.set_result(urls[-1])

    await client.send_message(
        "@safelinku_com_bot",
        f"/shortlink {pd_link}"
    )

    try:
        res=await asyncio.wait_for(
            future,
            timeout=180.0
        )
    except:
        res="Generation Failed"

    print(res)

    await client.disconnect()

asyncio.run(main())
EOF
)

    if [[ "$SL_LINK" == http* ]]; then
        success "Safelinku : ${SL_LINK}"
    else
        warn "Safelinku generation failed"
        SL_LINK="Generation Failed"
    fi

    info "Updating telegram message..."

    if [ "$SL_LINK" != "Generation Failed" ]; then

        DOWNLOAD_TEXT="📥 *Downloads*

🔗 [Pixeldrain](${PD_LINK})

💰 [Safelinku](${SL_LINK})"

    else

        DOWNLOAD_TEXT="📥 *Downloads*

🔗 [Pixeldrain](${PD_LINK})

⚠️ Safelinku generation failed"

    fi

    edit_telegram_status "🔥 *Kernel Build Success*

📱 Device : \`${DEVICE}\`
📦 Kernel : \`${KERNEL_NAME}\`
🏷 Variant : \`${VARIANT}\`
🍃 Version : \`${KERNEL_VERSION}\`

⌛ Build Time
\`${BUILD_TIME}\`

📦 Package
\`${ZIP_NAME}\`

${DOWNLOAD_TEXT}
"

    info "Uploading zip to Telegram..."

    telegram \
        -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"${ZIP_PATH}" \
        -F caption="${ZIP_NAME}" &

    send_telegram_log
}

# ================= RUN =================
START=$(date +%s)

build_kernel
pack_kernel
upload_telegram

END=$(date +%s)

success "========================================"
success "Kernel      : ${KERNEL_NAME}"
success "Variant     : ${VARIANT}"
success "Version     : ${KERNEL_VERSION}"
success "Image       : ${IMG_USED}"
success "ZIP         : ${ZIP_NAME}"
success "Build Time  : ${BUILD_TIME}"
success "Pixeldrain  : ${PD_LINK}"
success "Safelinku   : ${SL_LINK}"
success "Log File    : ${LOG_FILE}"
success "Total Time  : $((END - START)) sec"
success "========================================"
