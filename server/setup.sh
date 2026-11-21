#!/usr/bin/env bash
# さくらVPS（Ubuntu 22.04）に Android（redroid）と画面配信（ws-scrcpy）を入れ、
# https://<ドメイン>/ でパスワード付きで見られるようにする
#
# 使い方（SSH でログインしてから）:
#   curl -fsSL https://raw.githubusercontent.com/Nyachill/Androipad/main/server/setup.sh -o setup.sh
#   less setup.sh        # 中身を確認
#   sudo bash setup.sh android.amgm.jp メールアドレス
#
# 何度実行しても大丈夫（済んでいる手順は飛ばす）。既存のサイトの設定は変更しない。
set -euo pipefail

DOMAIN="${1:-}"
EMAIL="${2:-}"
if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo "使い方: sudo bash setup.sh android.amgm.jp メールアドレス"; exit 1
fi
if [ "$(id -u)" != 0 ]; then echo "sudo を付けて実行してください"; exit 1; fi

ANDROID_VERSION=11.0.0
DATA_DIR=/opt/androidpad/data
APP_DIR=/opt/androidpad
SCRCPY_DIR=$APP_DIR/ws-scrcpy
REDROID_SCRIPT_DIR=$APP_DIR/redroid-script
CONTAINER=androidpad
step() { echo; echo "=== $* ==="; }

step "1/8 事前チェック"
. /etc/os-release
echo "$PRETTY_NAME / $(uname -r) / $(uname -m)"
[ "$(uname -m)" = x86_64 ] || { echo "x86_64 のサーバーでのみ動きます"; exit 1; }
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
echo "メモリ合計 ${mem_mb}MB / 空き ${avail_mb}MB / ディスク空き ${disk_gb}GB"
if [ "$mem_mb" -lt 3500 ]; then
  echo "メモリが足りません（合計 3.5GB 以上が必要）。プランの変更を検討してください"; exit 1
fi
if [ "$disk_gb" -lt 15 ]; then
  echo "ディスクの空きが足りません（15GB 以上が必要）"; exit 1
fi
# Android に割り当てるメモリ（ほかのサービス用に 1GB 以上は残す）
android_mem_mb=$(( mem_mb - 1024 ))
[ "$android_mem_mb" -gt 4096 ] && android_mem_mb=4096
echo "Android に割り当てるメモリの上限: ${android_mem_mb}MB"
SCRCPY_PORT=18000
for port in 80 443; do
  owner=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2 || true)
  if [ -n "$owner" ] && [ "$owner" != nginx ]; then
    echo "ポート $port を $owner が使っています。nginx と競合するのでここで止めます（設定を見て対応します）"; exit 1
  fi
done
if ss -ltnH "sport = :$SCRCPY_PORT" | grep -q .; then
  echo "ポート $SCRCPY_PORT が使用中です"; exit 1
fi
if systemctl is-active --quiet apache2 2>/dev/null; then
  echo "Apache が動いています。このスクリプトは nginx 前提なので、ここで止めます（設定を見て対応します）"; exit 1
fi

step "2/8 必要なパッケージ"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq "linux-modules-extra-$(uname -r)" adb lzip git curl python3 python3-venv \
  nginx certbot python3-certbot-nginx apache2-utils build-essential >/dev/null
# Docker は入っていなければ入れる（docker-ce が入っている場合はそのまま使う）
command -v docker >/dev/null || apt-get install -y -qq docker.io >/dev/null
systemctl enable --now docker >/dev/null

step "3/8 Android 用のカーネル機能（binder）"
cat > /etc/modules-load.d/androidpad.conf <<'EOF'
binder_linux
EOF
cat > /etc/modprobe.d/androidpad.conf <<'EOF'
options binder_linux devices="binder,hwbinder,vndbinder"
EOF
modprobe binder_linux devices="binder,hwbinder,vndbinder"
# 新しいカーネルでは /dev/binder は作られず binderfs 経由になる（redroid がコンテナ内でマウントする）
lsmod | grep -q '^binder_linux' && echo "binder_linux: 読み込み済み" || { echo "binder_linux を読み込めませんでした"; exit 1; }
grep -q binder /proc/filesystems && echo "binderfs: 対応" || echo "binderfs: なし（/dev/binder を使う）"

step "4/8 Android のイメージ（Google Play 入り）"
mkdir -p "$APP_DIR" "$DATA_DIR"
find_image() { docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "^redroid/redroid:${ANDROID_VERSION}_.*gapps" | head -1; }
IMAGE=$(find_image || true)
if [ -z "$IMAGE" ]; then
  if [ ! -d "$REDROID_SCRIPT_DIR" ]; then
    git clone -q https://github.com/ayasa520/redroid-script.git "$REDROID_SCRIPT_DIR"
  fi
  cd "$REDROID_SCRIPT_DIR"
  python3 -m venv venv
  venv/bin/pip install -q -r requirements.txt
  venv/bin/python3 redroid.py -a "$ANDROID_VERSION" -g
  cd - >/dev/null
fi
IMAGE=$(find_image || true)
[ -n "$IMAGE" ] || { echo "Google Play 入りのイメージができていません。上のログを送ってください"; docker images; exit 1; }
echo "使うイメージ: $IMAGE"

if [ -n "${STOP_BEFORE_RUN:-}" ]; then echo "STOP_BEFORE_RUN が指定されたのでここで終了（テスト用）"; exit 0; fi

step "5/8 Android を起動"
# 安全装置: 10 分以内に Android の起動確認まで行かなかったら（サーバーが固まった・通信が切れた場合）、
# Android を止めて自動起動を切り、それでもネットにつながらなければサーバーを再起動する
rm -f "$APP_DIR/confirmed"
systemctl stop androidpad-deadman.timer 2>/dev/null || true
systemd-run --unit=androidpad-deadman --on-active=10min --timer-property=AccuracySec=10s \
  /bin/sh -c "test -f $APP_DIR/confirmed || { docker update --restart=no $CONTAINER; docker stop -t 5 $CONTAINER; sleep 10; ping -c1 -W5 1.1.1.1 >/dev/null 2>&1 || systemctl reboot; }" >/dev/null
echo "安全装置を設定しました（10 分以内に起動を確認できなければ Android を自動で止めます）"
if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  # adb は 127.0.0.1 にだけ公開（外から直接つながらない）
  # ARM 専用アプリ（zeta など）は libndk_translation で動かす
  docker run -d --name "$CONTAINER" --privileged --restart unless-stopped \
    --memory "${android_mem_mb}m" \
    -v "$DATA_DIR":/data -p 127.0.0.1:5555:5555 "$IMAGE" \
    androidboot.redroid_width=720 androidboot.redroid_height=1280 androidboot.redroid_dpi=300 \
    androidboot.redroid_gpu_mode=guest androidboot.use_memfd=true \
    ro.product.cpu.abilist=x86_64,arm64-v8a,x86,armeabi-v7a,armeabi \
    ro.product.cpu.abilist64=x86_64,arm64-v8a \
    ro.product.cpu.abilist32=x86,armeabi-v7a,armeabi \
    ro.dalvik.vm.isa.arm=x86 ro.dalvik.vm.isa.arm64=x86_64 \
    ro.enable.native.bridge.exec=1 ro.dalvik.vm.native.bridge=libndk_translation.so \
    ro.ndk_translation.version=0.2.2 >/dev/null
else
  docker update --restart unless-stopped "$CONTAINER" >/dev/null
  docker start "$CONTAINER" >/dev/null
fi
echo "起動を待っています（初回は数分。最大 5 分）..."
for i in $(seq 1 60); do
  adb connect 127.0.0.1:5555 >/dev/null 2>&1 || true
  if [ "$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
    echo "Android が起動しました"
    # サーバーが固まらずに起動まで行けたので、安全装置を解除する
    touch "$APP_DIR/confirmed"
    systemctl stop androidpad-deadman.timer 2>/dev/null || true
    echo "安全装置を解除しました"
    break
  fi
  sleep 5
done

step "6/8 画面配信（ws-scrcpy）"
if ! command -v node >/dev/null || [ "$(node -v | tr -dc 0-9 | cut -c1-2)" -lt 18 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
if [ ! -d "$SCRCPY_DIR" ]; then
  git clone -q https://github.com/NetrisTV/ws-scrcpy.git "$SCRCPY_DIR"
fi
if [ ! -f "$SCRCPY_DIR/dist/index.js" ]; then
  cd "$SCRCPY_DIR"
  npm install --silent
  npm run dist --silent
  cd dist && npm install --silent --omit=dev
  cd - >/dev/null
fi
# ws-scrcpy の設定
cat > "$SCRCPY_DIR/dist/config.yaml" <<EOF
server:
  - secure: false
    port: $SCRCPY_PORT
EOF
# ws-scrcpy は全インターフェースで待ち受けるので、外からの直接接続を遮断する（nginx 経由のみ許可）
cat > /usr/local/sbin/androidpad-firewall <<EOF
#!/bin/sh
iptables -C INPUT -p tcp --dport $SCRCPY_PORT ! -s 127.0.0.1 -j DROP 2>/dev/null || iptables -I INPUT -p tcp --dport $SCRCPY_PORT ! -s 127.0.0.1 -j DROP
ip6tables -C INPUT -p tcp --dport $SCRCPY_PORT ! -s ::1 -j DROP 2>/dev/null || ip6tables -I INPUT -p tcp --dport $SCRCPY_PORT ! -s ::1 -j DROP 2>/dev/null || true
EOF
chmod +x /usr/local/sbin/androidpad-firewall
/usr/local/sbin/androidpad-firewall
# Android が再起動しても adb がつながり直すようにする
cat > /etc/systemd/system/androidpad-adb.service <<'EOF'
[Unit]
Description=Androidpad adb keep-connected
After=docker.service

[Service]
ExecStart=/bin/sh -c 'while true; do /usr/bin/adb connect 127.0.0.1:5555 >/dev/null 2>&1; sleep 30; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/androidpad-scrcpy.service <<EOF
[Unit]
Description=Androidpad screen streaming (ws-scrcpy)
After=docker.service network-online.target
Wants=docker.service

[Service]
WorkingDirectory=$SCRCPY_DIR/dist
Environment=WS_SCRCPY_CONFIG=$SCRCPY_DIR/dist/config.yaml
ExecStartPre=/usr/local/sbin/androidpad-firewall
ExecStartPre=-/usr/bin/adb connect 127.0.0.1:5555
ExecStart=/usr/bin/node index.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now androidpad-adb >/dev/null
systemctl enable --now androidpad-scrcpy >/dev/null
systemctl restart androidpad-scrcpy

step "7/8 nginx（パスワード付き HTTPS）"
PASS_FILE=/etc/nginx/androidpad.htpasswd
TOKEN_FILE=/etc/nginx/androidpad.token
NEW_PASSWORD=""
if [ ! -s "$TOKEN_FILE" ]; then
  NEW_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)
  printf '%s' "$NEW_PASSWORD" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  htpasswd -bc "$PASS_FILE" android "$NEW_PASSWORD" >/dev/null
fi
TOKEN=$(cat "$TOKEN_FILE")
cat > /etc/nginx/sites-available/androidpad <<EOF
# アプリはクッキー（androidpad_token）で、ブラウザは Basic 認証で入れる
map \$cookie_androidpad_token \$androidpad_auth {
    "$TOKEN" off;
    default  "Androidpad";
}

server {
    listen 80;
    server_name $DOMAIN;

    auth_basic \$androidpad_auth;
    auth_basic_user_file $PASS_FILE;

    location / {
        proxy_pass http://127.0.0.1:$SCRCPY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
        proxy_buffering off;
    }
}
EOF
ln -sf /etc/nginx/sites-available/androidpad /etc/nginx/sites-enabled/androidpad
nginx -t
systemctl reload nginx
if [ -n "${SKIP_CERT:-}" ]; then
  echo "SKIP_CERT が指定されたので証明書は取りません（テスト用）"
elif [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect
fi

step "8/8 完了"
echo "URL:        https://$DOMAIN/"
echo "ユーザー名: android"
if [ -n "$NEW_PASSWORD" ]; then
  echo "パスワード: $NEW_PASSWORD   ← アプリに入れるので控えてください（ここでしか表示されません）"
else
  echo "パスワード: 前回表示したもの（確認するには: sudo cat /etc/nginx/androidpad.token）"
fi
echo "Android の状態: $(docker ps --filter name=$CONTAINER --format '{{.Status}}')"
echo "メモリ: $(free -h | awk '/Mem/ {print $3 " 使用 / " $2}')"
