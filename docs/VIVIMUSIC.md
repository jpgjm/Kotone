# ViviMusic からの取り込み

Kotone のネイティブ UI は ViviMusic のものを使う。
**Reynard のように外部から取得せず、本リポジトリ内に置く**（vendoring）。

出典: `ViviMusic rev.80`（2026-08-14 のビルド修正版）

---

## 取り込んだもの — `Sources/Vivi/`

| 層 | 行数 | ファイル | 内容 |
|---|---:|---:|---|
| `Views/` | 5,172 | 22 | UI 本体。4 タブ + ミニ/フルプレイヤー |
| `InnerTube/` | 2,395 | 7 | 検索・ブラウズ・パーサ |
| `Core/` | 1,136 | 5 | モデル・ログ |
| `Services/` | 2,666 | 14 | 認証・ライブラリ・DL・歌詞・Together |
| **合計** | **11,369** | **48** | |

`Views/` の主要画面:

```
RootView          4 タブ（ホーム / 探索 / 検索 / ライブラリ）+ ミニプレイヤー
PlayerView        フルプレイヤー
HomeView / ExploreView / SearchView / LibraryView
PlaylistDetailView / BrowseDetailView / SongMenuSheet
LyricsPane / EqualizerView / SleepTimerSheet / SettingsView
LoginView / CookieLoginView / TogetherView / LogView
Theme / Components
```

---

## 取り込まなかったもの

**すべて再生系。Gecko が肩代わりするため不要。**

| 除外 | 行数 | 理由 |
|---|---:|---|
| `Playback/` | 1,812 | **65 秒問題の当事者。** `AVPlayer` + `AVAssetResourceLoader` |
| `Services/SABR/` | 1,579 | SABR 実装。`StreamProtectionStatus=2` で 69 秒上限だった |
| `Services/PoToken/` | 875 | BotGuard。公式プレイヤーが付与するので不要 |
| `Services/PlayerJSService.swift` | 913 | `base.js` の署名デコード。不要 |
| `Services/StreamProbe.swift` | 489 | ストリーム検証。不要 |
| `Services/StreamFetcher.swift` | 218 | 同上 |
| `App/` | 36 | Kotone 側に既存（`main.swift` は `GeckoRuntime.main`） |

**除外は 5,922 行**。ViviMusic で最も苦労した部分がまるごと不要になる。

---

## 未解決の参照

取り込んだコードが、除外したものを参照している箇所。
**ここを埋めないとコンパイルできない。**

| シンボル | 参照数 | 参照元 | 対処 |
|---|---:|---|---|
| ~~**`PlayerManager`**~~ | ~~24~~ | — | **rev.36 で解決**（`Sources/App/PlayerManager.swift`） |
| `PlayerJSService` | 4 | `RootView`, `SettingsView`, `InnerTube/*` | 呼び出しを削る |
| `PoTokenService` | 3 | `InnerTube/YouTubeAPI`, `YouTubeClient`, `InnerTube` | 同上 |
| `StreamFetcher` | 2 | `DownloadManager` | ダウンロード機能の再設計が要る |
| `StreamProbe` | 1 | `SettingsView` | 呼び出しを削る |

---

## 組み込みの進捗

| 層 | `project.yml` | 状態 |
|---|---|---|
| `Core/` | ✅ 組み込み済み | `Song` / `BrowseRoute` など 51 型 |
| `InnerTube/` | ✅ 組み込み済み | 検索・ブラウズ・パーサ |
| `Services/` | ✅ 組み込み済み | 認証・ライブラリ・歌詞・Together |
| `Views/` | ✅ 組み込み済み | 22 ファイル 5,172 行 |

### 除外したファイル

| ファイル | 理由 |
|---|---|
| `Services/Equalizer/EqualizerTap.swift` | `MTAudioProcessingTap` で `AVPlayer` の音声に噛ませる実装。Gecko 内で再生するのでタップ対象が無い |
| `Services/Equalizer/BiquadFilter.swift` | 同上（`EqualizerTap` からのみ使用） |

どちらも他から参照されていないことを確認済み。
`EqualizerSettings` は残っているので `EqualizerView` は表示できる
（設定値が効かないだけ）。

### 未解決参照は解消済み

`PlayerJSService` / `PoTokenService` / `StreamProbe` / `StreamFetcher` は
**すべてコメント内の言及のみ**で、実コードからの参照は無かった。
`DownloadManager.performDownload` は既に
「現在の構成では未対応」を返す形に整理されている。

---

## `PlayerManager` の契約

`Views/` が実際に使っているのは以下だけ。
**この API を満たす Gecko 版を書けば、Views は無改修で動く。**

### 読み取り（`@Published` 想定）

```swift
var currentSong: Song?          // 16 箇所
var isPlaying: Bool             // 3
var isLoading: Bool             // 3
var duration: TimeInterval      // 4
var currentTime: TimeInterval   // 4
var queue: [Song]               // 2
var repeatMode: RepeatMode      // 2
var lastErrorMessage: String?   // 2
var isPlayingLocal: Bool        // 2
var isSleepTimerActive: Bool    // 3
var sleepTimerEndDate: Date?    // 1
var sleepAtEndOfTrack: Bool     // 1
```

### 操作

```swift
func play(...)                  // 10 箇所
func togglePlayPause()          // 2
func next() / previous()        // 3
func seek(to:)                  // 2
func setQueue(...)              // 3
func addToQueue(...) / removeFromQueue(...)
func shufflePlay(...)           // 2
func toggleShuffle()
func skip(...)
func setSleepTimer(...) / setSleepAtEndOfTrack(...)
```

### Gecko 版の実装方針

```
play(song)  → session.load("https://music.youtube.com/watch?v=<videoId>")
              ← 拡張機能に依存しない。GeckoSession の実証済み経路

pause / seek / next
            → KotoneHTTPBridge → background.js → content.js → ページ内操作

isPlaying / currentTime / duration / currentSong
            ← MediaSessionDelegate（既に全項目の到達を確認済み）
```

`MediaSession` からは `title` / `artist` / `artworkUrl` / `position` /
`duration` / `playbackRate` と `features`
（`play, pause, stop, seekTo, next, prev`）が届いている。
**読み取り側はほぼ揃っている。**

操作側は `KotoneBridge`（rev.20 で実装）が必要。

---

## ライセンス

ViviMusic は本人の著作物なので、Kotone（GPL-3.0）に取り込むうえでの
制約はない。`THIRD_PARTY_NOTICES.md` への記載も不要。

ただし ViviMusic 側が参照している第三者資産（`vivi-music-main` の
UI 設計など）がある場合は、そちらの表記を引き継ぐこと。
