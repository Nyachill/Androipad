#!/usr/bin/env bash
# Android-x86 の ISO から、アプリに同梱する一式を作る（Ubuntu で実行）
#   出力: OUT_DIR/{android.iso, kernel, initrd.img, data.qcow2, cmdline.txt}
# 使い方: prepare_android.sh ISO_URL OUT_DIR "カーネル引数" データ容量(GB)
set -euo pipefail

ISO_URL="$1"
OUT_DIR="$2"
CMDLINE="$3"
DATA_GB="${4:-16}"

mkdir -p "$OUT_DIR"
ISO="$OUT_DIR/android.iso"

if [ ! -s "$ISO" ]; then
  echo "ISO をダウンロード: $ISO_URL"
  curl -fL --retry 5 --retry-delay 10 --connect-timeout 30 -o "$ISO.part" "$ISO_URL"
  mv "$ISO.part" "$ISO"
fi

size=$(stat -c %s "$ISO")
if [ "$size" -lt 300000000 ]; then
  echo "::error::ISO が小さすぎます（${size} バイト）。URL がダウンロードページを指していないか確認してください"
  exit 1
fi

# ISO の直下にある kernel と initrd.img を取り出す（system.sfs は ISO ごと CD として渡す）
rm -rf "$OUT_DIR/x"
mkdir -p "$OUT_DIR/x"
bsdtar -xf "$ISO" -C "$OUT_DIR/x" kernel initrd.img
for f in kernel initrd.img; do
  if [ ! -s "$OUT_DIR/x/$f" ]; then
    echo "::error::ISO に $f が見つかりません。Android-x86 の ISO か確認してください"
    exit 1
  fi
  mv "$OUT_DIR/x/$f" "$OUT_DIR/$f"
done
rm -rf "$OUT_DIR/x"

# /data 用のディスク（ext4 でフォーマット済み）。中身は空なので qcow2 にすると数 MB で済む
rm -f "$OUT_DIR/data.img" "$OUT_DIR/data.qcow2"
truncate -s "${DATA_GB}G" "$OUT_DIR/data.img"
mkfs.ext4 -q -F -L data "$OUT_DIR/data.img"
qemu-img convert -f raw -O qcow2 "$OUT_DIR/data.img" "$OUT_DIR/data.qcow2"
rm -f "$OUT_DIR/data.img"

printf '%s\n' "$CMDLINE" > "$OUT_DIR/cmdline.txt"

ls -la "$OUT_DIR"
