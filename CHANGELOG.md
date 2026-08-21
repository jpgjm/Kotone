# Changelog

## rev.55

### 修正: ループ・シャッフルが壊れていた

ログ上はコマンドが成功していた。

```
15:34:29  [PM] repeatMode -> all
15:34:29  [PM→web] setRepeat ok
15:41:57  [PM] repeatMode をページから同期 -> off     ← 勝手に off に戻る
```

原因は**状態の読み取り方**。存在しない属性を読もうとしていた。

```js
el.getAttribute("repeat-mode")   // そんな属性は無い
```

読めないと必ず `"off"` を返す実装だったため、

- `setRepeat` が「現在 off」と誤認し、最大 3 回押して終わる。
  実際の状態と合わない
- `syncRepeatModeFromPage` がページを開くたびに
  Kotone 側の表示を off に潰す

正しくはページの Redux ストアを読む。pear-desktop も同じ場所を見ている。

```js
// src/providers/song-info-front.ts:66
document.querySelector('ytmusic-player-bar').getState().queue.repeatMode
```

content script は隔離ワールドなので `wrappedJSObject` を経由する。

### 直したこと

- **読めないときは `null` を返す。** `"off"` を返すと
  「未取得」と「本当に off」の区別がつかない
- `setRepeat` は**目的の状態になるまで押し、なっていなければ失敗を返す**。
  嘘の成功を返さない
- `toggleShuffle` は押した**前後の状態**を返す
- Swift 側は**結果で状態を決める**。
  先に反転させると、ページが応じなかったときに表示だけずれる
- シャッフルもページから同期する

疎通テストに「ループ / シャッフル」の欄を足した。
`mode = <null>` ならストアに触れていないと分かる。

- `manifest.json` を `0.18.0` に更新


## rev.54

### 修正: 曲を切り替えても変わらない

```
15:20:04  play いちごパフェが止まらない (XzLvfXMaP7c)
15:20:05  openVideo ok: { method = spa }     ← 成功と報告
15:20:13  metadata BE ME / Doul              ← 全然違う曲
```

**検証が嘘をついていた。**

切り替わったかを「URL が変わったか」で判定していたが、
`pushState` で URL を書き換えたのは**自分自身**なので必ず通る。
実際にはページのルーターが反応しておらず、曲は変わっていなかった。

2 点直した。

- **判定を `<video>` の `currentSrc` に変えた。**
  曲ごとに変わる blob URL なので、中身が切り替わったかを確かめられる。
  最大 2.5 秒待って変わらなければ失敗とみなす
- **遷移の方法を `<a>` のクリックに変えた。**
  YouTube のルーターは `<a>` のクリックを横取りする。
  `pushState` + `popstate` では反応しないことがある

効かなければ `location.assign` に落とす。こちらは確実。

### 修正: ログインしているのにダウンロードできない

```
WEB_REMIX: UNPLAYABLE 動画を再生できません
VISIONOS:  LOGIN_REQUIRED ログインして bot ではないことを確認してください
WEB:       UNPLAYABLE 動画を再生できません
```

**Cookie を送るだけでは認証されない。**
YouTube は `SAPISID` クッキーから作るハッシュを
`Authorization` ヘッダで要求する。無いと未ログイン扱いになる。

形式は yt-dlp の `_make_sid_authorization` に合わせた。

```
SAPISIDHASH <timestamp>_<sha1(timestamp + " " + sid + " " + origin)>
```

`SAPISID` が無いこともあるので `__Secure-3PAPISID` /
`__Secure-1PAPISID` も見て、3 つ分を並べて送る。
あわせて `X-Origin` / `X-Goog-AuthUser` / `X-Goog-Visitor-Id` も付ける。

計算が yt-dlp と一致することを確認済み。

```
yt-dlp 相当:     SAPISIDHASH 1755780000_03f5adc34c1ae5a2818b87e572d652c5d8d2713f
content.js 相当: SAPISIDHASH 1755780000_03f5adc34c1ae5a2818b87e572d652c5d8d2713f
```

失敗時は認証が効いていたかも返す。

```
音声 URL を取得できません — auth=あり / WEB_REMIX: … / VISIONOS: …
```

`auth=なし` なら `SAPISID` が読めていないので、原因が別だと分かる。

- `manifest.json` を `0.17.0` に更新


## rev.53

### 修正: 編集ミスでメンバーを消していた（14 件）

rev.50〜52 の書き換えで、周辺のメンバーをまとめて消していた。

**`PlayerManager`**
`pendingNavigation` / `navigationStartedAt` / `canNavigate` /
`navigationDidFinish`

**`KotoneHTTPBridge`**
`resolveAudio` / `setRepeat` / `toggleShuffle` / `cycleRepeat`

`openVideo` を `openURL` に差し替えたとき、
隣接するメソッドまで置換範囲に含めていた。復元した。

### 検査器が壊れていた

**より問題なのは、既存の検査がこれを一切検出できなかったこと。**
原因は Swift のコメント・文字列を落とす処理にあった。

```python
re.sub(r'"(?:\\.|[^"\\])*"', ' "" ', src)
```

Swift の複数行文字列

```swift
log.append(.player, """
    title = \(title)
    """)
```

の中には裸の `"` が入るため、単一行文字列用の正規表現と噛み合って
**本文まで食っていた**。実測で `PlayerManager.swift` は

```
22,215 文字  →  5,201 文字
self. の参照  8 種  →  0 種
```

まで削られており、**検査は常に「OK」を返していた。**
誤って OK を出す検査は無い方がまし。

### 対応

- **`scripts/check_swift_symbols.py`**（新規）に実体を移した。
  シェルに Python を埋め込む形は引用符の入れ子で壊れやすい
- コメントと文字列は**先頭から 1 文字ずつ読んで**落とす。
  正規表現では Swift の複数行文字列を正しく扱えない
- **同一ファイル内の自メンバー検査**を追加。
  `self.bridge.resolveAudio(...)` のような変数経由の呼び出しは
  型名検査では拾えない
- `self.` を付けずに参照されるプロパティは名指しで追跡する
  （`pendingNavigation` など）。`self.` だけ見ていては拾えない
- **型名の重複検査は撤去した。** 入れ子の型を区別できず、
  `Coordinator` / `Keys` / `Kind` / `Tab` を誤検出していた。
  正しく追うには Swift のパーサが要る

今回消えた 3 種類すべて（`self.` 無しのプロパティ /
`self.bridge.` 経由のメソッド / 型名経由のメソッド）を
再現して検出できることを確認済み。


## rev.52 — YouTube 外でもそのまま開く

ご指摘のとおり、エラーにせず**タブを書き換えればよい**。

```
YouTube のページを開いていません（現在: …addons.mozilla.org…）
```

拡張機能はタブを操作できるので、この状況をネイティブ側に
投げ返す必要が無かった。

### 変更: `openURL` は必ず開く

```js
async function openURL(url) {
  // 1. YouTube のタブがあれば content script に任せる（ページ内遷移）
  // 2. 無ければ現在のタブを書き換える
  await browser.tabs.update(active.id, { url });
}
```

アドオン導入のため AMO を開いたままでも、
**そのタブがそのまま目的の曲になる。**

### 変更: 再生制御も自動で復帰する

`play` / `pause` / `seek` などはページ内の操作なので、
別サイトに居ると届かない。
これまではエラーにしてネイティブ側の `ensureOnMusicPage()` に
頼っていたが、こちらもタブの書き換えで完結させた。

```js
if (!tabs.length) {
  await browser.tabs.update(active.id, { url: "https://music.youtube.com/" });
  // 読み込みと content script の注入を待つ（最大 10 秒）
}
```

待ち時間が伸びるぶん、拡張機能側のコマンドのタイムアウトを
6 秒 → 15 秒に広げた。
Swift 側は rev.49 で生存判定に変えてあるので、
拡張機能が生きている限り待ち続ける。整合している。

### ネイティブ側のフォールバック

`loadDirectly` は残してある。
ここに来るのは**拡張機能自体が応答しないとき**だけになった。

- `manifest.json` を `0.16.0` に更新


## rev.51 — URL をそのまま渡す

ご指摘のとおり、`music.youtube.com` へ組み立て直す必要はなかった。
**受け取った URL をそのまま開けば、ページ側が再生する。**

### 変更: URL を書き換えない

以前は videoId を取り出して
`https://music.youtube.com/watch?v=<id>` に組み立て直していた。
書き換えると失うものがある。

- `m.youtube.com` の URL を渡されたのに音楽版へ飛ばしてしまう
- `t=` などのクエリが落ちる
- Music カタログ外の動画が `music.youtube.com` で開けない
  （実測で `WEB_REMIX: UNPLAYABLE` の原因でもあった）

`PlayerManager.playbackURL(for:)` は次のように振る舞う。

| 入力 | 結果 |
|---|---|
| `XzLvfXMaP7c` | `https://music.youtube.com/watch?v=XzLvfXMaP7c` |
| `https://m.youtube.com/watch?v=…&list=…&start_radio=1` | **そのまま** |
| `https://youtu.be/…?si=…` | **そのまま** |
| `https://www.youtube.com/watch?v=…&t=10` | **そのまま** |
| `music.youtube.com/watch?v=abc` | `https://` を補うだけ |
| `https://music.youtube.com/playlist?list=…` | **そのまま** |

素の videoId のときだけ URL を組み立てる。

### 変更: `openVideo` → `openURL`

拡張機能側も videoId ではなく URL を受け取る。

- 同じ動画を開いているなら再生するだけ
- 同一オリジンなら SPA のルーターで切り替え（読み直しなし）
- **別オリジンなら普通に遷移**（`m.youtube.com` → `music.youtube.com` など）

### 変更: content script を YouTube 全体に注入

`music.youtube.com` だけでなく `www.youtube.com` と `m.youtube.com` にも
入れる。「URL を受け取って再生するだけ」なので、
音楽版に限定する理由が無い。

タブの検索とエラーメッセージも合わせた。

```
YouTube のページを開いていません（現在: …addons.mozilla.org…）
```

再生・一時停止はページ内の操作なので、別サイトに居ると届かない。
その場合だけ YouTube に戻す。
`openURL` は自前で目的の URL へ行くので対象外にしてある。

- `manifest.json` を `0.15.0` に更新


## rev.50

### 修正: 別サイトのまま音楽 UI に戻ると曲を開けない

報告のあった不具合。アドオン導入のため AMO を開いたまま
ブラウザ画面から音楽 UI に戻ると、曲を選んでも再生されない。

content script は `music.youtube.com` にしか入らないので、
`openVideo` が

```
openVideo 失敗: music.youtube.com を開いていません（現在: …addons.mozilla.org…）
```

で失敗する。ここまでは想定どおりだが、**その後 `ensureOnMusicPage()` が
ホームに飛ばしていたため、指定した曲が失われていた。**

- `openVideo` が失敗したら、**その曲の URL へ直接遷移する**
  （`loadDirectly`）。ホームではなく目的の曲に行く
- `openVideo` の失敗では `ensureOnMusicPage()` を呼ばない

### 前進: ダウンロードの相対 URL 問題は解消

rev.49 の絶対 URL 化が効き、`TypeError` は消えた。
次の壁が見えた。

```
WEB_REMIX: UNPLAYABLE 動画を再生できません
VISIONOS:  LOGIN_REQUIRED ログインして bot ではないことを確認してください
```

- `WEB_REMIX` は **Music カタログ外の動画**を再生不可扱いにする
- 素の `VISIONOS` は bot 判定に引っかかる

対策を 3 つ入れた。

1. **`visitorData` を添える。** ページが既に持っている値
   （`ytcfg.VISITOR_DATA`）なので、セッションの継続として扱われやすい
2. **`WEB` クライアントを追加。** Music カタログ外の動画はこちらなら
   再生可能扱いになる
3. **ページ自身の再生情報を調べる `playerResponseInfo` を追加**

3 番目が本命の切り分け。ページは既に再生できているので、
その `ytInitialPlayerResponse` に使える URL があれば
それが最も確実な入手経路になる。

```
ページの再生情報:
  found = 1
  status = OK
  audioCount = 3
  withUrl = 0        ← 0 なら SABR 配信で URL が無い
  withCipher = 3     ← 署名付きしか無い
  hasServerAbr = 1
  itags = (140, 251, 250)
```

🧩 の疎通テストで確認できる。
`withUrl` が 1 以上なら、ページの情報をそのまま使う経路に切り替えられる。

- `manifest.json` を `0.14.0` に更新


## rev.49

### rev.48 の確認

**SPA 遷移が動作した。**

```
09:18:31.129  PLAYER  [PM→web] openVideo ok: { method = spa;
              url = https://music.youtube.com/watch?v=wSFF7yqc9Oc }
```

ページ読み直しが消え、曲の切り替えが 1 秒で終わるようになった。
`method = spa` が続いており、`assign` へのフォールバックは起きていない。

### 修正 1: ダウンロードの相対 URL

```
TypeError: /youtubei/v1/player?prettyPrint=false is not a valid URL.
```

**content script の `fetch` はページを基準に解決してくれない。**
相対パスを渡すと URL として解釈されずに落ちる。

絶対 URL にした。

```js
"https://music.youtube.com/youtubei/v1/player?prettyPrint=false"
```

### 修正 2: content script が入る前のコマンド

```
09:17:42  openVideo 失敗: Could not establish connection.
          Receiving end does not exist.
```

ページ遷移の直後は content script がまだ注入されていない。
`callContentWithRetry` を追加し、この種の失敗は 400ms 間隔で
4 回まで待ち直すようにした。恒久的な失敗はそのまま投げる。

### 修正 3: 待ち方を固定秒数から生存判定に

ご指摘のとおり Swift にも `await` はある。問題は
**相手が必ず返す保証が無い**こと。拡張機能が死ぬと
continuation を resume する者がいなくなり永久に待つ。

とはいえ固定秒数は筋が悪かった。`resolveAudio` の 25 秒は
根拠のない数字で、実際 rev.48 では逆に

```
09:17:26  openVideo 失敗: タイムアウト: openVideo（最後のポーリングから 11 秒）
```

のように「相手は生きているのに待ち切れず諦める」ことも起きていた。

**拡張機能は 400ms ごとにポーリングしてくるので、生死は分かる。**

| 状況 | 挙動 |
|---|---|
| ポーリングが来ている & 応答が無い | 処理中。**待ち続ける** |
| ポーリングが 3 秒来ていない | 死んだ。**即座に諦める** |
| 60 秒経過 | 暴走止めの保険 |

これで「重い処理を待てる」と「死んだら即失敗」を両立できる。
失敗メッセージも「タイムアウト」ではなく理由を返すようにした。

```
openVideo を実行できません（拡張機能からのポーリングが 8 秒途絶えています）
```

### 修正 4: 遷移中のページタイトルがロック画面に出る

```
08:54:23  metadata title = 七月、繋いだ星に（feat. nayuta） | YouTube Music
          artist =   album =   art =
```

遷移中はページのタイトルがそのまま曲名として届き、
ロック画面が一瞬これを表示していた。
`| YouTube Music` で終わり、アーティストもアートワークも空のものは捨てる。
正しい曲情報は数百 ms 後に改めて届く。

- `manifest.json` を `0.13.0` に更新


## rev.48

### 修正: 遷移が詰まって曲が再生できない

実測ログ。

```
20:30:56.277  music.youtube.com へ戻した   ← ensureOnMusicPage が
20:30:56.289  music.youtube.com へ戻した      4 回連続で発火
20:30:56.290  music.youtube.com へ戻した
20:30:56.290  music.youtube.com へ戻した
20:32:54.875  [PM→web] load …             ← 以降 page start が来ない
20:34:44.936  [PM→web] load …                （12 回すべて無反応）
```

**`session.load()` を短時間に何度も呼ぶと、以降の遷移が一切始まらなくなる。**

`ensureOnMusicPage()` は失敗したコマンドの数だけ呼ばれるため、
1 回の操作で 4 連発した。これが引き金だった。

「ログインしてから曲を再生できない」もこれが原因で、
ログイン固有の問題ではなかった。

- 進行中の遷移を `pendingNavigation` として持ち、
  同じ URL の連打と、前の遷移が終わる前の要求を弾く
- `onPageStop` で解除する。15 秒来なければ取りこぼしとみなして次を通す
- `ensureOnMusicPage()` も同じ守りを通す

### 変更: 曲の切り替えをページ内遷移にする

ご指摘のとおり「URL を渡すだけ」なので、
**ページを読み直す必要がない**。

`session.load()` は毎回ページ全体を読み直すため

- 数秒かかる
- 子プロセスが増える（実測で 1 曲ごとに 1〜3 個）
- 連続で呼ぶと詰まる（上記）

YouTube Music は SPA なので、`history.pushState` + `popstate` で
ページ側のルーターに拾わせれば、読み直さずに曲だけ切り替わる。

```js
history.pushState({}, "", target);
window.dispatchEvent(new PopStateEvent("popstate", { state: {} }));
```

0.7 秒待って URL が変わっていなければ `location.assign` に落とす。
同じ曲なら何もしない（一時停止中なら再生だけする）。

拡張機能が未接続のときだけ `session.load()` を使う。

### 修正: ダウンロードのタイムアウト不一致

`resolveAudio` は JS 側 20 秒、Swift 側 5 秒だった。
**Swift が必ず先に諦める**ので、成功しても失敗として扱われていた。

コマンドごとに待ち時間を分けた。

| コマンド | Swift | JS |
|---|---|---|
| `resolveAudio` | 25 秒 | 20 秒 |
| `openVideo` | 10 秒 | 4 秒 + SPA 確認 0.7 秒 |
| その他 | 5 秒 | 4 秒 |

### 追加: ダウンロードの経過を測定ログにも出す

これまで `EventLog`（設定 → 診断ログ）にしか残らず、
測定ログだけでは切り分けられなかった。

```
[DL] 開始 曲名 (videoId)
[DL] URL 解決 VISIONOS itag=140 audio/mp4
[DL] 完了 videoId videoId.m4a
[DL] 失敗 videoId: 音声 URL を取得できません — …
```

- `manifest.json` を `0.12.0` に更新


## rev.47

### 修正: ブリッジが数分で死ぬ

実測ログ。

```
19:14:05  HTTP: 拡張機能が接続しました: 0.10.0
19:18:36  最後の HTTP event
19:23:05  ERR [PM→web] play 失敗: タイムアウト: play
（以降、seek / toggle / next / setRepeat すべてタイムアウト）
```

セッション全体で `HTTP event` が **4 件しか無い**。
`/event` も `/poll` も通らなくなっていた。

原因は**長時間ポーリング**。`/poll` が空のとき接続を保留していたが、
保留された接続が回収されず、以降の通信ごと巻き込んで止まっていた。

**短間隔ポーリングに変更した。**

- サーバは常に即座に返す（溜まっていなければ空配列）
- 拡張機能は 400ms 間隔で問い合わせる
- 拡張機能からのイベントは**同じ往復に相乗り**させ、接続数を半分にする
  （`timeupdate` が毎秒来るため、1 件ずつ接続を張ると数が増えすぎる）

ループバック通信なので毎秒 2〜3 往復は負荷にならない。
**接続が残らないので、同じ死に方はしない。**

あわせて詰まりにくくした。

- コマンドは `await` せずに走らせる。1 本が詰まっても次のポーリングは進む
- コマンドごとに JS 側で 4 秒のタイムアウト（`resolveAudio` は 20 秒）
- Swift 側のタイムアウトを 10 秒 → 5 秒に短縮し、
  **最後にポーリングが来てからの経過**をメッセージに含める。
  拡張機能が生きているのか死んでいるのかが切り分けられる

### 修正: ダウンロードが失敗する

`WEB_REMIX` で `player` を叩くと `adaptiveFormats` が
**`signatureCipher`（署名付き）で返る**ことが多い。
復号には `base.js` の解析が要り、それは意図的に落としてある。

クライアントを順に試すようにした。

| クライアント | 位置づけ |
|---|---|
| `WEB_REMIX` | ページと同じ。Cookie がそのまま効く。署名付きで返りがち |
| **`VISIONOS`** | **JS プレイヤー不要・poToken 不要**。`url` がそのまま入る |

`VISIONOS` は yt-dlp の分類による
（`extractor/youtube/_base.py` の `REQUIRE_JS_PLAYER: False`、
`GVS_PO_TOKEN_POLICY` なし）。

`ANDROID_VR` も同じ性質だが、yt-dlp の注記によると
**2026-08-17 以降は全フォーマットが 403** になるため候補から外した。

失敗時はクライアントごとの理由を並べて返す。

```
音声 URL を取得できません — WEB_REMIX: 署名付き URL のみ (itag 140,251) /
VISIONOS: LOGIN_REQUIRED …
```

使用できたクライアントは診断ログに残す（`VISIONOS itag=140 audio/mp4`）。

- `manifest.json` を `0.11.0` に更新


## rev.46

### 追加: ロック画面 / コントロールセンター

`Sources/App/NowPlayingCenter.swift`。
ViviMusic の同名ファイルを下敷きに、再生の実体が Gecko 内にあることへ
合わせて書き直した。

- `MPNowPlayingInfoCenter` — 曲名 / アーティスト / アルバム /
  アートワーク / 再生位置 / 長さ
- `MPRemoteCommandCenter` — 再生 / 一時停止 / トグル / 次 / 前 /
  シーク。`MediaSession` の features に
  `play, pause, stop, seekTo, next, prev` が揃っていることは実測済み
- 早送り・巻き戻しは無効化（押せてしまうため）

**`AVAudioSession` を `.playback` にするのもここ。**
`Info.plist` の `UIBackgroundModes: audio` だけでは足りず、
カテゴリを設定しないと画面を消した時点で音が止まる。
着信などの中断後に `shouldResume` なら再開する。

アートワークは `MediaSession` から `w60-h60` の小さい版で届くので、
ロック画面用にサイズ指定を差し替える。実測で届く形は 2 種類ある。

```
https://yt3.googleusercontent.com/…=w60-h60-s-l90-rj  → =w544-h544-l90-rj
https://i.ytimg.com/vi/<id>/mqdefault.jpg             → maxresdefault.jpg
```

再生位置は毎秒更新されるが、ロック画面は `elapsedTime` と
`rate` から自前で補間するため 2 秒に間引いて渡す。

### 追加: ダウンロード（案 A）

**ページのコンテキストで `fetch` する。**

```js
// content.js
fetch("/youtubei/v1/player?prettyPrint=false", { credentials: "include", … })
```

こうすると

- Cookie / 認証がそのまま乗る
- **署名済み URL をそのまま使える**（`PlayerJSService` が不要）
- CORS を気にしなくてよい

`INNERTUBE_CLIENT_VERSION` はページの `ytcfg` から読む
（古い値だと InnerTube が拒否するため）。隔離ワールドから
`ytcfg` に触れない場合は HTML から正規表現で拾う。

`adaptiveFormats` から **itag 140 (AAC 128kbps) を最優先**で選ぶ。
`signatureCipher` しか無い場合は復号が要るので諦めてその旨を返す。

Swift 側は解決した URL を `URLSession` で普通に取得する。

保存先は既存の規約どおり `<videoID>.m4a` 固定にした。
`localFileURL(for:)` がこの名前を前提にしているため、
拡張子を可変にすると再生側が見つけられなくなる。
WebM/Opus しか無い曲は `AVPlayer` で再生できないので弾く。

`DownloadManager.isSupported` は
**拡張機能が接続しているか**を返すようにした。
未接続なら `SongMenuSheet` がボタンを押せなくして理由を出す。

- `manifest.json` を `0.10.0` に更新


## rev.45

実機で報告のあった 3 点。

### 1. 再生バーがページと一致しない

`currentTime` を `MediaSession` の `positionState` でしか更新しておらず、
**これは状態変化時にしか飛んでこない**。曲の途中では止まったままになる。

対策は 2 段構え。

- `content.js` が `timeupdate` を約 1 秒おきに送る。
  `timeupdate` 自体は毎秒 4 回ほど発火するので間引いている
- その間はローカルのタイマー（0.25 秒）で補間する

実測値が来たら必ずそちらで上書きするので、ずれは蓄積しない。
実測が 5 秒途絶えたら補間も止める（曲の終わりや遷移中）。

`currentTime` は JSON 経由で文字列として届くことがあるため
（`currentTime = "3.224479"`）、`Double` / `NSNumber` / `String` の
いずれでも受けられるようにした。

`timeupdate` は毎秒来るのでログには出さない。

### 2. ループ・シャッフルが効かない

Kotone 側の変数を切り替えるだけで、**ページに何も送っていなかった**。

```swift
func toggleShuffle() {
    isShuffled.toggle()      // ← これだけだった
}
```

ViviMusic では Kotone 側でキューを並べ替えていたが、
Gecko 構成では**キューを持っているのはページ側**なので、
ページのボタンを押さないと実際には効かない。

`content.js` に `setRepeat` / `cycleRepeat` / `toggleShuffle` /
`repeatState` を追加した。セレクタは pear-desktop が使っているものに合わせた。

```js
document.querySelector('#right-controls .repeat')   // song-info-front.ts:66
```

ループはページのボタンが off → all → one → off と巡回するため、
Kotone 側で次の状態を決めて `setRepeat` で指示する。
現在の状態は `repeat-mode` 属性から読む（ページの言語に依存しない）。

ページを開き直すとループ状態がページ側の値に戻るので、
`onPageStop` で `syncRepeatModeFromPage()` を呼んで表示を合わせる。

### 3. ダウンロードが機能しない

**意図的に無効化されている状態だった**が、UI 上は普通のボタンに見えるため
「押しても何も起きない」ように見えていた。

`DownloadManager.isSupported = false` を追加し、
`SongMenuSheet` はボタンを押せなくして理由を表示するようにした。

```
⬇ ダウンロード
   現在の構成では未対応です
```

再実装するなら設計判断が要る（後述）。

- `manifest.json` を `0.9.0` に更新


## rev.44

### 修正: ブラウザ画面のボタンが効かない

実機報告。ブラウザ画面の 🧩 アドオン / 📋 測定ログ / ✓ 診断を押しても
**何も起きない**。

原因は `BrowserViewController` が `MusicHostViewController` の子として
**直接**貼られていたこと。`UINavigationController` に載っていないため
`navigationController` が `nil` になり、

```swift
navigationController?.pushViewController(AddonsViewController(), animated: true)
```

が**黙って何もしない**。オプショナルチェーンなのでコンパイルは通り、
実機で触るまで気づけない。

rev.42 で `SceneDelegate` の root を
`UINavigationController(rootViewController: BrowserViewController())` から
`MusicHostViewController` に変えたときに、ナビゲーションが失われていた。

- `MusicHostViewController` が `browserNav`
  （`UINavigationController`）を持ち、そちらを背面に貼る
- ブラウザ画面は自前のツールバーを持つので、
  その画面でのみナビゲーションバーを隠す
  （`viewWillAppear` / `viewWillDisappear`）。
  押した先では戻るボタンが要るので表示に戻す
- 音楽 UI に戻るときは `popToRootViewController` で畳む。
  次に開いたときブラウザから始まる方が分かりやすい

### 追加: ナビゲーションの検査

`scripts/check-symbols.sh` に、
`pushViewController` / `popViewController` を使う画面が
実際に `UINavigationController` に載っているかの検査を追加した。

```
MISS BrowserViewController  (navigationController を使用)
::error::BrowserViewController が pushViewController を使っていますが、
         UINavigationController に載せている箇所が見つかりません
```

今回の不具合を再現して検出できることを確認済み。

**「オプショナルチェーンで黙って失敗する」類はコンパイルで拾えない。**
`rev.38` の除外ファイル検査と同じ発想で、
実機で触るまで分からない不具合を CI 側に寄せていく。


## rev.42 — Views 組み込み。ViviMusic の UI が前面に

### rev.41 の確認

```
11:29:32.583  PLAYER  [PM→web] load …watch?v=GD-ZqpHVMHY&list=RDMM…
11:29:32.592  NAV     page start        ← 9ms で開始（rev.40 では来なかった）
11:29:42.118  NAV     page stop success=true
11:29:45.868  MEDIA   metadata title = 【ハミダシクリエイティブOP Full】…
```

`PromptDelegate` の設定で遷移が復活した。
再生中でも URL 遷移が通り、`list=` も引き継がれている。

### 組み込み

`Sources/Vivi/Views`（22 ファイル）を追加し、
`MusicHostViewController.swift` の除外を外した。

```
Sources/App              11
Sources/Vivi/Core         5
Sources/Vivi/InnerTube    7
Sources/Vivi/Views       22
Sources/Vivi/Services    12
合計                      57 ファイル
```

**ViviMusic の全層が入った。**

### 事前検証

- `Views` が参照する型を機械走査し、未解決が無いことを確認。
  候補に挙がった 11 個は全て SwiftUI 標準（`AsyncImage` /
  `NavigationPath` / `LabeledContent` など）か `Core` 定義
  （`BrowseRoute` / `SearchFilter`）、または `Views` 内定義
  （`TogetherChatView`）だった
- `EqualizerView` が除外した `EqualizerTap` / `BiquadFilter` に
  触れていないことを確認
- `RootView` 系が要求する `@EnvironmentObject` 7 種と、
  `MusicHostViewController` が注入する 7 種が**完全に一致**することを確認。
  いずれも `.shared` を持つ

### 画面構成

```
[SwiftUI RootView]     ← 前面。ホーム / 探索 / 検索 / ライブラリ
[Gecko]                ← 背面。alpha 0.02 で敷いたまま
```

Gecko はビュー階層から外さない。
完全に外すとタイマーが絞られて再生が止まる恐れがあるため。

**測定用のブラウザ画面は残してある。**
🧩 からブリッジ診断と `PlayerManager` テストを続けられる。
これまで何度もこの画面のログで原因を特定してきたため、
`Views` を載せた直後こそ切り分け手段が要る。

切り替えは**設定画面のボタン**で行う。

```
設定 → 診断 → 「ブラウザ画面を開く」   → ブラウザ画面
ツールバー左端の家アイコン              → 音楽 UI に戻る
```

当初は 3 本指タップにしていたが、
存在に気づけない・SwiftUI のスクロールと競合する・誤爆する、
という理由で明示的なボタンに変えた。

`Views` から Kotone の型を直接参照すると層が混ざるので、
`NotificationCenter` で疎結合にしてある
（`Kotone.showBrowser` / `Kotone.showMusicUI`）。


## rev.41

### 修正: 再生開始後にページ遷移できなくなる

```
11:12:44  NAV  page stop success=true         ← 最後に成功した遷移
11:13:00       （再生開始）
11:13:43  NAV  load https://duckduckgo.com/…  ← page start が来ない
11:14:42  NAV  load https://music.youtube.com/search?q=…  ← 来ない
11:15:31  PLAYER [PM→web] load …              ← 来ない
```

**URL バーの文字だけ変わり、実際の遷移が起きない。**
アドレスバーに `m.youtube.com/watch?v=…` を入れても読み込まれず、
`PlayerManager` からの `session.load()` も同様に無視されていた。

原因は **`PromptDelegate` を設定していなかったこと**。

YouTube Music は再生中に `beforeunload` を張る。
Gecko は離脱の可否を embedder に問い合わせ、**応答があるまで遷移を保留する**。
`PromptDelegate` が未設定だと問い合わせが宙に浮き、遷移が永久に始まらない。

`GeckoSession` には `promptDelegate` が用意されていたが、
Kotone 側で繋いでいなかった。

- `session.promptDelegate = self` を追加
- `button` プロンプト（`beforeunload` はここに来る）は **0 番目＝肯定側**を返す。
  Kotone は Gecko を再生エンジンとして使うので、離脱確認は常に許可でよい
- `alert` とその他の入力系は UI を出さずに閉じる。
  ページに勝手なダイアログを出させない
- どのプロンプトが来たかはログに残す

### 補足

`media.geckoview.autoplay.request` と同じ構図だった。
**GeckoView は判断を embedder に委ねる箇所がいくつもあり、
繋いでいないと「無反応」という形で表面化する。**
今後同種の症状が出たら、まず未設定の delegate を疑う。


## rev.40 — Services / InnerTube を組み込み

### 確認: 未解決参照は実在しなかった

`PlayerJSService` / `PoTokenService` / `StreamProbe` / `StreamFetcher` を
`Sources/Vivi/{InnerTube,Services}` で検索したところ、
**すべてコメント内の言及のみ**で実コードからの参照は無かった。

```
InnerTube/YouTubeAPI.swift:216   // PlayerJSService（署名デコード）・…
InnerTube/YouTubeClient.swift:142 ///   - 署名復号 / n 変換 → PlayerJSService
Services/DownloadManager.swift:8  //  取得は StreamFetcher に任せる。
```

`DownloadManager.performDownload` は既に
「現在の構成では未対応」を返す形になっている。

### 組み込み

`project.yml` に `Sources/Vivi/InnerTube` と `Sources/Vivi/Services` を追加。
合わせて **24 ファイル・51 型**。

### 除外: EQ の音声タップ実装

| ファイル | 理由 |
|---|---|
| `Equalizer/EqualizerTap.swift` | `MTAudioProcessingTap` で `AVPlayer` の音声に噛ませる実装。Gecko 内で再生するのでタップ対象が存在しない |
| `Equalizer/BiquadFilter.swift` | 同上（`EqualizerTap` からのみ使用） |

どちらも他から参照されていないことを確認済み。
`EqualizerSettings` は残るので `EqualizerView` は表示できる。

### 整合の確認

`TogetherManager` が使う `PlayerManager` の API 9 種
（`currentSong` / `isPlaying` / `currentTime` / `seek` / `resume` /
`pause` / `next` / `previous` / `play`）がすべて揃っていることを確認。
`$currentSong` / `$isPlaying` の Publisher も `@Published` で提供済み。

`Sources/Vivi` 内の型参照を機械的に走査し、
`Core` 内定義と標準ライブラリ以外への依存が
`PlayerManager`（`Sources/App`）のみであることを確認した。


## rev.39

### `PlayerManager` の動作を確認（rev.38 の実測）

```
10:40:37.404  PLAYER  [PM] pause
10:40:37.421  PLAYER  [PM→web] pause ok: { ok = 1; paused = 1; }
10:40:37.427  MEDIA   paused
10:40:37.427  PLAYER  [web→PM] paused           ← 往復 23ms

10:40:48.312  PLAYER  [PM] seek to 14.4
10:40:48.321  MEDIA   position 14.4 / 276.0     ← 9ms で反映
10:40:48.327  PLAYER  [PM→web] seek ok: { currentTime = "14.36225" }
```

**操作 → ページ → MediaSession → PlayerManager の往復が全て成立。**
`pause` / `resume` / `seek` のいずれも、
ページ側の結果が `MediaSession` 経由で戻ってきている。

### 修正 1: URL を貼られると壊れる

```
[PM] play https://youtu.be/6qkUHaRXvtE?si=…
[PM→web] load https://music.youtube.com/watch?v=https://youtu.be/…
```

`Song.id` は本来 videoId だが、URL が入ることがある。
`extractVideoID(from:)` を追加し、次の形に対応した。

| 入力 | 抽出 |
|---|---|
| `6qkUHaRXvtE` | そのまま |
| `https://youtu.be/6qkUHaRXvtE?si=…` | パス末尾 |
| `https://www.youtube.com/watch?v=…&t=10` | クエリ `v` |
| `https://music.youtube.com/watch?v=…&list=…` | クエリ `v` + `list` も引き継ぐ |
| `https://www.youtube.com/shorts/…` | パス末尾 |

5 形式すべてで正しく取れることを確認済み。

### 修正 2: ページを離れると操作が届かない

```
ERR  [PM→web] pause 失敗: Error: music.youtube.com のタブがありません
```

測定用ブラウザでは AMO などへ自由に遷移できるため起きる。
最終形（Gecko を背面に固定）では起きないが、起きたときに復帰できるようにした。

- 失敗メッセージに `music.youtube.com` が含まれていれば、
  `session.load("https://music.youtube.com/")` で戻す
- 拡張機能側は現在開いている URL をエラーに添える。
  「どこに居るのか」が分かると切り分けが早い


## rev.38

### 修正（16 件、3 系統）

**(1) `MusicHostViewController.swift` がビルド対象に入っていた（8 件）**

```
error: cannot find 'RootView' in scope
error: cannot find 'LibraryStore' in scope
error: cannot find 'DownloadManager' in scope
…
```

ViviMusic の SwiftUI UI をホストする画面で、
`RootView` / `LibraryStore` / `DownloadManager` / `PlaylistStore` /
`GoogleAuthService` / `CookieAuthService` / `TogetherManager` を参照する。
これらは `Sources/Vivi/{Views,Services}` にあり、
**(A) の方針では組み込んでいない**（現在は `Core` のみ）。

`project.yml` の `Sources/App` の excludes に追加した。
`SceneDelegate` が参照していたので、測定用のブラウザ画面を root に戻した。

**(2) `PlayerManager` の `await` 漏れ（3 件）**

```
error: expression is 'async' but is not marked with 'await'
```

rev.36 で 6 メソッドを `async` にしたが、
`skip` / `setQueue` / `shufflePlay` の内部から
`play` / `setQueue` を呼ぶ箇所に `await` を付け忘れていた。

**(3) ネスト関数のアクター分離（5 件）**

```
error: main actor-isolated property 'currentSong' can not be
       referenced from a nonisolated context
```

`Task { @MainActor in }` の中で定義したネスト関数は、
**外側のアクター分離を継承しない**。`@MainActor` を明示した。

### 追加: 除外ファイルへの参照を検出する

`scripts/check-symbols.sh` を拡張した。
`project.yml` の excludes からファイル名を読み、
**ビルド対象外なのに他から参照されていないか**を検査する。

```
MISS MusicHostViewController  (ビルド対象外なのに参照あり)
     参照元: Sources/App/SceneDelegate.swift
```

除外は「ビルド対象から外す」だけで参照は残るため、
`cannot find ... in scope` として遅れて表面化する。
今回の失敗を再現して検出できることを確認済み。


## rev.37 — 再生開始を URL 渡しに変更

### 変更: 曲の開始は `GeckoSession.load()` で行う

`content.js` の `location.assign()` で遷移させていたのを、
**Gecko のセッションに URL を渡す方式**に変えた。

```swift
session.load("https://music.youtube.com/watch?v=<videoId>")
```

- 拡張機能の注入タイミングに依存しない
- ブラウザ UI が既に使っている実証済みの経路
- content script が未注入の状態でも曲を開始できる

`PlayerManager` に `weak var session: GeckoSession?` を持たせ、
`BrowserViewController.startSession()` が設定する。
セッションが未設定のときはブリッジ経由にフォールバックする。

**`play` / `pause` / `seek` / `next` は引き続き HTTP ブリッジ**を使う。
これらはページ内の操作であり、URL 遷移では実現できない。

### 修正: 自動再生が embedder の許可待ちになっていた

```
defaults/pref/mobile.js:33
  pref("media.geckoview.autoplay.request", true);
```

GeckoView は自動再生の可否を embedder に問い合わせる作りで、
Kotone はその応答を実装していない。
**URL を読み込んでも再生が始まらない**ことになる。

音楽アプリなので常に許可でよい。`applyDefaultPrefs` に追加した。

```swift
"media.geckoview.autoplay.request": false,
"media.autoplay.default": 0,          // 0 = allowed
"media.autoplay.blocking_policy": 0,
```

### 追加: videoId 指定の再生テスト

🧩 の「PlayerManager」に「URL 指定で曲を再生」を追加。
`videoId` を入力して `PlayerManager.play(song:)` を呼ぶ。
**再生開始が `GeckoSession.load()` で成立するか**を単体で確認できる。


## rev.36 — PlayerManager

### Phase 2 完了の確認（rev.35 の実測）

```
09:09:15.196  MEDIA   paused
09:09:15.200  BRIDGE  HTTP event { currentTime=3.224479, event=pause }
09:09:15.530  MEDIA   playing          ← 334ms 後
09:09:15.549  BRIDGE  HTTP event { currentTime=3.224479, event=play }
```

疎通テストの `toggle` × 2（間に 300ms スリープ）と時間差が一致。
**Swift → 拡張機能 → ページの操作が実際に効いている。**

### 追加: Gecko 版 `PlayerManager`

`Sources/App/PlayerManager.swift`。
ViviMusic の `Playback/PlayerManager.swift`（932 行、`AVPlayer` +
自前 InnerTube）の代替で、API だけ同じにして中身を差し替えた。

```
読み取り  MediaSessionDelegate → currentSong / isPlaying / currentTime / duration
操作      KotoneHTTPBridge     → play / pause / next / seek / openVideo
```

**Views の呼び出し形に合わせて非同期化した。**
実測した `await player.*` の呼び出し箇所:

```
play(10) setQueue(3) shufflePlay(2) next(2) skip(1) previous(1)
```

この 6 メソッドを `async` にしてある。
`RepeatMode` は Views から直接参照されていない
（`cycleRepeatMode()` 経由のみ）ため、ネストせずトップレベルに置いた。

`MediaSessionDelegate` の 5 つのコールバックから
`applyMetadata` / `applyPlaybackState` / `applyPosition` /
`applyPlaybackNone` へ配線した。

### 変更: `Sources/Vivi` は `Core` のみ組み込み

`project.yml` に `Sources/Vivi` 全体が入っていたため、
`PlayerJSService` などの未解決参照でビルドが通らない状態だった。
**`Sources/Vivi/Core` のみに絞った。**

`Core`（`Song` / `BrowseRoute` ほか 30 型）が単独で通ることは、
コメントと文字列を除去したうえで外部シンボルを機械的に照合して確認した。

### 追加: 疎通テストに `PlayerManager` の通し確認

🧩 の「PlayerManager」セクションから、
`pause` → `play` → `seek(+10)` を順に実行し、
各段階で `currentSong` / `isPlaying` / `currentTime` / `duration` /
`lastErrorMessage` を表示する。

**読み取り（MediaSession 由来）と操作（HTTP ブリッジ経由）が
噛み合っているかがここで分かる。**


## rev.38

69 件のエラーが出たが、**原因は 4 種類だけ**だった。

### 修正 1: `deploymentTarget` が低すぎた（58 件）

```
'NavigationStack' is only available in iOS 16.0 or newer          × 14
'onChange(of:initial:_:)' is only available in iOS 17.0 or newer  ×  6
'LabeledContent' / 'AnyShape' / 'presentationDetents' / …
```

ViviMusic の `Views` は iOS 16 / 17 の SwiftUI API を前提にしている。
`15.0` のままにしていたのが誤りだった。

**`26.0` に変更。** 対象機は iPadOS 26.6 なので実害はない。
`probe-toolchain` の実測で `-mios-version-min 26.0` でも
`XUL` へのリンクが警告ゼロで通ることは確認済み。
15.0 以上なので `libswift_Concurrency.dylib` の同梱も引き続き不要。

### 修正 2: `LogEntry` の名前衝突（10 件）

```
error: invalid redeclaration of 'LogEntry'
error: 'LogEntry' is ambiguous for type lookup in this context   × 7
```

`Sources/App/MeasurementLog.swift` の `LogEntry` と
`Sources/Vivi/Core/EventLog.swift` の `LogEntry` が衝突していた。

Kotone 側を **`MeasurementEntry`** にリネーム。
ViviMusic のコードには手を入れない方針を優先した。

### 修正 3: `EqualizerTap` / `BiquadFilter`（5 件）

```
error: a C function pointer can only be formed from a reference to
       a 'func' or a literal closure   × 5
```

`MTAudioProcessingTap` の実装。ViviMusic では `AVPlayer` の音声に
噛ませていたが、Kotone では再生が Gecko 内なのでタップする対象が無い。

**どこからも参照されていない**ことを確認したうえで `project.yml` で除外。
`EqualizerSettings` と `EqualizerView` は残るので UI は出る（設定値が効かないだけ）。

### 修正 4: `RepeatMode` のメンバー不足（2 件）

```
error: value of type 'RepeatMode' has no member 'iconName'
error: value of type 'RepeatMode' has no member 'isActive'
```

rev.36 で新規定義した際、`symbolName` という別名にしていた。
ViviMusic の元実装と同じ `iconName` / `isActive` に揃えた。

### 追加: 型名の重複検査

`scripts/check-symbols.sh` に追加。ViviMusic のコードを取り込む以上、
同名の型は今後も起こりうる。

```
重複 LogEntry: Sources/App/_dup_test.swift, Sources/Vivi/Core/EventLog.swift
::error::型名 LogEntry が複数のファイルで宣言されています
```

意図的に重複を作って検出できることを確認済み。


## rev.37

### 修正

- **`SettingsView.swift` の波括弧が壊れていた**

  ```
  Sources/Vivi/Views/SettingsView.swift:212:1:
    error: extraneous '}' at top level
  ```

  rev.36 で `PoTokenService` の参照を除去する際、
  **`if let error = poToken.lastError {` の行だけを削除**したため、
  対応する閉じ括弧が浮いていた。行単位の機械的な置換が原因。

  ブロックごと正しく除去した。

  **エラーはこの 1 件だけ。** 13,349 行を一度に配線したにもかかわらず、
  `Sources/Vivi` の型不一致は 1 件も出なかった。
  `PlayerManager` の API を ViviMusic と揃えた判断が効いている。

### 追加: `scripts/check-braces.sh`

同種の破壊を Swift コンパイラより先に捕まえる。

文字列リテラルとコメントを潰したうえで `{` `}` を数え、
収支が 0 でないファイルと、途中で負になった行を報告する。
構文解析はしないが、「削除で片方だけ消えた」類は確実に捕まる。

rev.36 と同じ壊し方を再現して検出できることを確認済み。

```
NG   Sources/Vivi/Views/SettingsView.swift  行 206 で閉じ括弧が過剰（最終収支 -1）
```

CI では `Check own symbols` の前に実行する。


## rev.36 — PlayerManager と Views の配線

### Phase 2 完了の確認（rev.35 の実測）

疎通テストの `toggle` × 2（間に 300ms のスリープ）が
ログの時間差と一致した。

```
09:09:15.196  MEDIA   paused
09:09:15.200  BRIDGE  HTTP event { currentTime=3.224479, event=pause }
09:09:15.530  MEDIA   playing            ← 334ms 後
09:09:15.549  BRIDGE  HTTP event { currentTime=3.224479, event=play }
```

**Swift → 拡張機能 → ページ の向きが実証された。**

### 追加: `Sources/App/PlayerManager.swift`

ViviMusic の `Views` が使う 25 メンバーを満たす Gecko 実装。
ViviMusic の `Playback/PlayerManager.swift`（AVPlayer + 自前 InnerTube）は
取り込まず、**API だけ同じにして中身を差し替えた**。

| 向き | 経路 |
|---|---|
| 読み取り | `MediaSessionDelegate` → タイトル / アーティスト / アルバム / 位置 / 状態 |
| 操作 | `KotoneHTTPBridge` → play / pause / next / seek / openVideo |

ログには層が分かる接頭辞を付けた。**失敗時に切り分けられる。**

```
[PM]      PlayerManager 自身
[PM→web]  ページへの操作
[web→PM]  MediaSession からの反映
```

### 追加: `Sources/App/MusicHostViewController.swift`

SwiftUI の `RootView` を前面に、`GeckoView` を背面に置く。

**`GeckoView` はビュー階層から外さない。** 完全に外すとタイマーが絞られ
再生が止まる恐れがあるため、`alpha = 0.02` で敷いたままにする。

**3 本指タップでブラウザ画面に切り替えられる**（切り分け用）。

### 除去: 未解決参照 4 種

| 対象 | 対処 |
|---|---|
| `YouTubeAPI.resolveStream` 系 264 行 | 削除。再生は Gecko が担う |
| `PlayerJSService`（署名デコード） | 呼び出しを削除 |
| `PoTokenService`（BotGuard） | 呼び出しを削除 |
| `StreamProbe` | 呼び出しを削除 |
| `DownloadManager.performDownload` | 無効化。再設計が必要 |
| `InnerTube` の `signatureTimestamp` | 削除 |

**検索・ブラウズ（`home` / `explore` / `search` など）はそのまま使う。**
保存済みファイルの一覧・削除・再生も従来どおり動く。

### 変更

- `project.yml` に `Sources/Vivi` を追加（11,369 行）
- `SceneDelegate` のルートを `MusicHostViewController` に変更
- `MediaSessionDelegate` の 5 メソッドから `PlayerManager` に反映
- `LogKind` に `PLAYER` を追加

### 想定される失敗と切り分け

初回で通る見込みは高くない。ログの接頭辞で層を特定できる。

| 症状 | 層 |
|---|---|
| ビルドエラー | `Sources/Vivi` の型不一致。ファイル名で特定できる |
| UI は出るが曲が出ない | `[web→PM]` が出ていなければ MediaSession 側 |
| 再生ボタンが効かない | `[PM→web]` のエラーを見る |
| 検索が空 | InnerTube 層。`resolveStream` 除去の巻き込みを疑う |


## rev.35 — Phase 2 突破

### HTTP 経路が動作した

```
03:46:40.363  BRIDGE  HTTP: 拡張機能が接続しました: 0.7.0
03:47:49.785  BRIDGE  HTTP event payload={
    currentTime = 0;
    duration = "<null>";
    event = play;
    type = video;
} tabId=10001
```

**入れ子のペイロードが完全な形で届いた。**
`content.js` の `<video>` イベントが `background.js` を経由して
Swift まで到達している。

### 正規経路は使えないと結論

```
port 診断: how=waived(empty) dataSize=152 revivedType=object names=[] text={}
```

**`dataSize=152`** — クローンバッファには 152 バイト入っている。
つまりデータは送られているのに `deserialize()` が空を返す。

- `globalThis` / `this` / `{}` のいずれを渡しても変わらない
- `ChromeUtils.waiveXrays()` を挟んでも変わらない
- 同じメッセージの `sender` は入れ子まで完全に届く
  → オブジェクト → `NSDictionary` の変換自体は正常

この Gecko iOS 移植に固有の不具合と判断し、追跡を打ち切る。
`KotoneBridge` は接続の検知（connected / disconnected）にのみ使い、
冒頭に結論と実測値をコメントとして残した。
空ペイロードの警告は 1 回だけ出すようにしてログを整理した。

### 追加: 再生制御

HTTP 経路に載せた。**`PlayerManager` の土台になる。**

`content.js` の `commands`（ページの JS 変数には触れず、
`<video>` と DOM ボタンだけで操作する）

| コマンド | 実装 |
|---|---|
| `play` / `pause` / `toggle` | `<video>` の `play()` / `pause()` |
| `next` / `previous` | プレイヤーバーのボタンを `click()` |
| `seek` | `video.currentTime` |
| `setVolume` | `video.volume` |
| `openVideo` | `watch?v=` へ遷移（SPA なので `location.assign`） |
| `probe` | 現在状態の取得 |

Swift 側は `KotoneHTTPBridge` に同名のメソッドを用意した。

疎通テストは 3 段階を確認する。

1. `ping` — 単純な往復
2. `probe` — content script までの往復
3. **`toggle` × 2** — 実際にページを操作して元に戻す

- `manifest.json` を `0.8.0` に更新


## rev.34

### 判明したこと

```
port 診断: how=globalThis(empty) ctor=StructuredCloneHolder
           own=[] proto=[deserialize,dataSize,constructor]

受信の生データ (GeckoView:WebExtension:Message)
  data:   __NSDictionaryM = { }          ← 空
  sender: __NSDictionaryM = {
    contextId = 687194767361;
    envType = "addon_child";             ← 入れ子の中身が届いている
```

- `holder` は本物の `StructuredCloneHolder`
- `deserialize(globalThis, true)` はオブジェクトを返すが空
- **同じメッセージの `sender` は入れ子まで完全に届いている**
  → オブジェクト → `NSDictionary` の変換自体は正常
- `sendNativeMessage`（別経路）でも `data` は空

**構造化クローンの復元だけが壊れている**ことが確定した。

### 対応 1: 原因をさらに絞る

`fix-port-message.py` に以下を追加。

- **`holder.dataSize`** を報告。クローンバッファが本当に空なのか、
  復元だけが失敗しているのかを区別できる
- **`ChromeUtils.waiveXrays()`** を試す。
  Xray ラッパー越しだとプロパティが見えないため、
  それが原因なら剥がせば取れる
- `Object.getOwnPropertyNames()` で列挙不可のプロパティも確認

### 対応 2: 構造化クローンを完全に迂回する経路

**`Sources/GeckoView/KotoneHTTPBridge.swift`（新規）**

Gecko のメッセージング機構を一切使わず、
ローカル HTTP で JSON をやり取りする。

```
拡張機能  --fetch("http://127.0.0.1:47821/…")-->  Swift (NWListener)
          <--ロングポーリング (/poll)------------
```

- `127.0.0.1` のみ待ち受け（`requiredInterfaceType = .loopback`）
- 共有トークンで照合
- `/hello` `/event` `/poll` `/reply` の 4 経路
- Swift → 拡張機能は `/poll` で待たせて配る

**ポートとトークンの受け渡し**が課題だったが、
`scripts/AddGecko.sh` がビルド時に `kotone-config.js` を生成し、
**拡張機能とアプリの双方が同じファイルを読む**形にした。
実行時の受け渡し経路が要らない。

疎通テストは HTTP 経路が生きていればそちらを優先する。

- `manifest.json` を `0.7.0` に更新。
  `http://127.0.0.1/*` 権限と `kotone-config.js` の読み込みを追加


## rev.33

### 判明: 中身は JS 側の時点で既に空

rev.32 の保険キーが決定的な情報をくれた。

```
data:       __NSDictionaryM = { }
kotoneText: NSTaggedPointerString = {}      ← 文字列として "{}"
```

**文字列の JS→ネイティブ変換は正常に通っている。**
`kotoneText` は `JSON.stringify(revived)` の結果であり、
それが `"{}"` ということは **`revived` が JS 側で既に空のオブジェクト**。

つまり:

- 変換の問題ではない（文字列は通る）
- `deserialize({})` → `deserialize(globalThis)` の修正でも直らない
- 構造化クローンの復元そのものが空を返している

### 対応: 2 方向から原因を絞る

**(1) `holder` の正体を JS 側から報告させる**

`fix-port-message.py` を拡張し、復元方法を 5 通り試して
どれで値が取れたか、`holder` が何者かを文字列で持ち出す。

```js
const attempts = [
  ["globalThis", () => holder.deserialize(globalThis, true)],
  ["this",       () => holder.deserialize(this, true)],
  ["empty",      () => holder.deserialize({}, true)],
  ["data",       () => holder.data],
  ["holder",     () => holder],
];
```

結果は `kotoneDebug` として送る（文字列は確実に届くため）。

```
port 診断: how=… holderType=… ctor=… own=[…] proto=[…] revivedType=…
```

**(2) もう一方の経路を同時に試す**

`browser.runtime.sendNativeMessage()` は Gecko 側の**別のコード**
（`GeckoViewConnection.sendMessage`）を通る。
ポート経由が駄目でもこちらは通る可能性がある。

`background.js` が起動 1.5 秒後に、JSON 文字列とオブジェクトの
両方で `sendNativeMessage` を投げる。
Swift 側は受信内容を要約した JSON 文字列を返す
（`sendRequestForResult` なので戻り値が拡張機能の `await` の解決値になる）。

**これが通れば「要求 → 応答」が成立するので、
ポートを使わない設計に切り替えられる。**

- `manifest.json` を `0.6.0` に更新


## rev.32

### 原因の特定: 構造化クローンの復元先が誤っている

rev.31 で JSON 文字列に変えても結果は同じだった。

```
data: __NSDictionaryM = { }      ← 文字列を送ったのに空の辞書
```

**送る中身の問題ではない。** Gecko 側の呼び出しが誤っていた。

```js
// modules/GeckoViewWebExtension.sys.mjs:174
data: holder.deserialize({}),
```

`StructuredCloneHolder.deserialize()` の第 1 引数は
**復元先のグローバルオブジェクト**を渡す場所。
同じツリーの他の呼び出しはすべて適切なグローバルを渡している。

```js
modules/ExtensionParent.sys.mjs:1314   result.deserialize(globalThis)
modules/ExtensionStorage.sys.mjs:32    value.deserialize(globalThis)
modules/ExtensionChild.sys.mjs:165     holder.deserialize(this.context.cloneScope)
modules/GeckoViewWebExtension.sys.mjs  holder.deserialize({})        ← ここだけ
```

復元に失敗し、**渡した `{}` がそのまま返っている**とみられる。
Swift 側で観測していた「空の辞書」の正体は、この引数の `{}` そのもの。
何を送っても永久に空になる。

### 対応: `scripts/fix-port-message.py`（新規）

`{}` を `globalThis` に置き換える。対象は 2 箇所。

- `EmbedderPort.onPortMessage` — ポート経由（`connectNative`）
- `GeckoViewConnection.sendMessage` — 単発（`sendNativeMessage`）

**保険も同時に入れた。** 正しいグローバルを渡してもなお
JS オブジェクトの変換が不安定な可能性があるため、
値を文字列化した `kotoneText` キーを併せて渡す。
Swift 側は `kotoneText` → `data` → `message` → `payload` の順に見る。

実 Gecko ファイルに適用し、構文・冪等性・出力内容を確認済み。
`relax-builtin-location.py` と併用しても衝突しない。

- `manifest.json` を `0.5.0` に更新
- `THIRD_PARTY_NOTICES.md` に改変内容を追記（MPL-2.0）

### 補足

仮設のブラウザ UI とリロードボタンは正常に動作していることを確認済み
（実機で検証）。UI の見え方の違和感はモーダル遷移中の表示によるもので、
不具合ではなかった。


## rev.31

### 原因の確定: JS オブジェクトが Swift に届かない

rev.30 の生データ出力で決着した。

```
02:47:33.875  BRIDGE  受信の生データ (GeckoView:WebExtension:PortMessage)
  data: __NSDictionaryM = {
}
```

キーは `data` のみで、中身は**空の辞書**。
`hello` に入れた `num` / `flag` / `nested` / `list` が全て消えている。

Gecko 側は

```js
onPortMessage(holder) {
  this.dispatcher.sendRequest("...:PortMessage", {
    data: holder.deserialize({}),     // ← 空オブジェクトをグローバルとして復元
  });
}
```

としており、そうして作られたオブジェクトが JS→ネイティブ変換で
列挙できず、空辞書になっているとみられる。

### 対応: JSON 文字列で運ぶ

オブジェクトを諦め、**両方向とも JSON 文字列**にした。
文字列は単純な値なので変換を通り抜けられる。

- `background.js` — `port.postMessage(JSON.stringify(payload))`、
  受信時は `JSON.parse`
- `KotoneBridge` — 受信は `data` が文字列なら `JSONSerialization` で解く。
  送信は `encodeJSON` で文字列化してから渡す
- 辞書のまま届いた場合の経路も残してある（環境が変わったとき用）

Node と Python で往復をシミュレートし、
ネスト辞書・数値・真偽・配列が保たれることを確認済み。

- `manifest.json` を `0.4.0` に更新

### 確認できたこと

- **起動時の自動組み込みが動作した**

  ```
  02:47:28.667  ADDON   updated: Kotone Bridge enabled=true
  02:47:33.873  BRIDGE  connected — dispatcher=port:687194767363
  02:47:33.880  BRIDGE  起動時の組み込み: ✅ インストール成功  経路: resource://android/
  ```

  手動操作なしでインストールと接続が完了するようになった。

- `content.js` の `video` イベントも届いている
  （`受信: 空のペイロード` の時刻が `MEDIA playing/paused` と一致）


## rev.30

### 前進: ポート経路が通った

```
02:35:03.272  BRIDGE  connected — dispatcher=port:1649267441668
02:35:03.274  BRIDGE  受信: [:]
02:35:25.843  BRIDGE  受信: [:]
```

rev.29 の `port:<portId>` dispatcher が正しかった。
`connected` の直後に `hello` が、以降は `content.js` の
`video` イベントが届いている（タイミングが `MEDIA playing/paused` と一致）。

**経路は正しく、ペイロードの取り出し方だけが誤っている。**

### 修正: 起動のたびに組み込みアドオンが消える

```
02:34:19.948  ADDON  installed addons: (なし)     ← 前回入れたのに消えている
```

`installBuiltinAddon` で入れた組み込みアドオンは**アプリの再起動で消える**。
GeckoView は起動のたびに `ensureBuiltIn` を呼ぶ設計だった。

- 起動時（最初のページ描画後）に `installBridge()` を自動実行するようにした。
  バージョンが同じなら何もしない（冪等）
- 接続待ちの警告を 15 秒 → 40 秒に延長。
  起動時インストールとページ読み込みの前に出ると紛らわしいため

### 追加: ペイロードの形を実測する

推測で直すより、実際の形をログに出す。

- **受信**: 最初の 1 通だけ、メッセージの全キーと型と値を出す
  （`dumpShape`）。`extractPayload` は `data` / `message` / `payload` を
  順に見て、空でないものを採る。`NSDictionary` も受け付ける
- **`hello` の中身を多様化**。ネスト辞書・数値・真偽・配列を入れ、
  Gecko → Swift の写像で何が潰れるかを判別できるようにした

  ```js
  post({ type: "hello", version, num: 42, flag: true,
         nested: { a: 1, b: "two" }, list: [1, 2, 3] });
  ```

- **送信の到達確認**: `background.js` が受け取った生データを
  `echo` として送り返す。
  Swift → 拡張機能の向きが届いているかは、これまで確認手段が無かった

- `manifest.json` を `0.3.0` に更新（`ensureBuiltIn` の再インストール判定用）


## rev.29

### 成功: ブリッジが接続した

```
02:20:18  BRIDGE  connected — extension=bridge@kotone.example.com
                  port=Optional(2199023255555)
requiredPermissions = (geckoViewAddons, nativeMessaging, tabs)
```

rev.28 の `geckoViewAddons` 追加が正解だった。

### 修正: ポートの送受信経路が間違っていた

接続はできたが、**送受信の相手を取り違えていた。**

Gecko 側の `EmbedderPort` は専用の dispatcher を作る。

```js
// modules/GeckoViewWebExtension.sys.mjs
class EmbedderPort {
  constructor(portId, messenger) {
    this.dispatcher = lazy.EventDispatcher.byName(`port:${portId}`);
    this.dispatcher.registerListener(this, [
      "GeckoView:WebExtension:PortMessageFromApp",
      "GeckoView:WebExtension:PortDisconnect",
    ]);
  }
  onPortDisconnect() {
    this.dispatcher.sendRequest("GeckoView:WebExtension:Disconnect", …);  // ← 名前が違う
  }
  onEvent(aEvent, aData) {
    case "GeckoView:WebExtension:PortMessageFromApp":
      … aData.message …    // ← portId は見ない
  }
}
```

rev.28 までの誤り:

| 項目 | 誤り | 正しい |
|---|---|---|
| 受信の購読先 | ランタイム dispatcher | **`port:<portId>` dispatcher** |
| 切断イベント名 | `…:PortDisconnect` | **`…:Disconnect`** |
| 送信の宛先 | ランタイム dispatcher | **`port:<portId>` dispatcher** |
| 送信データ | `{portId, message}` | **`{message}`** |

`PortDisconnect` は**アプリ側から切断を要求する**ときの入力イベント名で、
Gecko からの通知は `Disconnect`。逆向きだった。

### 名前付き dispatcher が到達可能であることの確認

```objc
// GeckoViewSwiftSupport.h
@protocol SwiftGeckoViewRuntime <NSObject>
- (id<SwiftEventDispatcher>)runtimeDispatcher;
- (id<SwiftEventDispatcher>)dispatcherByName:(const char*)name;   // ← これ
@end
```

```swift
// GeckoRuntime.swift:28
func dispatcher(byName name: UnsafePointer<CChar>!) -> any SwiftEventDispatcher {
    return GeckoEventDispatcherWrapper.lookup(byName: String(cString: name))
}
```

Gecko が `EventDispatcher.byName("port:N")` を作ると、
同名の Swift wrapper に `attach` される。
`lookup(byName:)` は Reynard 本体では未使用だが、この経路のために存在する。

### その他

- ポート接続時に `dispatcher.activate()` を呼ぶ。
  `dispatch()` は「listener 無し + queue 非 nil」のとき送信せず貯めるため、
  attach 前に送ったものが取り残されないようにする
- 再接続時は古いポートを先に外す（再インストールで二重にならないように）


## rev.28

### 前進: ブリッジのインストールに成功

rev.27 の Gecko 側 JS 緩和が効いた。

```
02:06:49  ADDON  installed as built-in from resource://android/
  isBuiltIn   = 1
  webExtensionId = "bridge@kotone.example.com"
  enabled     = 1
  requiredPermissions = (nativeMessaging, tabs)
```

`uri.fileName` が `undefined` を返すという読みが当たっていた。

あわせて uBlock Origin 導入後は
`album = ごはんはおかず/U&I` のようにアルバム名まで届くようになった。
広告が混ざっていたときは `album` が空だった。

### 修正: `geckoViewAddons` 権限が抜けていた

インストールは成功したが `connectNative` が繋がらなかった。

```js
// modules/ExtensionParent.sys.mjs:259
openNative(nativeApp, sender) {
  if (context.extension.hasPermission("geckoViewAddons")) {
    return new GeckoViewConnection(...);        // ← ここに入る必要がある
  } else if (sender.verified) {
    return new NativeApp(context, nativeApp);   // ← 外部プロセスを探しに行く
  }
}
```

`manifest.json` に `nativeMessaging` しか書いていなかったため、
**Firefox 標準の `NativeApp`**（ネイティブホストのプロセスを起動する仕組み）
に流れていた。iOS にそんなプロセスは無いので必ず失敗する。

`geckoViewAddons` は privileged 権限だが、
組み込みアドオンは `builtIn ⇒ isPrivileged`
（`Extension.sys.mjs` の `getIsPrivileged`）なので付与される。
`nativeMessaging` 自体も `PRIVILEGED_PERMS_ANDROID_ONLY` に含まれており、
それが受理されていたことが privileged である証拠だった。

- `manifest.json` に `geckoViewAddons` を追加
- version を `0.1.0` → **`0.2.0`** に更新。
  `ensureBuiltIn` はバージョン比較で再インストールを判断するため、
  上げないと古いものが残る

### 追加: 繋がらないときの手掛かり

- `background.js` が起動時に `browser.permissions.getAll()` を出す
- `KotoneBridge.activate()` は 15 秒待って接続が無ければ、
  確認すべき点をログに出す（黙って繋がらないのを防ぐ）
- 購読しているイベント名も列挙する


## rev.27

### 判明: 末尾スラッシュの問題ではなかった

rev.26 で候補 3 つを試した結果、**すべて同じエラー**だった。

```
resource://android/                  → folders URIs must end with a "/"
resource://android/kotone-bridge/    → 同上
resource://android/bridge/           → 同上
```

`resource://android/` はパスが `/` だけなので、
末尾スラッシュが原因ならこれは通るはず。通らないということは別の理由がある。

```js
if (uri.fileName !== "") { ... }
```

`uri.fileName` は `nsIURL` 由来。この iOS ビルドでは `resource://` の URI が
`nsIURL` として公開されていないらしく **`undefined`** を返す。
`undefined !== ""` が真になるため、**どんなフォルダ URI も拒否される**。

### 対応: Gecko 側の JS を直接緩める

Gecko のリソースは展開状態（`omni.ja` に固められていない）で、
起動キャッシュを落とす `.purgecaches` も置かれている。
つまり `.mjs` を書き換えれば反映される。

**`scripts/relax-builtin-location.py`**（新規）が
`validateBuiltInLocation` を以下のとおり改変する。

- `resource://` に加えて **`file://` を許可**
- `uri.host === "android"` の制約を外す
- `uri.fileName` の判定を**文字列として取れたときのみ**に限定

冪等で、該当箇所が見つからなければ明示的に失敗する
（Gecko のバージョンが変わったときに気づけるように）。

実際の Gecko ファイルに適用し、構文と冪等性を確認済み。

### 変更

- `KotoneBridge.builtInCandidates()` が **`file://` を第一候補**にする。
  `AddGecko.sh` が拡張機能を置く
  `<App>.app/Frameworks/GeckoView.framework/Frameworks/kotone-bridge/` を
  実フォルダとして直接指す。`resource://android/` は予備として残す
- `manifest.json` の実在を確認し、無ければ
  「AddGecko.sh の配置が効いていない可能性」を明示する
- `THIRD_PARTY_NOTICES.md` に Gecko 改変の内容を記載（MPL-2.0）


## rev.26

### 判明: 署名要求はコンパイル時に固定されている

rev.24 の対策 A（pref を戻す）は**原理的に不可能**だった。

```js
// modules/AppConstants.sys.mjs:115
MOZ_REQUIRE_SIGNING: true,

// modules/addons/AddonSettings.sys.mjs:32
if (AppConstants.MOZ_REQUIRE_SIGNING && !Cu.isInAutomation) {
  makeConstant("REQUIRE_SIGNING", true);   // pref を一切見ない
}
```

`greprefs.js:1246` の `pref("xpinstall.signatures.required", false)` を
根拠に「未署名アドオンを入れられる」と判断したのが誤り。
`defaults/pref/mobile.js:38` が true に上書きし、
さらに `AppConstants` がコンパイル時に固定していた。
**見るべきは pref ではなく `AppConstants` だった。**

未署名 .xpi は何をしても `installError = -5`
(`ERROR_SIGNEDSTATE_REQUIRED`) になる。

### 対応: 組み込み経路に一本化

`AddonManager.installBuiltinAddon()` は署名検査を通らない。

rev.24 の B 経路は URI で弾かれていた。

```
This URI does not point to a folder. Note: folders URIs must end with a "/".
```

`resource://android/bridge/` を渡していたが、
`validateBuiltInLocation` の `uri.fileName !== ""` に引っかかった。

- `AddGecko.sh` の substitution を**拡張機能フォルダそのもの**に向けた
  （`resource android file:kotone-bridge/`）。
  サブパスを噛ませないので `resource://android/` で済み、
  パスが `/` だけになる
- `KotoneBridge.installBuiltIn()` は候補 URI を順に試し、
  **それぞれの失敗理由をまとめて返す**。
  どの形が通るか未確定なので切り分けを兼ねる

  ```
  resource://android/
  resource://android/kotone-bridge/
  resource://android/bridge/
  ```

- `.xpi` 経路を廃止。`AddonCatalog.bundledBridgeURL` も削除
- `applyDefaultPrefs` から署名関連 pref を除去し、
  効かない理由をコメントに明記。
  `xpinstall.whitelist.*` は害が無いので残す

`scripts/PackExtension.sh` は残してある。
将来 AMO 署名版を配る場合と、URL 手入力での切り分けに使えるため。


## rev.25

### 修正

- **`AddonController.installBridge` が存在しなかった**

  ```
  Sources/App/AddonsViewController.swift:218:55:
    error: value of type 'AddonController' has no member 'installBridge'
  ```

  rev.24 で不要になった `installBundledBridge` を削除した際、
  **直後に追記していた `installBridge` まで巻き込んで消していた**。
  範囲指定を誤った編集ミス。復旧した。

### 追加

- **`scripts/check-symbols.sh`** — 独自シンボルの相互参照を検査する

  Swift コンパイラを起動せずに「呼んでいるのに定義が無い」を検出する。
  CI の `Install XcodeGen` の前に実行し、macOS ランナーを 10 分使ってから
  型エラーで落ちるのを防ぐ。

  **設計上の要点**: 検索を「その型を定義しているファイル」に限定している。

  最初は全文検索で書いたが、それでは
  `AddonsViewController.installBridge`（別の型の同名メソッド）に
  引っかかり、**rev.24 の事故を検出できなかった**。
  型 → 定義ファイル（本体 + `extension`）を先に特定し、
  その範囲だけを見るようにした。

  rev.24 と同じ状況を再現して検出できることを確認済み。

  ```
  MISS AddonController.installBridge  (1 箇所)
  ::error::AddonController.installBridge が呼ばれていますが
           Sources/App/AddonController.swift に定義がありません
  ```


## rev.24

### 修正

- **自作アドオンのインストールが必ず失敗していた**

  ```
  ERR  install failed
    code = -5        ← AddonManager.ERROR_SIGNEDSTATE_REQUIRED
    name = Kotone Bridge
  ```

  rev.20 で `greprefs.js:1246` の
  `pref("xpinstall.signatures.required", false)` を確認して
  「未署名アドオンを入れられる」と判断したが、**上書きを見落としていた**。

  ```
  greprefs.js:1246            pref("xpinstall.signatures.required", false);
  defaults/pref/mobile.js:38  pref("xpinstall.signatures.required", true);   ← これ
  ```

  AMO 署名済みの uBlock Origin は入るのに自作だけ落ちるのは、これが理由。

  **対策 A（既定）** — `GeckoRuntime.setDefaultPrefs` で pref を戻す。
  セッションを開く前に実行する。
  `greprefs` 側の既定が false ということは `MOZ_REQUIRE_SIGNING` が
  コンパイル時に有効化されていない（有効なら既定が true になる）ので、
  pref を戻せば効くはず。
  あわせて `xpinstall.whitelist.required` と
  `xpinstall.whitelist.fileRequest` も開ける。

  **対策 B（フォールバック）** — 組み込みアドオンとして入れる。
  `GeckoView:WebExtension:EnsureBuiltIn` は
  `AddonManager.installBuiltinAddon()` を使うため**署名検査を通らない**。

  ただし `validateBuiltInLocation` が
  `scheme == "resource" && host == "android"` を要求し、
  この iOS ビルドに `resource://android` は登録されていない。
  そこで `AddGecko.sh` が
  - `Extension/` を Gecko リソース配下の `kotone/bridge/` に配置
  - `chrome.manifest` に `resource android file:kotone/` を追記

  し、`resource://android/bridge/` を解決可能にした。

  A が失敗したら自動的に B を試す。

- **「タップしても無反応」だった**

  インストール結果をログにしか出していなかった。
  進行と結果をアラートで表示するようにした。

  ```
  ✅ インストール成功（.xpi）
  ✅ インストール成功（組み込み）
  ❌ どちらの経路でも失敗しました
  ```

### 参考: 今回のログから読めたこと

- ブリッジの listener 登録自体は成功している
  （`BRIDGE  bridge listening on runtime dispatcher`）
- 子プロセスは 14 個まで増加。種別は `tab` / `rdd` / `utility`
- 親プロセスのメモリは 178.5 MB


## rev.23 — ブリッジ復帰

rev.22（ViviMusic 取り込み）に、rev.20/21 の
WebExtension ↔ Swift ブリッジを戻した。
`PlayerManager` の操作側がブリッジ無しでは書けないため。

### 復帰したもの

- `Sources/GeckoView/KotoneBridge.swift` — ブリッジのネイティブ側
- `Extension/` — 自作 WebExtension「Kotone Bridge」
  （`manifest.json` / `background.js` / `content.js`）
- `scripts/PackExtension.sh` — `Extension/` を `.xpi` にまとめる
- アドオン画面の「Kotone Bridge」セクション
  （同梱版インストール / 疎通テスト）
- `LogKind.bridge`

### 再発防止（rev.21 由来）

- `.gitignore` に `!Sources/GeckoView/KotoneBridge.swift`
- CI の `Verify own sources survived import` ステップ

  `import-reynard.sh` の `PROTECTED` を読み、実在を確認する。
  rev.20 は `.gitignore` に引っかかって push されず
  `error: cannot find 'KotoneBridge' in scope` で落ちた。

### rev.19 との差異に注意した点

添付の Kotone は rev.19 で **Gecko 有効の展開済み状態**だったため、
`project.yml` の `postBuildScripts` はコメントアウトされていない。
rev.20 のパッチをそのまま当てると不一致になるので、
実際の記述に合わせて適用した。
`GECKO-TOGGLE` の往復（enable → disable → enable）が
バイト単位で一致することを確認済み。

### 現状

`Sources/Vivi/`（11,369 行）は**まだ `project.yml` に未組み込み**。
ビルド対象は rev.19 と同じで、そこにブリッジが加わった状態。

次は Gecko 版 `PlayerManager` の作成と、未解決参照 4 種の除去。


## rev.22 — ViviMusic のソースを取り込み

UI 方針を転換し、**ViviMusic のネイティブ SwiftUI UI** を採用する。
Reynard のように外部から取得せず、**本リポジトリ内に置く**（vendoring）。

### 取り込み — `Sources/Vivi/`（11,369 行 / 48 ファイル）

| 層 | 行数 |
|---|---:|
| `Views/` | 5,172 |
| `InnerTube/` | 2,395 |
| `Core/` | 1,136 |
| `Services/` | 2,666 |

### 除外（5,922 行）

**すべて再生系。Gecko が肩代わりするため不要。**

`Playback/`（1,812）/ `Services/SABR/`（1,579）/
`Services/PoToken/`（875）/ `PlayerJSService`（913）/
`StreamProbe`（489）/ `StreamFetcher`（218）/ `App/`（36）

ViviMusic で最も苦労した部分——`AVAssetResourceLoader`、
SABR の自前実装、BotGuard、`base.js` の署名デコード——が
まるごと不要になる。

### 現状

**まだ `project.yml` には組み込んでいない。ビルドは rev.19 のまま通る。**

未解決の参照が残っているため（詳細は `docs/VIVIMUSIC.md`）:

| シンボル | 参照数 | 対処 |
|---|---:|---|
| `PlayerManager` | 24 | **Gecko 版を新規に書く** |
| `PlayerJSService` | 4 | 呼び出しを削る |
| `PoTokenService` | 3 | 呼び出しを削る |
| `StreamFetcher` | 2 | ダウンロード機能の再設計 |
| `StreamProbe` | 1 | 呼び出しを削る |

`PlayerManager` は Views が使うのが**約 25 メンバーだけ**という
綺麗な境界になっている。同じ API を満たす Gecko 版を書けば
`Views/` は無改修で動く。

読み取り側（`currentSong` / `isPlaying` / `currentTime` / `duration`）は
`MediaSessionDelegate` で既に全項目の到達を確認済み。
操作側には `KotoneBridge`（rev.20）が必要。


## rev.19

### 修正

- **起動時クラッシュの真因は実行スレッドだった**

  rev.18 で接続タイミングを「最初のページ描画後」まで遅らせたが、
  **まったく同じクラッシュが再発した**。診断が誤っていた。

  ```
  Thread com.apple.root.user-initiated-qos.cooperative (crashed)
    0  XUL        mozilla::dom::AutoJSAPI::Init(JSObject*) +52
    1  GeckoView  GeckoEventDispatcherWrapper.query(type:message:)
    5  GeckoView  AddonRuntime.list()
  ```

  スレッド名が答えだった。**協調スレッドプールで動いている。**

  `GeckoEventDispatcherWrapper` はスレッド安全でもアクター分離でもなく、
  `dispatch()` から `gecko?.dispatch(toGecko:)` で直接 XUL に入る。
  Gecko の `AutoJSAPI::Init` はメインスレッド前提なので、
  そこから呼ばれると null 参照で即死する。

  `AddonRuntime.list()` は `nonisolated async` なので、
  `Task { @MainActor }` から `await` しても協調プールへ逃げる。

  Reynard の `project.pbxproj` を確認したところ、
  **アプリ本体と `GeckoView` の Debug/Release 計 4 箇所**に
  以下が設定されていた。

  ```
  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
  SWIFT_APPROACHABLE_CONCURRENCY = YES;
  ```

  Swift 6.2 の既定アクター分離。注釈の無いコードが全て MainActor に
  乗るため、この経路がメインスレッドに固定される。
  **同じソースでもビルド設定が違えば動作が変わる**という例。

  `Helper` と `OpenIn` には設定されていないので、こちらも合わせた。
  動作実証済みの構成から不必要に外れないため。

  - `AddonController` の `nonisolated` 注釈を削除
    （既定分離が MainActor になるため矛盾する）
  - rev.18 の遅延接続はそのまま残す。独立した保険として有効


## rev.18

### 修正

- **起動直後に必ずクラッシュする（rev.17 の不具合）**

  ```
  Thread com.apple.root.user-initiated-qos.cooperative  (crashed)
    0  XUL        mozilla::dom::AutoJSAPI::Init(JSObject*) +52
    1  GeckoView  closure #1 in GeckoEventDispatcherWrapper.query(type:message:)
    5  GeckoView  AddonRuntime.list()
    6  GeckoView  closure #1 in AddonRuntime.delegate.didset
  EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0000000000000008
  ```

  `AddonRuntime.delegate` の `didSet` は自動的に `list()` を投げる。
  これは `GeckoView:WebExtension:List` を**ランタイムの**ディスパッチャに
  流すもので、**Gecko の JS ランタイムが立ち上がる前に届くと
  `AutoJSAPI::Init` が null を参照して落ちる**。

  rev.17 は `BrowserViewController.viewDidLoad` から即座に
  `activate()` を呼んでいた。`startSession()` の直後ではあるが、
  `session.open()` は Gecko の準備完了を待たずに戻る。

  Reynard は最初のタブを作った後の `Task { @MainActor }` で
  `AddonCoordinator.start()` を呼んでいる
  （`BrowserViewController.swift:156`）。
  本 rev はさらに安全側に倒し、**最初のページが実際に描画された後**
  （`onFirstContentfulPaint` / `onPageStop(success:)`）まで待つ。
  コンテンツプロセスが生きていることが保証されるので競合の余地がない。

  - `activate()` を冪等にし、`@MainActor` を明示
  - `refresh()` は未接続なら何もしない
  - アドオン画面を先に開かれた場合の保険として、
    `AddonsViewController.viewDidLoad` からも `activate()` を呼ぶ
    （この時点では既にページが開かれている）

### 追加

- **Gecko 子プロセスの起動ログ**

  `GeckoRuntime.ChildProcessDidStart` 通知を購読し、
  `processType` と `pid` を記録する。

  ```
  INFO  child process #1 started — type=tab pid=1234
  INFO  child process #2 started — type=gpu pid=1235
  ```

  App Extension が実際に何個・どの種類で立ち上がっているかが分かる。
  親プロセスの `phys_footprint`（142 MB）には子プロセス分が
  含まれないため、メモリ余力の判断材料になる。

- `onFirstContentfulPaint` でもメモリを記録する


## rev.17 — WebExtension 基盤と広告除去

### Phase 1 の最重要項目を通過（rev.16 の実測）

```
21:53:50  position 0.3 / 275.8   ← 再生開始
21:58:25  MARK 再生位置 65 秒に到達  ← ★
21:58:25  playback none            ← 275 秒の曲を完走
```

**65 秒の壁は存在しなかった。** しかも未ログイン（広告付き）の匿名セッション。
ViviMusic で `visitorData` バケット・スロットリングとして観測していた現象は、
公式プレイヤー経由では発生しない。

メモリは **142 MB**。iPad 第 9 世代の 3 GB に対して十分軽い。
`MediaSession` のメタデータと `features`
(`play, pause, stop, seekTo, next, prev`) も全て届いており、
Phase 3（ロック画面連携）の前提も揃った。

### 追加

- **`UserAgentPolicy.swift`** — URL ごとの UA 決定

  Reynard の `UserAgentPolicy` から必要部分を移植。

  ```swift
  if host == "addons.mozilla.org"        { return Android UA (強制) }
  if url.hasPrefix("moz-extension://")   { return Android UA (強制) }
  return prefersDesktop ? Linux desktop UA : Android UA
  ```

  **AMO はデスクトップ UA だと「Firefox へ追加」ボタンを出さない。**
  rev.15 はデスクトップ UA 固定だったため、
  そのままではアドオンを 1 つもインストールできなかった。
  `onLocationChange` でも UA を追従させ、リダイレクトで
  AMO に飛んだ場合にも対応する。

- **`AddonController.swift`** — `AddonEmbedderDelegate` の実装

  **これが無いと `install()` は必ず失敗する。**
  インストール時の権限プロンプトに応答する経路が存在しないため。
  権限・アクセス先・データ収集を一覧するアラートを出し、
  ユーザーの選択を `AddonPermissionPromptResponse` として返す。
  `uBlock Origin` は `<all_urls>` を要求するのでアクセス先が長くなる。
  8 件まで表示して残りは件数で畳む。

- **`AddonsViewController.swift`** — アドオン管理画面
  - インストール済み一覧（有効/無効トグル、スワイプで削除）
  - おすすめ（uBlock Origin / SponsorBlock / AMO）
  - `.xpi` の URL を直接指定してインストール

- `project.yml` — `UTImportedTypeDeclarations` と
  `CFBundleDocumentTypes` に `org.mozilla.xpi-extension` を追加。
  他アプリから `.xpi` を「Kotone で開く」で受け取れるようにする

### 修正

- **`about:` などのスキームが検索クエリに化けていた**（rev.15 の不具合）

  ```
  NAV  load https://duckduckgo.com/?q=about:blank   ← 誤り
  ```

  `://` を含まない `about:` / `moz-extension:` / `data:` /
  `resource:` / `chrome:` を URL として扱うようにした

### 使い方

ツールバーに 🧩 が増えている。

1. 🧩 → 「uBlock Origin」→ AMO が Android 表示で開く
2. 「Firefox へ追加」→ 権限プロンプトで「追加」
3. `music.youtube.com` に戻って再生
4. 📋 の測定ログで、Uber / Red Bull / SUUMO のような
   広告メタデータが消えたかを確認する


## rev.16

### 修正

- **`project.yml` を Gecko 有効の状態でコミットするようにした**

  rev.15 のビルドが `auto` で実行され、Gecko 無効のまま失敗した。

  ```
  note: Target dependency graph (1 target)
  Sources/App/main.swift:21:8:
    error: unable to resolve module dependency: 'GeckoView'
  ```

  `on` を選び直せば済む話ではなく、**rev.15 で `Sources/App` が
  `import GeckoView` を必須にした時点で、0-B1 モードは
  構造的に成立しなくなっていた**。既定値を変えていなかったのが不備。

  Phase 0 は完了したので、リポジトリの既定状態を有効に切り替えた。
  以降は push するだけでビルドされ、手動実行でも `auto` のままでよい。

- `enable-gecko.sh --disable` — `Sources/App` に `import GeckoView` が
  あるときは警告を出す。無効化すると必ずビルドが失敗するため
- `build.yml` — `gecko_integration` の説明を実態に合わせた


## rev.15 — Phase 1 測定用の最小ブラウザ

**Phase 0 完了。** rev.14 の署名除去で実機起動に成功し、
診断画面が全項目 ✅ になった（`XUL` 221 MB / dylib 9 個 /
Gecko リソース / `Reynard Helper.appex` の名前一致、バンドル 283.2 MB）。

### 追加

- **`Sources/App/main.swift`** — `UIApplicationMain` から
  **`GeckoRuntime.main()`** に切り替え。
  Gecko は XPCOM を初期化してから UIKit のイベントループに入るため、
  この順序でないと動かない。`@main` は引き続き使わない。
  `JITController.start()` は `#if KOTONE_ENABLE_JIT` で括ってある

- **`Sources/App/BrowserViewController.swift`** — 測定用の最小ブラウザ
  - `GeckoView` + URL バー + 戻る/進む/再読込
  - **デスクトップ UA 切り替え**（既定はデスクトップ）。
    Reynard の `UserAgentPolicy.defaultConfiguration` と同じ組み立てで、
    `Mozilla/5.0 (X11; Linux x86_64; rv:153.0) Gecko/20100101 Firefox/153.0`。
    Gecko + iOS はサイト側が想定しない組み合わせなので、
    Reynard も Linux/Android を名乗っている
  - 起動時に `music.youtube.com` を開く
  - `onCrash` / `onKill` をログに出す。JIT 無しでは SpiderMonkey が重く、
    コンテンツプロセスが落ちる可能性があるため

- **`Sources/App/MeasurementLog.swift`** — 測定記録と表示

  **65 秒問題の判定を経過時間ではなく `MediaSession` の
  `positionState`（ページ内の実再生位置）で行う。**
  その最大値を「水位」として追い、30 / 60 / **63 / 65** / 70 / 80 /
  100 / 120 / 180 / 300 秒の通過を記録する。

  ```
  MARK  再生位置 63 秒に到達  ← 65 秒の壁が近い
  MARK  再生位置 65 秒に到達  ← ★ 65 秒を突破
  ```

  シークや曲の切り替えで水位が下がらないようにしてある。
  ヘッダに最大再生位置とメモリ使用量（`phys_footprint`）を表示し、
  共有ボタンで全文をテキストとして書き出せる。

### 変更

- `SceneDelegate` — ルートを `BrowserViewController` に変更。
  診断画面はツールバーの ✓ アイコンから push で到達できる
- `AppDelegate` — Reynard の構造に揃えた（`final` を外し、
  `didDiscardSceneSessions` を追加）。`GeckoRuntime.main` 経由の
  デリゲート解決に影響しうるため構造を変えない。
  バックグラウンド遷移とメモリ警告をログに記録する（測定項目 5・6 用）

### 使い方

1. ツールバー右端の ✓ で `Frameworks/XUL` などが ✅ か確認
2. `music.youtube.com` でログインし、曲を再生
3. 📋 アイコンで測定ログを開き、**最大再生位置**を見る
4. 共有ボタンでログを書き出す


## rev.14

### ビルドは成功。実機で起動時クラッシュ

rev.13 で `** BUILD SUCCEEDED **`。IPA も生成された。
しかし起動と同時に `EXC_CRASH (SIGABRT)`。

```
termination: DYLD / Library missing
  Library not loaded: @rpath/XUL
  Reason: tried: '.../Kotone.app/Frameworks/XUL'
          (code signature invalid ... (errno=1)
           sliceOffset=0x00000000,
           codeBlobOffset=0x0D01A110, codeBlobSize=0x001A4B40)
```

### 原因

`engine/dist/bin/` の `XUL` と 9 個の dylib には
**Reynard 配布 IPA の署名がそのまま残っていた**。
抽出元の `Reynard.app` は Xcode の archive で署名済みで、
`LC_CODE_SIGNATURE` ごとコピーされてくるため。

配布 IPA の `XUL` を解析すると、クラッシュログの値と完全に一致する。

```
LC_CODE_SIGNATURE  offset=0x0D01A110  size=0x1A4B40
CodeDirectory      ident='XUL'  teamID=(なし)  adhoc=no
```

**この一致は「再署名されずに元の署名が残っている」ことの直接的な証拠**である。

`AddGecko.sh` は `CODE_SIGNING_ALLOWED=NO` のとき `codesign` を
まるごとスキップしていたが、それだけでは不十分だった。
「署名しない」と「古い署名を消す」は別の話で、後者が抜けていた。

### 修正

- `AddGecko.sh` — 署名しないときは `codesign --remove-signature` で
  `XUL` と全 dylib の古い署名を除去する
- `build.yml` の `Package IPA` に、入れ子 Mach-O の署名状態を
  一覧表示する診断を追加


## rev.13

### 修正

- **`GeckoView.framework` に Info.plist が無い**

  ```
  error: Framework .../Kotone.app/Frameworks/GeckoView.framework
         did not contain an Info.plist (in target 'Kotone')
  ```

  `project.yml` の `GeckoView` ターゲットに `info:` を書いていなかったため、
  `ProcessInfoPlistFile` が一度も実行されていなかった
  （`Helper` と `Kotone` には書いてあったので、そちらは生成されていた）。

  **Swift のコンパイルも、XUL と 9 個の dylib へのリンクも、
  `AddGecko.sh` による 280MB のエンジン展開も全部成功した後、
  最後の `Validate` 段階で落ちる**ため原因が分かりにくい類のエラー。

  Reynard の `browser/GeckoView/Info.plist` と同じ内容を
  `info.properties` として定義した。

  なお `import-reynard.sh` は取り込んだ `Info.plist` を削除するが、
  これは正しい（XcodeGen が同じパスに生成するため）。

### この時点での到達状況

| 段階 | 状態 |
|---|---|
| Reynard ソースの取得 | 成功 |
| ヘッダ 3 種 + `mozilla-config.h` の生成 | 成功 |
| `GeckoView` の Swift/ObjC コンパイル | 成功 |
| `GeckoView` のリンク（XUL + dylib 9 個） | 成功 |
| `Reynard Helper.appex` のビルド | 成功 |
| `Kotone` 本体のビルドとリンク | 成功 |
| `AddGecko.sh` によるエンジン展開 | 成功 |
| バンドル検証 | ← ここで失敗 |


## rev.12

### 修正

- **`mozilla-config.h` が見つからない**

  rev.11 でエラーは 29 件 → 1 件になり、残ったのはこれだけだった。

  ```
  Sources/GeckoView/Runtime/GeckoRuntimeBridge.mm:10:9:
    fatal error: 'mozilla-config.h' file not found
  ```

  本物の `mozilla-config.h` は Gecko のビルドが
  `obj-dir/dist/include/` に生成する巨大な設定ヘッダで、
  配布 IPA には含まれない（IPA 内の `.h` は 0 個）。

  取り込んだソース全体を走査したところ、**参照しているのはこの 1 ファイルだけ**で、
  必要なマクロも `MOZILLA_VERSION` ひとつだけだった。

  ```objc
  #import "mozilla-config.h"
  + (NSString *)version { return @MOZILLA_VERSION; }
  ```

  そこで `scripts/fetch-headers.sh` が最小版を生成するようにした。
  値は `engine/VERSION.txt` の `GECKO_MILESTONE`
  （`fetch-engine.sh` が `platform.ini` と照合済み）から取る。

  取り込んだソースを書き換える案もあったが、次回の
  `import-reynard.sh` で上書きされるため採らなかった。

### 確認

取り込んだ ObjC/C++ ソースの `#import` / `#include` を全て走査し、
解決先を確認した。未解決は以下 2 件のみで、どちらも実害なし。

| ヘッダ | 状況 |
|---|---|
| `TSUtils.h` | ブリッジングヘッダの**コメント内**の言及のみ |
| `JITEnabler.h` | `#if defined(KOTONE_ENABLE_JIT)` の内側。JIT 無効時は評価されない |


## rev.11

### 修正

- **`GeckoView` / `Helper` にブリッジングヘッダが設定されていなかった**

  0-B2 初回ビルドで 29 件のエラー。すべて同一原因だった。

  ```
  Sources/GeckoView/Addons/Addon.swift:8: cannot find type 'NSObject' in scope
  Sources/GeckoView/Events/EventDispatcher.swift:38: cannot find type 'SwiftEventDispatcher'
  Sources/GeckoView/Runtime/GeckoRuntime.swift:99: cannot find 'MainProcessInit'
  Sources/GeckoView/Runtime/GeckoRuntime.swift:35: cannot find 'updateJetsamControl'
  ...
  ```

  framework ターゲットでは通常 umbrella header で ObjC 宣言を Swift に見せるが、
  Reynard は **Headers ビルドフェーズを空にしたまま、
  `browser/Configuration/Reynard.xcconfig` で全ターゲットに
  `SWIFT_OBJC_BRIDGING_HEADER` を設定**していた
  （`project.pbxproj` の 6 箇所で確認。`OpenIn` 拡張だけ空文字）。

  rev.2 で `headerVisibility` を撤回した際、代替経路を用意し忘れていた。

  `Addon.swift` のように `import Foundation` を書かず
  ブリッジングヘッダ経由で Foundation を得ているファイルがあるため、
  `NSObject` すら見つからない状態になっていた。

  失われていた 13 個のシンボルが、すべてブリッジングヘッダから
  到達可能であることを確認済み:

  | シンボル | 解決先 |
  |---|---|
  | `SwiftEventDispatcher` `EventCallback` `GeckoEventDispatcher` | `GeckoViewSwiftSupport.h` |
  | `SwiftGeckoViewRuntime` `GeckoProcessExtension` | `GeckoViewSwiftSupport.h` / `IOSBootstrap.h` |
  | `GeckoOrientationLockResult` `GeckoViewWindow` `GeckoViewOpenWindow` `GeckoViewInteractionDelegate` | `GeckoViewSwiftSupport.h` |
  | `MainProcessInit` `ChildProcessInit` | `IOSBootstrap.h` |
  | `GeckoRuntimeBridge` | `Sources/GeckoView/Runtime/GeckoRuntimeBridge.h` |
  | `updateJetsamControl` | `Sources/Shared/Utils.h` |

- **`HEADER_SEARCH_PATHS` を再帰指定に変更**

  `GeckoRuntimeBridge.h` は `Sources/GeckoView/Runtime/` にあり、
  非再帰の `$(SRCROOT)/Sources/GeckoView` では見つからない。
  Reynard は Xcode のプロジェクト headermap 経由で解決していたが、
  明示的に `/**` を付けた。`Helper` `Bridging` `Shared` も同様。


## rev.10

### 変更

- **ターミナル無しで Gecko 統合を切り替えられるようにした**

  `build.yml` に `Apply Gecko toggle` ステップを追加。
  `gecko_integration` 入力が `on` / `off` のとき、
  ランナー上で `scripts/enable-gecko.sh` を実行して
  `project.yml` を実行内だけ書き換える。

  これまでは「手元で `enable-gecko.sh` を実行して push」が前提だったが、
  GitHub の Web UI だけで運用している場合に実行できなかった。

  ```
  Actions → build → Run workflow → gecko_integration: on → Run workflow
  ```

  - 書き換えはランナー上のみ。リポジトリには反映されない
  - `auto`（既定）は従来どおり `project.yml` の状態に従う
  - 入力と `project.yml` が食い違う場合は警告ではなく
    「この実行内で書き換えます」という通知に変更


## rev.9

### 追加

- **`scripts/import-reynard.sh`** — Reynard の Swift ラッパ層を取得・展開する

  ```bash
  ./scripts/import-reynard.sh                # engine/VERSION.txt の タグから取得
  ./scripts/import-reynard.sh --from DIR     # ローカルのソースを使う
  ./scripts/import-reynard.sh --clean        # 取り込み分を削除
  ./scripts/import-reynard.sh --keep-src DIR # 展開ツリーを残す（CI 用）
  ```

  **ソースはリポジトリにコミットせず、ビルド時に取得する方針。**
  対応表はスクリプト内の `MAPPING` を唯一の定義とし、
  `docs/PLACEMENT.md` はその記録という位置づけにした。

  - `Sources/Bridging/Kotone-Bridging-Header.h`（独自ファイル）は上書きしない
  - 未使用ファイルを取り込み時に除去する
    （`View/GeckoView.h`、`Reynard-Bridging-Header.h`、各 `Info.plist`、
    `Helper/Entitlements/`）
  - tarball の SHA256 を記録し、`engine/VERSION.txt` の
    `REYNARD_SRC_SHA256` に設定すれば以降のビルドで検証する
    （タグの付け替え検知）
  - `Sources/IMPORT_PROVENANCE.txt` に取得元を記録

### 修正（実際に取り込んで判明した問題）

- **`Helper` ターゲットに `GeckoView` への依存が無かった**

  `Sources/Helper/Helper.swift` が `import GeckoView` している。
  `embed: false` で追加した（実体はアプリ本体が `Frameworks/` に置き、
  appex は `@executable_path/../../Frameworks` 経由で参照する）。

- **不要ファイルがバンドルに混入する**

  Reynard の `Info.plist`（XcodeGen が生成するので不要）と
  `Helper/Entitlements/`（無料 Personal Team では使えない private 権限を含む）が
  リソースとして取り込まれていた。
  `import-reynard.sh` で削除し、`project.yml` でも除外する二重の対策にした。

- **`HEADER_SEARCH_PATHS` に `Sources/Helper` が無かった**

  bridging header が `#import "ExtensionBridge.h"` するが、実体は
  `Sources/Helper/` にある。Xcode のプロジェクト headermap 経由でも
  解決されるはずだが、明示しておく。
  `Sources/Bridging` `Sources/Shared` も同様に追加した。

### 変更

- `build.yml` に `Import Reynard sources` ステップを追加。
  `--keep-src` で展開ツリーを残し、`fetch-headers.sh` に渡すことで
  **同じ tarball を 2 回ダウンロードしない**ようにした
- `Verify engine layout` に `Sources/` の中身チェックを追加
- `.gitignore` — 取り込み分を除外（`.gitkeep` と独自ファイルは残す）
- `enable-gecko.sh` — CI 取得方式に合わせ、ローカルでソース未配置でも
  エラーにせず注意書きを出すだけにした。`--status` に取り込み済みタグを表示


## rev.8

### 変更

- **JIT を 0-B2 の対象から外した**

  `Sources/JIT/` は `RPPairing/libidevice_ffi.a` を必要とするが、これは
  `tools/development/build-idevice.sh` が Rust でクロスコンパイルする成果物で、
  reynard-browser のリポジトリにも配布 IPA にも含まれていない
  （静的ライブラリなのでバイナリからの抽出も不可）。

  Gecko は JIT なしでも動作する（SpiderMonkey がインタプリタになり遅いだけ）。
  0-B2 で確認したいのは「Gecko が子プロセスを起動して描画できるか」であり、
  同時に入れると失敗時の切り分けができなくなる。

  **結合は閉じていることを確認済み。** `Sources/{GeckoView,Helper,Shared}` から
  JIT シンボルへの参照は 0 件で、唯一の接点は bridging header の
  `#import "JITEnabler.h"` だった。これを `KOTONE_ENABLE_JIT` で条件化した。

- **トグルのマーカー系統を 2 つに分離**

  | 系統 | ブロック | 切り替え |
  |---|---|---|
  | `GECKO-TOGGLE:*` | `flag` / `bridging` / `deps` | `enable-gecko.sh` / `--disable` |
  | `JIT-TOGGLE:*` | `sources` / `settings` | `--with-jit` / `--without-jit` |

  互いに独立して切り替わる。`--with-jit` は `libidevice_ffi.a` が無ければ拒否する。

### 修正

- **トグルの往復でインデントがずれるバグ**

  無効化時に `#@ ` を挿入する位置を「その行の先頭空白」から
  **「マーカー行のインデント」**に変更した。前者だと
  ブロック内で相対インデントを持つ行（`  excludes:` や `  - target:`）が
  往復のたびに左へ寄っていき、`#@` の位置が階段状にずれていた。

  YAML としては同値なので実害は無かったが、`git diff` にノイズが出る。

  5 周回 + 逆順で完全一致することを確認済み。

- `--status` の表示を拡充。Gecko / JIT の状態に加えて
  `Sources/` 各ディレクトリの配置状況を一覧表示する


## rev.7

### 修正

- **`-undefined dynamic_lookup` を廃止し、Reynard 本家と同じリンク構成にした**

  ビルドログに出ていた警告:

  ```
  ld: warning: -undefined dynamic_lookup is deprecated on iOS
  ```

  `MainProcessInit` / `ChildProcessInit` を実行時解決に頼るのは誤りだった。
  Reynard の `browser/Configuration/Reynard.xcconfig` と `project.pbxproj` を
  読み直したところ、**XUL と 9 個の dylib を明示的にリンク**していた。

  ```
  OTHER_LDFLAGS = $(GECKO_DIST)/bin/XUL
                  -lmozglue -lnss3 -lfreebl3 -lsoftokn3 -llgpllibs
                  -lmozavcodec -lmozavutil -lgkcodecs -lmozinference
  LIBRARY_SEARCH_PATHS = $(inherited) $(GECKO_DIST)/bin
  HEADER_SEARCH_PATHS  = $(inherited) $(GECKO_DIST)/include
                         $(GECKO_DIST)/include/GeckoView $(SRCROOT)/GeckoView
  LD_RUNPATH_SEARCH_PATHS = $(inherited) @executable_path/Frameworks
                            @executable_path/Frameworks/GeckoView.framework
  ```

  これを `GeckoView` / `Helper` / `Kotone` の 3 ターゲットに反映した。
  deprecated 警告が消えるだけでなく、**未定義シンボルがリンク時に
  検出される**ようになる（実行時クラッシュではなくビルドエラーになる）。

  - `HEADER_SEARCH_PATHS` に `$(GECKO_DIST)/include/GeckoView` と
    `$(SRCROOT)/Sources/GeckoView` を追加。
    Reynard の xcconfig と同じ 3 パス構成
  - `Kotone` の `LD_RUNPATH_SEARCH_PATHS` に
    `@executable_path/Frameworks/GeckoView.framework` を追加
  - `ARCHS: arm64` を共通設定に追加。
    Reynard は `VALID_ARCHS` と `ENABLE_BITCODE` も設定しているが、
    現行 Xcode ではどちらも deprecated 警告になるため入れていない

  App 側のリンク設定は `GECKO-TOGGLE:bridging` ブロックに入れたので、
  0-B1 では `OTHER_LDFLAGS` 自体が存在せず警告も出ない。

### 確認

- `Select Xcode` が **Xcode 26.6** を選択。
  Reynard 本家のビルド環境（`DTXcode 2660` / `DTXcodeBuild 17F113`）と一致。
  `SDKROOT = iphoneos26.5` も同一
- 往復テスト（enable → disable）でバイト単位の完全一致を再確認


## rev.6

### 追加

- **`scripts/enable-gecko.sh`** — Gecko 統合の ON/OFF を 1 コマンドで切り替える

  ```bash
  ./scripts/enable-gecko.sh            # 有効化 (0-B2)
  ./scripts/enable-gecko.sh --disable  # 無効化 (0-B1)
  ./scripts/enable-gecko.sh --status   # 状態表示
  ./scripts/enable-gecko.sh --force    # ソース未配置でも有効化
  ```

  `project.yml` の 3 箇所（`GECKO_INTEGRATION` / bridging header /
  `dependencies` + `postBuildScripts`）を同時に切り替える。
  手で 1 つでも漏らすとリンクエラーか実行時クラッシュになり、
  切り分けが面倒になるため。

  - `project.yml` に `# >>> GECKO-TOGGLE:<name> >>>` マーカーを埋め込み、
    マーカー間の `#@ ` プレフィックス行だけを操作する。
    **コメント文言に依存しないので説明文を書き換えても壊れない**
  - 書き換え後に PyYAML で検証し、不正なら `project.yml` を変更しない
  - 有効化前に `Sources/` にソースが配置済みかを確認する
  - 変更前を `project.yml.bak` に保存する
  - **往復（enable → disable → enable）でバイト単位の完全一致を確認済み**

### 変更

- `build.yml` — `gecko_integration` を boolean から
  `choice [auto, on, off]`（既定 `auto`）に変更し、
  **`project.yml` の `GECKO-TOGGLE:deps` マーカーから自動判定**するようにした。
  スクリプトで有効化したのにワークフロー入力を切り替え忘れる、
  という事故を構造的に防ぐ。入力と実状態がズレた場合は警告を出す
- `project.yml` — `GECKO_INTEGRATION` を `"YES"` / `"NO"` と引用符付きに変更。
  YAML では裸の `YES`/`NO` が真偽値に解釈されるため
- `.gitignore` に `*.bak` を追加


## rev.5

### 修正

- **`Select Xcode` ステップが `exit 134` (SIGABRT) で落ちる問題**

  ```bash
  set -euo pipefail
  ver="$("$app/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | ...)"
  ```

  ランナー上の一部の Xcode で `xcodebuild -version` が SIGABRT(134) する。
  `var="$(cmd)"` は代入文が `cmd` の終了コードを継承するため、
  `set -e` 下ではステップごと即死する。`2>/dev/null` は
  エラー出力を捨てるだけで終了コードは伝播する。
  （`probe-toolchain.yml` の同等ステップは `set -e` を入れていなかったため通っていた）

  対処:
  - **`xcodebuild` を起動しない。** `version.plist` を `PlistBuddy` で読む
  - `sort -V` を廃止。macOS の BSD `sort` は対応が不確実なため、
    `awk` でゼロ埋め数値に変換して比較（`26.10 > 26.4.1` も正しく判定）
  - `sudo xcode-select -s` ではなく `DEVELOPER_DIR` を `$GITHUB_ENV` に書く
  - `continue-on-error: true` + `exit 0`。
    **Xcode の選択は最適化であって必須要件ではない**
    （probe で全 Xcode がリンク可能と実証済み）ため、
    失敗してもビルドを止めない

### 同種の危険を全ファイルで監査・修正

`set -e` + `pipefail` 下でコマンド置換を代入する箇所を洗い出し、
非マッチ(exit 1) や SIGPIPE(exit 141) で死にうるものを修正した。

- `scripts/fetch-engine.sh`
  - `grep KEY= | cut` → `awk` 一本の `read_var` / `require_var`。
    キー欠落時は明示的なエラーメッセージで停止する
  - `find ... | head -1` → グロブでのループ（`head` による SIGPIPE 回避）
  - `sed -n ... | head -1` → `awk` の `exit`
  - `du -sh | cut -f1` → `awk` + フォールバック
- `scripts/fetch-headers.sh` — `read_var` を同様に置き換え
- `.github/workflows/probe-toolchain.yml` — `find | head -1` を修正


## rev.4

### 確定

- **ツールチェーンの検証完了**（`probe-toolchain`、72 通り全 CLEAN）

  | runner | Xcode |
  |---|---|
  | `macos-14` | 15.0.1 / 15.1 / 15.2 / 15.3 / 15.4 / 16.1 / 16.2 |
  | `macos-15` | 16.0 / 16.1 / 16.2 / 16.3 / 16.4 / 26.0.1 / 26.1.1 / 26.2 / 26.3 |
  | `macos-26` | 26.0.1 / 26.1.1 / 26.2 / 26.3 / **26.4.1** |
  | `macos-latest` | 26.0.1 / 26.1.1 / 26.2 |

  Xcode 15.0.1 〜 26.4.1 のすべて × `-mios-version-min` 15.0 / 18.0 / 26.0 の
  **全 72 通りで `XUL` へのリンクが警告ゼロで成功**。
  SDK 26.5 でビルドされた `XUL` に対して、古い SDK でも
  リンク互換性の問題は一切なかった。

  → rev.2 のビルド失敗は `PLACE_HERE.md` の出力衝突が唯一の原因で、
    Xcode 16.4 / SDK 18.5 は無関係だった。

### 変更

- `build.yml`
  - `runs-on: macos-15` → **`macos-26`**
  - `Select Xcode` ステップを追加。**利用可能な最新の Xcode 26.x を動的に選択**する
    （バージョン名を決め打ちしないので、イメージ更新で壊れない）。
    リンク互換性の制約は無いが、Reynard 上流が Xcode 26.6 / SDK 26.5 で
    ビルドされているため、Swift ソースが SDK 26 世代の API を
    参照している場合に備えてビルド環境を上流に揃える
- `project.yml` — `deploymentTarget: 15.0` を確定（据え置き）。
  15.0 なら `libswift_Concurrency.dylib` の後方互換同梱が不要

### 残る未解決事項

- なし。**0-B2 に必要な前提はすべて揃った**


## rev.3

### 解決

- **`TSUtils.h` 問題の解決** — 存在しないヘッダではなく、
  *使われていない* ヘッダだった。
  - `browser/GeckoView/View/GeckoView.h` は Reynard 本家でも
    `PBXHeadersBuildPhase` が空のため umbrella header として採用されず、
    `#import "TSUtils.h"` は一度も評価されない
  - `TSUtils` = TrollStore Utils。実体は `Shared/Utils.h` にリネーム済み
  - 実際に使われているのは `Reynard-Bridging-Header.h` の方
  - → `project.yml` で `View/GeckoView.h` を除外

- **Gecko ヘッダ 3 つの入手方法を確定** — firefox の clone は不要。
  - upstream から raw URL で 2 ファイル取得
    （`toolkit/xre/IOSBootstrap.h`, `widget/uikit/GeckoViewSwiftSupport.h`）
  - reynard-browser の patch を 3 つ適用（`--fuzz=0` で検証）
  - `GeckoViewRuntimeSupport.h` は patch が新規作成するため全文が patch に含まれる
  - 依存の閉包はこの 3 ファイル + システムヘッダのみで閉じることを確認済み

### 追加

- `scripts/fetch-headers.sh` — 上記の再構成を自動化。
  `engine/dist/include/GeckoView/` に生成し、`PROVENANCE.txt` を残す
- `Sources/Bridging/Kotone-Bridging-Header.h` — 0-B2 用のテンプレート
- `engine/VERSION.txt` に `FIREFOX_REPO` / `FIREFOX_TAG` を追加

### 変更

- `project.yml`
  - `GeckoView` から `headerVisibility: public` を撤回。
    public にすると `GeckoView.h` が umbrella になり、rev.2 の設定では
    かえって壊れていた
  - `GeckoView` ターゲットに `Sources/Shared` を追加。
    Reynard は `Shared/Utils.m` を `GeckoView` にも所属させており
    （`membershipExceptions`）、`GeckoRuntime.swift` の
    `updateJetsamControl()` 呼び出しに必要
  - `Sources/GeckoView` の excludes に `View/GeckoView.h` を追加
- `build.yml` に `Fetch Gecko headers` ステップと検証を追加

### 残る未解決事項

- ビルドに使う Xcode / iOS SDK（`probe-toolchain.yml` の結果待ち）


## rev.2

### 修正

- **ビルド失敗の修正** — `Sources/*/PLACE_HERE.md` が 5 つとも
  `Kotone.app/PLACE_HERE.md` へフラット出力され、
  `error: Multiple commands produce` でビルドが落ちていた。
  - 配置ガイドを `docs/PLACEMENT.md` に集約し、`Sources/` から撤去
  - `project.yml` の全ソースパスに `excludes` を追加（`**/*.md`,
    `**/LICENSE*`, `**/.gitkeep`）。Reynard のソースにも `.md` や
    `LICENSE` が含まれるため、撤去だけでは再発する

### 追加

- `.github/workflows/probe-toolchain.yml` — 切り分け用ワークフロー。
  runner / Xcode / iOS SDK の実態と、**`XUL` への実リンク可否**を測る
- `Sources/App/` — Phase 0-B1 の最小アプリ。Gecko を起動せず、
  バンドル構成（`XUL`・Gecko リソース・`Reynard Helper.appex` の名前）を
  実機上で検証する `DiagnosticsViewController` を含む
- `LICENSE` (GPL-3.0) / `LICENSE.mpl` (MPL-2.0) / `THIRD_PARTY_NOTICES.md`
- `docs/PLACEMENT.md` — ソース配置マップと未解決課題

### 変更

- `build.yml` に `gecko_integration` 入力を追加。既定 `false`。
  Phase 0-B1 では engine の取得・検証と Gecko の同梱をスキップし、
  配管（XcodeGen → xcodebuild → IPA → SideStore）だけを検証できる
- `build.yml` に `Record toolchain` ステップを追加。
  毎ビルドで Xcode / SDK を Job Summary に記録する
- `project.yml` で `Kotone` → `GeckoView` / `Helper` の依存と
  `AddGecko.sh` の実行を一時コメントアウト（Phase 0-B2 で復活させる）

### 既知の未解決事項

- `TSUtils.h` / `GeckoViewSwiftSupport.h` / `IOSBootstrap.h` の入手方法。
  配布 IPA に `.h` が含まれないため。詳細は `docs/PLACEMENT.md`
- ビルドに使う Xcode / iOS SDK。`XUL` は SDK 26.5 でビルドされているが
  `macos-15` ランナーの既定は Xcode 16.4 / SDK 18.5 だった。
  `probe-toolchain.yml` の結果待ち

## rev.1

- 初版。`project.yml`、`fetch-engine.sh`、`AddGecko.sh`、`rename.sh`、
  `build.yml`、`engine/VERSION.txt`
