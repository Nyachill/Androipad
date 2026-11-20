#!/usr/bin/env python3
"""過去の CI 実行で Xcode が作った開発用証明書（"Created via API"）を App Store Connect API で削除する。

GitHub の Mac は実行のたびに新品なので、Xcode は毎回新しい開発用証明書を作る。放置すると
Apple の上限に達して「Choose a certificate to revoke」で署名に失敗する。
削除するのは「種類が Development」かつ「名前に Created via API を含む」ものだけ。
配布用（DISTRIBUTION）の証明書と、手元の Mac で作った証明書には触らない。

外部ライブラリ不要: JWT の署名は openssl コマンドで行う。
環境変数: KEY_PATH（.p8 のパス）, ASC_KEY_ID, ASC_ISSUER_ID
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
MARK = "Created via API"
DEV_TYPES = ("DEVELOPMENT", "IOS_DEVELOPMENT")


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """ECDSA の DER 署名 (SEQUENCE { INTEGER r, INTEGER s }) を JWT 用の r||s (64 bytes) に変換"""
    assert der[0] == 0x30, "DER の先頭が SEQUENCE ではない"
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    assert der[i] == 0x02
    rl = der[i + 1]
    r = der[i + 2 : i + 2 + rl]
    i = i + 2 + rl
    assert der[i] == 0x02
    sl = der[i + 1]
    s = der[i + 2 : i + 2 + sl]
    r = r.lstrip(b"\x00").rjust(32, b"\x00")
    s = s.lstrip(b"\x00").rjust(32, b"\x00")
    return r + s


def make_jwt(key_path: str, key_id: str, issuer_id: str) -> str:
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = (
        b64u(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64u(json.dumps(payload, separators=(",", ":")).encode())
    )
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode(),
        capture_output=True,
        check=True,
    ).stdout
    return signing_input + "." + b64u(der_to_raw(der))


def request(token: str, method: str, path: str):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read()
        return resp.status, (json.loads(body) if body else None)


def main() -> int:
    key_path = os.environ["KEY_PATH"]
    key_id = os.environ["ASC_KEY_ID"]
    issuer_id = os.environ["ASC_ISSUER_ID"]
    token = make_jwt(key_path, key_id, issuer_id)

    _, data = request(
        token, "GET",
        "/certificates?limit=200&fields[certificates]=name,displayName,certificateType,expirationDate",
    )
    certs = data.get("data", [])
    print(f"証明書 {len(certs)} 件")

    targets = []
    for c in certs:
        a = c.get("attributes", {})
        ctype = a.get("certificateType", "")
        label = f'{a.get("displayName") or ""} / {a.get("name") or ""}'
        print(f'  {ctype:18} {label}  期限 {(a.get("expirationDate") or "")[:10]}')
        if ctype in DEV_TYPES and MARK in label:
            targets.append(c["id"])

    print(f"削除対象（開発用・{MARK}）: {len(targets)} 件")
    deleted = 0
    for cid in targets:
        try:
            request(token, "DELETE", f"/certificates/{cid}")
            deleted += 1
        except urllib.error.HTTPError as e:
            print(f"  削除失敗 {cid}: HTTP {e.code} {e.read()[:200]!r}")
    print(f"削除 {deleted} 件")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # 整理に失敗してもビルドは続ける（ワークフロー側で continue-on-error）
        print(f"::warning::証明書の整理に失敗: {e}")
        sys.exit(1)
