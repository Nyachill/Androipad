#!/usr/bin/env python3
"""Mach-O の LC_LOAD_DYLIB を LC_LOAD_WEAK_DYLIB に書き換える（そのライブラリが無くても起動できるようにする）

使い方: weaken_dylib.py バイナリ ライブラリのパス
例:     weaken_dylib.py qemu-x86_64-softmmu @rpath/dxmt-native.framework/dxmt-native
署名は無効になるので、あとで署名し直すこと（xcodebuild -exportArchive が署名し直す）。
"""
import struct
import sys

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


def patch_slice(buf: bytearray, base: int, target: bytes) -> int:
    magic = struct.unpack_from("<I", buf, base)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit(f"64bit の Mach-O ではありません（magic={magic:#x}）")
    ncmds = struct.unpack_from("<I", buf, base + 16)[0]
    off = base + 32  # mach_header_64 のサイズ
    count = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmd == LC_LOAD_DYLIB:
            name_off = struct.unpack_from("<I", buf, off + 8)[0]
            raw = bytes(buf[off + name_off : off + cmdsize])
            name = raw.split(b"\0", 1)[0]
            if name == target:
                struct.pack_into("<I", buf, off, LC_LOAD_WEAK_DYLIB)
                count += 1
        off += cmdsize
    return count


def main() -> int:
    path, target = sys.argv[1], sys.argv[2].encode()
    with open(path, "rb") as f:
        buf = bytearray(f.read())
    magic_be = struct.unpack_from(">I", buf, 0)[0]
    count = 0
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", buf, 4)[0]
        for i in range(nfat):
            if magic_be == FAT_MAGIC:
                _, _, offset, _, _ = struct.unpack_from(">iiIII", buf, 8 + i * 20)
            else:
                _, _, offset, _, _, _ = struct.unpack_from(">iiQQII", buf, 8 + i * 32)
            count += patch_slice(buf, offset, target)
    else:
        count += patch_slice(buf, 0, target)
    if count == 0:
        print(f"{path}: {target.decode()} の読み込みは見つかりませんでした")
        return 0
    with open(path, "wb") as f:
        f.write(buf)
    print(f"{path}: {target.decode()} を弱リンクにしました（{count} か所）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
