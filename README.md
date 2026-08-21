# Kotone

Gecko エンジンを用いた iOS 向け音楽プレイヤー。

> **名前は仮です。** `./scripts/rename.sh <NewName> <com.new.bundleid>` で変更できます。

---

## これは何か

WebKit ではなく **Gecko**（Firefox のエンジン）を組み込み、その中で音楽サービスの
公式 Web プレイヤーを動かします。UI とロック画面制御、音声処理はネイティブ側で行います。

WKWebView では実現できない以下を目的としています。

- `webRequest` によるリクエストの観測・改変
- エンジンをプロセス内に持つことによる音声出力の掌握（cubeb → `AVAudioEngine`）
- Media Session API のネイティブ受信（`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`）
- WebExtension 形式でのスクリプト注入

## 免責

本プロジェクトは Mozilla Foundation、Google LLC、YouTube、およびそれらの関連会社と
一切関係がなく、承認も推奨も受けていません。各サービス名・商標は識別目的でのみ
言及しています。個人利用を目的とした非商用の実験的プロジェクトです。

---

## 由来と謝辞

本プロジェクトは以下の成果物に依拠しています。

| 出所 | 利用範囲 | ライセンス |
|---|---|---|
| [minh-ton/reynard-browser](https://github.com/minh-ton/reynard-browser) | Gecko の iOS 移植、`GeckoView` Swift 層、Helper プロセス、JIT 有効化 | GPL-3.0 |
| [reynard-browser の `patches/`](https://github.com/minh-ton/reynard-browser/tree/main/patches) | Gecko エンジン本体への改変 | MPL-2.0 |
| [Mozilla Firefox](https://github.com/mozilla-firefox/firefox) | Gecko エンジン (`FIREFOX_153_0_4_RELEASE`) | MPL-2.0 |
| [pear-devs/pear-desktop](https://github.com/pear-devs/pear-desktop) | プラグイン設計、Web Audio によるオーディオ加工の実装 | MIT |
| [th-ch/youtube-music](https://github.com/th-ch/youtube-music) | pear-desktop の上流 | MIT |

Gecko エンジンは **Reynard の配布 IPA から抽出したビルド済みバイナリ**を使用し、
本リポジトリ内でのビルドは行いません。対応するソースは
`engine/VERSION.txt` に記録したタグから辿れます。

### ライセンス

本プロジェクト全体は **GPL-3.0** です（`LICENSE`）。

- `engine/` に配置される Gecko バイナリおよびその改変は **MPL-2.0**（`LICENSE.mpl`）
- 取り込んだ MIT ライセンス部分の表示は `THIRD_PARTY_NOTICES.md`

---

## 構成

```
.
├─ project.yml              XcodeGen 定義
├─ .github/workflows/
│   ├─ build.yml            未署名 IPA を生成
│   └─ probe-toolchain.yml  Xcode / SDK / XUL リンク可否の切り分け
├─ engine/
│   ├─ VERSION.txt          Gecko / Reynard のバージョン固定（要更新管理）
│   └─ dist/                fetch-engine.sh が生成。git 管理外（約 280MB）
├─ scripts/
│   ├─ fetch-engine.sh      Reynard IPA → engine/dist/bin
│   ├─ fetch-headers.sh     Gecko ヘッダ再構成 → engine/dist/include
│   ├─ import-reynard.sh    Reynard の Swift ラッパ層 → Sources/
│   ├─ AddGecko.sh          Xcode Run Script。engine/dist → .app/Frameworks
│   ├─ enable-gecko.sh      Gecko 統合の ON/OFF を一括切り替え
│   └─ rename.sh            アプリ名・Bundle ID の一括変更
├─ docs/
│   ├─ PLACEMENT.md         Reynard ソース配置マップ
│   └─ VIVIMUSIC.md         ViviMusic 取り込み内容と PlayerManager の契約
├─ Sources/               ※ App/ 以外は import-reynard.sh が埋める（git 管理外）
│   ├─ App/                 独自。main.swift / SceneDelegate / 診断画面
│   ├─ Vivi/                ViviMusic から取り込んだ UI と InnerTube（git 管理下）
│   ├─ Bridging/            独自の Kotone-Bridging-Header.h + 取り込み分
│   ├─ GeckoView/           ← browser/GeckoView/
│   ├─ Helper/              ← browser/Helper/
│   ├─ Shared/              ← browser/Reynard/Shared/
│   ├─ ThirdParty/          ← browser/Reynard/ThirdParty/
│   └─ JIT/                 ← 既定では取り込まない（docs/PLACEMENT.md）
├─ Extension/               WebExtension（pear-desktop プラグインの移植先）
├─ LICENSE                  GPL-3.0
├─ LICENSE.mpl              MPL-2.0（Gecko / patches）
├─ THIRD_PARTY_NOTICES.md
└─ CHANGELOG.md
```

配置の詳細は **`docs/PLACEMENT.md`** を参照してください。

Reynard の `browser/Reynard/Client/`（タブ・ブックマーク・履歴などの
ブラウザ UI）は移植しません。

---

## ⚠️ 変更してはいけないもの

### `PRODUCT_NAME: "Reynard Helper"`

Gecko（XUL）が子プロセスを起動する際、アプリの `PlugIns/` を走査して
**`Reynard Helper.appex` というファイル名で完全一致検索**します。

```objc
// reynard-browser patches/ipc/glue/NSExtensionUtils.mm.patch:143
if ([[itemURL lastPathComponent] isEqualToString:@"Reynard Helper.appex"]) {
  preferredExtensionURL = itemURL;
  break;
}
// This is bad, but I don't know of a better way for this.
if (!preferredExtensionURL) {
  preferredExtensionURL = appExtensions.firstObject;   // ← 順序不定
}
```

見つからない場合は「最初に列挙された .appex」にフォールバックしますが、
`contentsOfDirectoryAtURL` の順序は保証されません。**2つ目の拡張機能を追加した
時点で非決定的に壊れます。**

- アプリ名・Bundle ID・Helper の Bundle ID は自由に変更できます
- **Helper の `.appex` ファイル名だけは固定**してください

### `engine/dist/` のレイアウト

`XUL` / `*.dylib` / `GeckoView.framework/Frameworks/**` の相対配置は
Reynard の配布 IPA と完全に一致させてください。XUL はこの配置を前提に
リソースを解決します。

---

## 段階的な進め方

Gecko の統合は依存が多いため、**配管の検証を先に完了させます。**

| 段階 | 内容 | Gecko | 判定 |
|---|---|---|---|
| **0-A** | Reynard 本体が実機で動く | ✅ | 済（ペアリング JIT / 子プロセス起動が確認済み） |
| **0-B1** | 独自アプリの配管検証 | ❌ | `build.yml` を既定（`gecko_integration=false`）で実行 |
| **0-B2** | Gecko 統合 | ✅ | `gecko_integration=true` + `project.yml` の依存を有効化 |
| **1** | `music.youtube.com` の測定 | ✅ | 65 秒問題の検証 |

**0-B1 で確認すること:**

XcodeGen → xcodebuild → 未署名 IPA → SideStore インストール → 起動、
という経路が通ることだけを見ます。Gecko は組み込まれません。

起動すると診断画面が出ます。この段階では
`Frameworks/XUL` と `Gecko resources` が ❌、
`PlugIns/Reynard Helper.appex` も ❌ になりますが、**それが正常**です。
Bundle Identifier とバージョンが期待どおりに出ていれば合格です。

**0-B2 に進む手順:**

**Phase 0 は完了済みで、`project.yml` は Gecko 有効の状態でコミットしてあります。**
push すればそのままビルドされます。手動実行する場合も
`gecko_integration` は既定の `auto` のままで構いません。

> ⚠️ `off` にすると必ずビルドが失敗します。
> Phase 1 以降 `Sources/App` が `import GeckoView` を含むためです。
> 0-B1（Gecko 無しの配管検証）に戻す目的でのみ使ってください。

Reynard の Swift ラッパ層は **リポジトリにコミットせず、ビルド時に取得**します
（`scripts/import-reynard.sh`）。取得元とタグは `engine/VERSION.txt` で固定されています。

手元でも試したい場合:

```bash
./scripts/import-reynard.sh          # Sources/ に展開
./scripts/import-reynard.sh --clean  # 取り込み分を削除
```

0-B1 に戻したくなったら `./scripts/enable-gecko.sh --disable` です。
現在の状態は `--status` で確認できます。

`enable-gecko.sh` はソースが未配置だと有効化を拒否します
（意図的に空で試すなら `--force`）。

**JIT は 0-B2 では含めません。** `Sources/JIT/` が要求する
`libidevice_ffi.a` は Reynard のリポジトリにも配布 IPA にも含まれておらず、
Rust でのビルドが必要なためです。Gecko は JIT なしでも動作します
（インタプリタ実行になり遅いだけ）。詳細と後から入れる手順は
`docs/PLACEMENT.md` の「JIT について」を参照してください。

```bash
./scripts/enable-gecko.sh --status       # Gecko / JIT それぞれの状態
./scripts/enable-gecko.sh --with-jit     # JIT を有効化（独立）
./scripts/enable-gecko.sh --without-jit  # JIT を無効化（独立）
```

ワークフローの `gecko_integration` 入力は既定 `auto` で、
**`project.yml` の状態から自動判定**します。
入力と実際の状態がズレたら警告が出ます。

ヘッダの問題（`TSUtils.h` ほか）は rev.3 で、
ツールチェーンの選定は rev.4 で解決済みです。

### ツールチェーン

`probe-toolchain` の検証結果（72 通り全 CLEAN）により、
**`XUL` へのリンクに Xcode バージョンの制約は無い**ことが判明しています
（15.0.1 〜 26.4.1、deployment target 15.0 / 18.0 / 26.0 のすべてで警告ゼロ）。

それでも `build.yml` は `macos-26` + 最新の Xcode 26.x を使います。
リンクではなく Swift ソース側の理由で、Reynard 上流のビルド環境
（Xcode 26.6 / iOS SDK 26.5）に揃えておくためです。

---

## ビルド

### 1. Gecko エンジンの取得（0-B2 以降）

```bash
./scripts/fetch-engine.sh
```

`engine/VERSION.txt` に記載のリリースから IPA を落とし、`BuildID` と `Milestone`
を検証してから `engine/dist/bin/` を再構成します。ローカルに IPA がある場合は
引数で渡せます。

```bash
./scripts/fetch-engine.sh ~/Downloads/Reynard.ipa
```

一般的なブラウジングもさせたい場合は辞書類を残します。

```bash
KEEP_DICTIONARIES=1 ./scripts/fetch-engine.sh
```

続いて Gecko のヘッダを再構成します。配布 IPA に `.h` は含まれないため、
ここだけソースから作ります（firefox の clone は不要）。

```bash
./scripts/fetch-headers.sh
```

`engine/dist/include/GeckoView/` に 3 ファイルが生成されます。

### 2. プロジェクト生成とビルド

```bash
xcodegen generate
open Kotone.xcodeproj
```

CI では GitHub Actions（`.github/workflows/build.yml`）が未署名 IPA を生成します。
署名は SideStore 側で行われます。

### 3. インストール

SideStore でインストールする際、**「Keep App Extensions」を必ず有効**にしてください。
Helper がなければ Gecko は起動しません。

JIT はペアリング方式で有効化されます（`Sources/JIT/`）。

---

## Phase 0 の完了条件

以下がすべて満たされたら Phase 1 へ進みます。

- [ ] 独自名・独自 Bundle ID で署名した IPA が SideStore でインストールできる
- [ ] ペアリング JIT が有効化される（`JITController` のログ）
- [ ] **Gecko が子プロセスを起動できる**（`Reynard Helper.appex` 名前固定の検証点）
- [ ] 任意のページ（`example.com` 等）が描画される
- [ ] Gecko のバージョンが取得できる（`GeckoRuntime.version`）

## Phase 1 で測定すること

測定用の最小ブラウザ (`Sources/App/BrowserViewController.swift`) が
起動時に `music.youtube.com` を開きます。
ツールバーの 🖥 が UA 切替、🧩 がアドオン、📋 が測定ログ、✓ がバンドル診断です。

アドオン（WebExtension）は 🧩 から導入します。
`addons.mozilla.org` を開くと自動的に Android 版の UA に切り替わります。
デスクトップ表示のままだと「Firefox へ追加」ボタンが出ないためです。

65 秒問題は経過時間ではなく `MediaSession` の `positionState`
（ページ内の実再生位置）の最大値で判定します。

| # | 項目 | 判定 |
|---|---|---|
| 1 | **公式プレイヤーで 65 秒を超えて連続再生できるか** | **No なら構想全体を見直す** |
| 2 | `MediaSessionDelegate.onMetadata` に曲情報が届くか | ロック画面対応の可否 |
| 3 | デスクトップ UA で iPad の表示が実用に耐えるか | UI 方針の分岐 |
| 4 | ログインできるか | Premium / ライブラリの可否 |
| 5 | バックグラウンドで再生が継続するか | `UIBackgroundModes: audio` の効き |
| 6 | メモリ使用量（iPad 第9世代 / 3GB） | 実用性の下限 |

**1 以外は後回しで構いません。**

## 以降の予定

- Phase 2 — WebExtension ↔ Swift のメッセージブリッジ（Gecko 側パッチ追加）
- Phase 3 — `MediaSessionDelegate` → `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`
- Phase 4 — pear-desktop の renderer プラグイン移植（content script 化）
- Phase 5 — cubeb tap → `AVAudioEngine`（EQ / クロスフェード / ラウドネス正規化）
