# Third Party Notices

本プロジェクトは以下の成果物を利用しています。

---

## Reynard Browser

- https://github.com/minh-ton/reynard-browser
- Copyright (c) Minh Ton
- **GNU General Public License v3.0** — 全文は `LICENSE`

利用範囲:

- `Sources/GeckoView/` — GeckoView の Swift/ObjC ラッパ層
- `Sources/Helper/` — Gecko 子プロセスホスト（NSExtension）
- `Sources/JIT/` — ペアリング方式の JIT 有効化
- `Sources/Bridging/`, `Sources/Shared/`, `Sources/ThirdParty/`
- `scripts/AddGecko.sh` — `browser/Scripts/AddGecko.sh` を改変
- `engine/dist/` — 配布 IPA から抽出した Gecko バイナリ

抽出元のリリースタグは `engine/VERSION.txt` に記録しています。

---

## Mozilla Firefox (Gecko)

- https://github.com/mozilla-firefox/firefox
- Copyright (c) Mozilla Foundation and contributors
- **Mozilla Public License 2.0** — 全文は `LICENSE.mpl`

`engine/dist/` に配置されるバイナリ（`XUL`、各 `.dylib`、および
`chrome/` `modules/` `components/` `actors/` `res/` `defaults/`
`localization/` `greprefs.js` 等のリソース）は Gecko の成果物です。

対応するソースは `FIREFOX_153_0_4_RELEASE` に、
Reynard の `patches/` ディレクトリの改変を適用したものです。
`patches/` 自体も MPL-2.0 です。

MPL-2.0 §3.3 に基づき、これらのファイルは GPL-3.0 の下で頒布される
本著作物の一部として配布されますが、当該ファイル自体は
引き続き MPL-2.0 の条件に服します。

### 本プロジェクトによる Gecko の改変

ビルド時に `scripts/relax-builtin-location.py` が
`modules/GeckoViewWebExtension.sys.mjs` の `validateBuiltInLocation` を
以下のとおり改変します。

- `resource://` に加えて `file://` を許可する
- `uri.host === "android"` の制約を外す
- `uri.fileName` の判定を「文字列として取得できたときのみ」に限定する

理由は、この iOS ビルドに `resource://android` が登録されておらず、
また `resource://` の URI が `nsIURL` として公開されないため
`uri.fileName` が `undefined` となり、あらゆるフォルダ URI が
誤って拒否されるためです。

また `scripts/fix-port-message.py` が同ファイルの
`EmbedderPort.onPortMessage` と `GeckoViewConnection.sendMessage` について、
構造化クローンの復元先を `{}` から `globalThis` に変更します。
`StructuredCloneHolder.deserialize()` の第 1 引数は復元先のグローバルを
渡す場所であり、同ツリー内の他の呼び出しはすべて `globalThis` または
`context.cloneScope` を渡しています。
あわせて、値を文字列としても渡す予備のキーを追加しています。

改変内容は各スクリプトのコメントに記載しています。

---

## Pear Desktop

- https://github.com/pear-devs/pear-desktop
- Copyright (c) th-ch
- **MIT License**

利用範囲:

- `Extension/` — プラグイン設計、Web Audio によるオーディオ加工の実装を参照

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

Pear Desktop は th-ch/youtube-music (MIT) を上流とします。

---

## 商標について

"Mozilla"、"Firefox"、"Gecko"、"Google"、"YouTube"、"YouTube Music" および
関連する名称・ロゴ・意匠は、それぞれの権利者の商標です。
本プロジェクトにおけるこれらの言及は識別を目的とするものであり、
権利者との提携・承認・推奨を意味しません。

"Reynard" の名称は、Gecko エンジンが子プロセスを探索する際に
`Reynard Helper.appex` というファイル名を要求するという技術的理由により
拡張機能の名称としてのみ保持しています。
