# ソース配置マップ

Reynard から流用するソースの対応関係です。

> **手動配置は不要です。** `scripts/import-reynard.sh` が
> `engine/VERSION.txt` の `REYNARD_TAG` からソースを取得して展開します。
> CI では `Import Reynard sources` ステップが自動実行します。
> この文書は「何がどこから来ているか」の記録です。

> ⚠️ **`engine/VERSION.txt` の `REYNARD_TAG` と同じコミットのソースを使ってください。**
> Gecko 側パッチ（`patches/`）と Swift ラッパ層は対で設計されているため、
> バージョンを混ぜると無言で壊れます。現在の固定値は `0.10.1` です。

## 流用するもの

| 配置先 | Reynard 側 | 行数 | 備考 |
|---|---|---|---|
| `Sources/GeckoView/` | `browser/GeckoView/` | 4,459 | 分解しないこと。`EventDispatcher` のプロトコルが Gecko 側パッチと対応。**`View/GeckoView.h` は除外済み**（下記） |
| `Sources/Helper/` | `browser/Helper/` | 約 200 | `PRODUCT_NAME` は `Reynard Helper` 固定 |
| `Sources/JIT/` | `browser/Reynard/JIT/` | — | **0-B2 では配置しない**（下記「JIT について」） |
| `Sources/Bridging/` | `browser/Reynard/Bridging/` | — | `UIKit+Private.h` など |
| `Sources/Shared/` | `browser/Reynard/Shared/` | — | `Utils.m` / `Utils.h`。**`GeckoView` と `Kotone` の両ターゲットに所属**させる（`project.yml` で設定済み） |
| `Sources/ThirdParty/` | `browser/Reynard/ThirdParty/` | — | BlurUIKit。UI で使わないなら省略可 |

## 流用しないもの

| Reynard 側 | 理由 |
|---|---|
| `browser/Reynard/Client/` | ブラウザ UI（タブ・ブックマーク・履歴・アドレスバー）。音楽アプリには不要 |
| `browser/Extensions/OpenIn/` | 他アプリで開く共有拡張。不要 |
| `browser/Reynard/Resources/` | Reynard のアイコン・ローカライズ。独自のものを用意する |
| `browser/Reynard/main.swift` | 参考にはするが、`Sources/App/main.swift` として自前で書く |
| `browser/Reynard/ApplicationMenuBuilder.swift` | ブラウザメニュー。不要 |
| `browser/Reynard.xcodeproj` | `project.yml` から生成する |

## 自前で書くもの

| 配置先 | 内容 | 状態 |
|---|---|---|
| `Sources/App/` | エントリポイント、Scene、UI | Phase 0-B1 の最小版を同梱済み |
| `Extension/` | WebExtension（pear-desktop プラグインの移植先） | Phase 2 |

## JIT について

**0-B2 では JIT を含めません。**

`Sources/JIT/` は `RPPairing/libidevice_ffi.a` を必要としますが、これは
`tools/development/build-idevice.sh` が Rust でクロスコンパイルする成果物で、

- reynard-browser のリポジトリに含まれていない（`.gitignore` されている）
- 配布 IPA からも取り出せない（静的ライブラリは実行ファイルに埋め込まれる）

Gecko は JIT なしでも動作します。SpiderMonkey がインタプリタ実行になり
遅くなるだけで、起動やレンダリングの確認には十分です。

**0-B2 で確認したいのは「Gecko が子プロセスを起動してページを描画できるか」**
であり、JIT は性能の話です。同時に入れると、失敗したときに
Gecko 由来か JIT 由来かを切り分けられなくなります。

### 結合は閉じていることを確認済み

`Sources/{GeckoView,Helper,Shared}` から JIT シンボル
（`JITController` / `JITEnabler` / `ReportJITStatusForChild` / `hasTXMSupport`）
への参照は **0 件**でした。唯一の接点は bridging header の
`#import "JITEnabler.h"` で、これは `KOTONE_ENABLE_JIT` で条件化してあります。

なお `GeckoRuntime.swift` が呼ぶ `updateJetsamControl()` は
`Sources/Shared/Utils.h` の側で、JIT とは無関係です。

### 後から JIT を入れる手順

```bash
# 1. reynard-browser で libidevice_ffi.a を生成（Rust / Cargo が必要）
./tools/development/build-idevice.sh

# 2. Sources/JIT/ 一式と libidevice_ffi.a を配置
# 3. 有効化
./scripts/enable-gecko.sh --with-jit
```

`--with-jit` は `libidevice_ffi.a` が無ければ拒否します。

---

## 配置時の注意

### `View/GeckoView.h` は使いません

`browser/GeckoView/View/GeckoView.h` は **Reynard 本家でも一度もコンパイルされていない
死んだファイル**です。`project.yml` で除外済みなので、そのまま置いておいても構いませんが、
削除しても問題ありません。

根拠:

```
project.pbxproj:
  01GECKO00A2F2F289C001F0001 /* Headers */ = {
      isa = PBXHeadersBuildPhase;
      files = (        ← 空
      );
  };
```

Headers ビルドフェーズが空なので umbrella header として採用されず、
中身の `#import "TSUtils.h"` が評価されることはありません。
配布 IPA の `GeckoView.framework` に `Headers/` も `Modules/` も無いのは
このためです。

実際に使われているのは `browser/Reynard/Bridging/Reynard-Bridging-Header.h` で、
そちらは `TSUtils.h` ではなく `Utils.h` を import しています。

### `TSUtils.h` の正体

`TSUtils` は **TrollStore Utils** の略でした。実体は
`browser/Reynard/Shared/Utils.h` / `Utils.m` にリネームされています。

```objc
// Sources/Shared/Utils.h
BOOL getEntitlementValue(NSString *key);
void updateJetsamControl(pid_t pid);
int  spawnRoot(NSString *path, NSArray<NSString *> *args);
```

`Utils.m` の冒頭に TrollStore の `Shared/TSUtil.m` への参照コメントがあります。
`GeckoRuntime.swift` が呼ぶ `updateJetsamControl(pid)` はここで宣言されています。

### Gecko のヘッダ 3 つ

`scripts/fetch-headers.sh` が自動生成します。手動作業は不要です。

| ヘッダ | 由来 |
|---|---|
| `IOSBootstrap.h` | firefox `toolkit/xre/` + `patches/toolkit/xre/IOSBootstrap.h.patch` |
| `GeckoViewSwiftSupport.h` | firefox `widget/uikit/` + 対応 patch |
| `GeckoViewRuntimeSupport.h` | patch が新規作成（全文が patch に含まれる） |

生成先は `engine/dist/include/GeckoView/` で、これは Gecko の
`EXPORTS.GeckoView` と同じ配置です。

依存の閉包はこの 3 ファイルとシステムヘッダ
（`Foundation` / `UIKit` / `AVFoundation` / `xpc` / `stdbool` / `stdint`）だけで閉じます。
`mozilla/Types.h` 等は `#ifdef MOZILLA_CLIENT` の内側にあり、
アプリ側のビルドでは評価されません。

**firefox リポジトリの clone は不要です。** raw URL で 2 ファイル取得するだけです。
