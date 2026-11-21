#!/usr/bin/env bash
# Android サーバー化の前に、VPS の状態を確認する（読み取りだけ。何も変更しない）
echo "== OS / カーネル"; . /etc/os-release; echo "$PRETTY_NAME"; uname -r; uname -m
echo "== CPU"; nproc; grep -m1 "model name" /proc/cpuinfo
echo "== メモリ"; free -h
echo "== ディスク"; df -h / | tail -1
echo "== 仮想化"; systemd-detect-virt 2>/dev/null || true
echo "== binder モジュール"
if modinfo binder_linux >/dev/null 2>&1; then echo "binder_linux: あり"; else echo "binder_linux: なし（linux-modules-extra が必要）"; fi
ls /dev/binder* /dev/binderfs 2>/dev/null || echo "/dev/binder: なし"
echo "== Docker"; (docker --version 2>/dev/null || echo "なし"); (docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null || true)
echo "== Node.js"; node -v 2>/dev/null || echo "なし"
echo "== Web サーバー"
for s in nginx apache2 caddy; do systemctl is-active --quiet $s 2>/dev/null && echo "$s: 動作中"; done
ls /etc/nginx/sites-enabled 2>/dev/null
echo "== 使用中のポート"; (sudo -n ss -ltnp 2>/dev/null || ss -ltn) | awk 'NR>1{print $4, $6}' | sort -u | head -30
echo "== 動いているサービス（主なもの）"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -vE '^(systemd|dbus|cron|ssh|rsyslog|polkit|getty|user@|networkd|udisks|unattended|snapd|multipathd|irqbalance|ModemManager|packagekit)' | head -30
echo "== 証明書（certbot）"; (sudo -n certbot certificates 2>/dev/null | grep -E "Domains|Expiry" || echo "certbot なし or sudo パスワードが必要")
echo "== 完了"
