#!/usr/bin/env python3
"""アプリと同じ構成で Android-x86 を QEMU で起動し、シリアルのログと画面の様子を出力する

使い方: boot_test.py 一式のフォルダ 分数 tcg|kvm
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time

from PIL import Image

preset, minutes, accel = sys.argv[1], float(sys.argv[2]), sys.argv[3]
cmdline = open(os.path.join(preset, "cmdline.txt")).read().strip()
# 確認用にシリアルにもログを出す（アプリでは付けない）
test_cmdline = cmdline + " console=ttyS0,115200 console=tty0 printk.devkmsg=on loglevel=8"
cpu = os.environ.get("CPU") or "max"

# 書き込みでアプリ用の元ファイルを汚さないようコピーを使う
subprocess.run(["cp", os.path.join(preset, "data.qcow2"), "/tmp/data.qcow2"], check=True)

qmp_path = "/tmp/qmp.sock"
args = [
    "qemu-system-x86_64",
    "-nodefaults", "-vga", "none", "-display", "none",
    "-device", "e1000,netdev=net0", "-netdev", "user,id=net0",
    "-device", "VGA",
    "-cpu", cpu if accel == "tcg" else "host",
    "-smp", "cpus=4,sockets=1,cores=4,threads=1",
    "-machine", "q35,vmport=off,i8042=off,hpet=off",
    "-accel", "tcg,tb-size=512" if accel == "tcg" else "kvm",
    "-m", "2048",
    "-audiodev", "none,id=audio0", "-device", "intel-hda", "-device", "hda-duplex,audiodev=audio0",
    "-usb", "-device", "usb-tablet,bus=usb-bus.0", "-device", "usb-mouse,bus=usb-bus.0",
    "-device", "usb-kbd,bus=usb-bus.0",
    "-kernel", os.path.join(preset, "kernel"),
    "-initrd", os.path.join(preset, "initrd.img"),
    # アプリ（修正後）と同じく bootindex は付けない
    "-device", "ide-cd,bus=ide.0,drive=cd0",
    "-drive", f"if=none,media=cdrom,id=cd0,file.filename={os.path.join(preset, 'android.iso')},file.locking=off,readonly=on",
    "-device", "ide-hd,bus=ide.1,drive=hd0",
    "-drive", "if=none,media=disk,id=hd0,file.filename=/tmp/data.qcow2,discard=unmap,detect-zeroes=unmap",
    "-device", "virtio-rng-pci",
    "-serial", "file:/tmp/serial.log",
    "-qmp", f"unix:{qmp_path},server=on,wait=off",
    "-append", test_cmdline,
]
print("起動コマンド:", " ".join(args), flush=True)
start = time.time()
proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def pump_qemu_output():
    for line in proc.stdout:
        print(f"[qemu] {line.rstrip()}", flush=True)


threading.Thread(target=pump_qemu_output, daemon=True).start()


def qmp_screendump(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect(qmp_path)
    f = s.makefile("rw")
    f.readline()
    # 画面が消灯していたら起こすため、シフトキーを押してから撮る
    wake = {"execute": "send-key", "arguments": {"keys": [{"type": "qcode", "data": "shift"}]}}
    for cmd in ({"execute": "qmp_capabilities"}, wake,
                {"execute": "screendump", "arguments": {"filename": path}}):
        f.write(json.dumps(cmd) + "\n")
        f.flush()
        while True:
            reply = json.loads(f.readline())
            if "return" in reply or "error" in reply:
                break
    s.close()
    return reply


def describe_screen(path):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    small = img.resize((min(w, 320), min(h, 200)))
    px = list(small.getdata())
    lit = sum(1 for r, g, b in px if r + g + b > 60)
    colors = len(set((r // 32, g // 32, b // 32) for r, g, b in px))
    mean = sum(r + g + b for r, g, b in px) / (3 * len(px))
    # 色が多い＝グラフィカルな画面（ロゴやホーム）、少ない＝文字のコンソールか真っ黒
    kind = "真っ黒" if lit < len(px) * 0.002 else ("文字のコンソール" if colors <= 6 else "グラフィカルな画面")
    # 縮小した画面を PNG の base64 でログに出す（ログから復元して確認する）
    import base64, io
    buf = io.BytesIO()
    img.resize((256, 160)).save(buf, format="PNG", optimize=True)
    print("[png] " + base64.b64encode(buf.getvalue()).decode(), flush=True)
    return f"{w}x{h} 明るい画素 {100 * lit / len(px):.1f}% 色数 {colors} 平均輝度 {mean:.0f} → {kind}"


serial_pos = 0
deadline = start + minutes * 60
last_shot = 0
markers = ("Kernel panic", "panic", "Detecting Android-x86", "found at /dev", "Android-x86",
           "Could not find", "mount", "sda", "init:", "boot_completed", "SurfaceFlinger",
           "bootanim", "zygote", "error", "Error", "failed", "FAILED")
while time.time() < deadline and proc.poll() is None:
    time.sleep(5)
    try:
        with open("/tmp/serial.log", "rb") as f:
            f.seek(serial_pos)
            chunk = f.read()
            serial_pos += len(chunk)
        for line in chunk.decode(errors="replace").splitlines():
            line = line.strip()
            if line:
                print(f"[serial {int(time.time() - start):4d}s] {line[:300]}", flush=True)
    except FileNotFoundError:
        pass
    if time.time() - last_shot >= 60:
        last_shot = time.time()
        try:
            time.sleep(2)
            r = qmp_screendump("/tmp/screen.ppm")
            if "error" in r:
                print(f"[screen] 取得失敗: {r['error']}", flush=True)
            else:
                print(f"[screen {int(time.time() - start):4d}s] {describe_screen('/tmp/screen.ppm')}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"[screen] 取得失敗: {e}", flush=True)

code = proc.poll()
if code is None:
    print(f"{minutes:.0f} 分経過したので停止します（QEMU は動き続けていた）", flush=True)
    proc.terminate()
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        proc.kill()
else:
    print(f"::error::QEMU が {int(time.time() - start)} 秒で終了しました（終了コード {code}）", flush=True)
    sys.exit(1)
