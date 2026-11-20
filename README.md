# Android for iPad（TestFlight 用）

UTM SE（App Store 版と同じ、JIT を使わない QEMU）に **Android-x86 9.0** を同梱した iPad アプリです。
初回起動時に「Android」という仮想マシンが自動で作られ、▶ を押すだけで Android が起動します。

- ビルドは GitHub Actions の Mac で行い、そのまま TestFlight にアップロードします（Xcode・Mac 不要）
- 脱獄・サイドロード・JIT の有効化は不要。TestFlight から普通に入れるだけ
- 速度は App Store の UTM SE と同じです（JIT が使えないため遅い）。起動には十数分〜かかることがあります

## 中身

| 場所 | 内容 |
|---|---|
| `patches/0001-android-preset.patch` | UTM への変更。アプリ内の `qemu/android` に Android 一式があれば、初回起動時に VM を作る |
| `scripts/prepare_android.sh` | ISO を落とし、kernel / initrd を取り出し、`/data` 用のディスク（ext4・16GB）を作る |
| `.github/workflows/testflight.yml` | 上の 2 つを使って UTM SE をビルドし、TestFlight に上げる |

VM の設定：x86_64（q35）、CPU 4 コア（`max`）、メモリ 3GB、画面 VGA、ISO を CD、`/data` 用ディスクを IDE で接続。
カーネル引数：`root=/dev/ram0 androidboot.selinux=permissive HWACCEL=0 SRC= DATA=sda video=1280x800`

## 準備（初回だけ）

SNS ブロッカーと同じ Apple 側の設定を流用できます。

### 1. バンドル ID を登録（developer.apple.com）

Identifiers → ＋ → App IDs → App で次を登録（`jp.amgm.android` の部分は好きに決めてよい。これが `BUNDLE_PREFIX`）。

- `jp.amgm.android.UTM-SE` … Capabilities で **App Groups**、**Increased Memory Limit**、**Extended Virtual Addressing** にチェック
- （`jp.amgm.android.UTM-SE.iOSHelper` は UTM v5.0.6 以降で使う。今の v5.0.5 では不要）

末尾の `.UTM-SE` と `.UTM-SE.iOSHelper` は変えないでください（UTM 側で決まっています）。

### 2. App Store Connect でアプリを作成

アプリ → ＋ → 新規 App。バンドル ID に `jp.amgm.android.UTM-SE` を選ぶ。名前は「Android Pad」など、ストアで重複しないもの。

### 3. GitHub の Secrets を登録

このリポジトリの Settings → Secrets and variables → Actions に 5 つ登録します。
`BUNDLE_PREFIX` 以外は SNS ブロッカーと同じ値です。

| 名前 | 値 |
|---|---|
| `ASC_KEY_ID` | API キーのキー ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | `.p8` ファイルの中身（BEGIN〜END の行まで全部） |
| `TEAM_ID` | Team ID |
| `BUNDLE_PREFIX` | 1 で決めた前半部分（例 `jp.amgm.android`） |

## ビルド

Actions → TestFlight → Run workflow。

- **初回**は QEMU 一式（sysroot）の用意が入ります。UTM 公式のビルド済みを取れれば数分、取れなければ自分でビルドするため 1〜3 時間かかります。2 回目以降はキャッシュを使うので 20〜30 分ほどです
- アップロード後、App Store Connect 側の処理に数分〜十数分。終わると iPad の TestFlight アプリに出てきます

### 公開リポジトリにする理由

GitHub の Mac は非公開リポジトリだと無料枠を 10 倍の速さで消費します（初回の sysroot ビルドだけで枠を使い切ることがある）。
公開リポジトリなら無料・無制限です。Secrets は公開しても外からは見えません。

## 使い方

1. TestFlight から入れて起動 →「Android」の VM が自動で作られる（初回だけ数十秒）
2. ▶ で起動。黒い画面に文字が流れたあと Android のロゴ → ホーム画面
3. 設定やインストールしたアプリは `/data` 用ディスクに保存されるので、再起動しても残ります

### 画面が真っ黒のまま進まないとき

VM を長押し → Edit → QEMU → Arguments の `-append` の次の行（カーネル引数）を編集します。

- `HWACCEL=0` を消す、または `nomodeset` を足す
- 画面の解像度は `video=1280x800` の部分

次のビルドから既定値を変えたいときは、Run workflow の `cmdline` に入れるか、ワークフローの `DEFAULT_CMDLINE` を書き換えます。

## 注意

- Google Play は入っていません。アプリは Android 内のブラウザで APK を落として入れます
- 多くのスマホアプリは ARM 用です。Android-x86 の設定（Android-x86 options）にある native bridge を有効にすると動く場合がありますが、この速度では実用は厳しいです
- 土台の UTM のバージョンはワークフローの `UTM_TAG` で固定しています。上げるときはパッチが当たるか確認してください
- UTM は Apache License 2.0、QEMU は GPL v2、Android-x86 は Apache License 2.0 / GPL です
