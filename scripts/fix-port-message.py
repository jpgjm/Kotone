#!/usr/bin/env python3
"""
fix-port-message.py

Gecko の GeckoViewWebExtension.sys.mjs にある構造化クローンの復元先を直す。
scripts/AddGecko.sh からビルド時に呼ばれる。

背景
----
拡張機能から Swift に送ったメッセージが、中身を失って空の辞書として届く。
実測（rev.30 / rev.31 の生データ出力）:

    BRIDGE  受信の生データ (GeckoView:WebExtension:PortMessage)
      data: __NSDictionaryM = {
    }

オブジェクトで送っても、JSON 文字列で送っても、常に空の辞書になった。
つまり「送る中身」の問題ではない。

原因
----
Gecko 側は次のように書かれている。

    onPortMessage(holder) {
      this.dispatcher.sendRequest("GeckoView:WebExtension:PortMessage", {
        data: holder.deserialize({}),
      });
    }

`StructuredCloneHolder.deserialize()` の第 1 引数は
**復元先のグローバルオブジェクト**を渡す場所であり、
プレーンな `{}` を渡すのは誤り。同じファイル以外の呼び出し箇所は
すべて適切なグローバルを渡している。

    modules/ExtensionParent.sys.mjs:1314   result.deserialize(globalThis)
    modules/ExtensionStorage.sys.mjs:32    value.deserialize(globalThis)
    modules/ExtensionChild.sys.mjs:165     holder.deserialize(this.context.cloneScope)

復元に失敗し、渡した `{}` がそのまま返っているとみられる。
Swift 側で観測される「空の辞書」の正体は、この引数の `{}` そのもの。

対処
----
`{}` を `globalThis` に置き換える。対象は 2 箇所。

  * `EmbedderPort.onPortMessage`   — ポート経由（connectNative）
  * `GeckoViewConnection.sendMessage` — 単発（sendNativeMessage）

Gecko のリソースは展開状態（omni.ja に固められていない）で、起動キャッシュを
落とす .purgecaches も置かれているため、.mjs を書き換えれば反映される。

冪等。既に当たっていれば何もしない。

改変対象は Mozilla のコード（MPL-2.0）。THIRD_PARTY_NOTICES.md に記載する。
"""

import io
import sys

MARK = "/* kotone: deserialize-global */"

OLD_PORT = '''  onPortMessage(holder) {
    this.dispatcher.sendRequest("GeckoView:WebExtension:PortMessage", {
      data: holder.deserialize({}),
    });
  }'''

NEW_PORT = '''  onPortMessage(holder) {
    /* kotone: deserialize-global */
    // Kotone: the embedder receives empty payloads.
    //
    // What we know so far:
    //   * holder really is a StructuredCloneHolder
    //     (proto = [deserialize, dataSize, constructor])
    //   * deserialize(globalThis, true) returns an object with no own keys
    //   * JSON.stringify of it gives "{}"
    //   * plain strings survive the JS -> native conversion
    //   * the sibling `sender` object arrives with all its nested contents,
    //     so object -> NSDictionary conversion itself works fine
    //
    // So the loss happens on the revived clone specifically. Two candidates
    // remain: the clone buffer is empty (nothing was sent), or the revived
    // object is behind an Xray wrapper that hides its properties.
    // dataSize tells the two apart, and waiveXrays covers the second.
    let size = -1;
    try {
      size = holder.dataSize;
    } catch (e) {
      size = -2;
    }

    const waive = v => {
      try {
        return ChromeUtils.waiveXrays(v);
      } catch (e) {
        return v;
      }
    };
    const nonEmpty = v =>
      v !== undefined &&
      v !== null &&
      (typeof v !== "object" || Object.getOwnPropertyNames(v).length > 0);

    let revived;
    let how = "none";
    const attempts = [
      ["waived", () => waive(holder.deserialize(globalThis, true))],
      ["globalThis", () => holder.deserialize(globalThis, true)],
      ["this", () => holder.deserialize(this, true)],
      ["empty", () => holder.deserialize({}, true)],
    ];
    for (const [label, fn] of attempts) {
      let value;
      try {
        value = fn();
      } catch (e) {
        continue;
      }
      if (nonEmpty(value)) {
        revived = value;
        how = label;
        break;
      }
      if (revived === undefined && value !== undefined && value !== null) {
        revived = value;
        how = label + "(empty)";
      }
    }

    // Kotone: plain strings survive reliably, objects have not. Send both.
    let text = null;
    try {
      const target = typeof revived === "object" ? waive(revived) : revived;
      text = typeof target === "string" ? target : JSON.stringify(target);
    } catch (e) {
      text = "stringify failed: " + e;
    }

    let debug;
    try {
      const names = revived && typeof revived === "object"
        ? Object.getOwnPropertyNames(waive(revived)).join(",")
        : "";
      debug =
        `how=${how} dataSize=${size} revivedType=${typeof revived} ` +
        `names=[${names}] text=${String(text).slice(0, 120)}`;
    } catch (e) {
      debug = "debug failed: " + e;
    }

    this.dispatcher.sendRequest("GeckoView:WebExtension:PortMessage", {
      data: revived,
      kotoneText: text,
      kotoneDebug: debug,
    });
  }'''

OLD_MSG = '''  sendMessage(data) {
    return this._sendMessage("GeckoView:WebExtension:Message", {
      data: data.deserialize({}),
    });
  }'''

NEW_MSG = '''  sendMessage(data) {
    // Kotone: same problem as EmbedderPort.onPortMessage above.
    let revived;
    try {
      revived = ChromeUtils.waiveXrays(data.deserialize(globalThis, true));
    } catch (e) {
      try {
        revived = data.deserialize(globalThis, true);
      } catch (e2) {
        revived = null;
      }
    }
    let text = null;
    try {
      text = typeof revived === "string" ? revived : JSON.stringify(revived);
    } catch (e) {
      text = null;
    }
    let size = -1;
    try {
      size = data.dataSize;
    } catch (e) {
      size = -2;
    }
    return this._sendMessage("GeckoView:WebExtension:Message", {
      data: revived,
      kotoneText: text,
      kotoneDebug: `dataSize=${size} type=${typeof revived}`,
    });
  }'''


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: fix-port-message.py <GeckoViewWebExtension.sys.mjs>",
              file=sys.stderr)
        return 1

    path = sys.argv[1]
    try:
        src = io.open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"error: {path} を読めません: {e}", file=sys.stderr)
        return 1

    if MARK in src:
        print("note: deserialize の復元先は既に修正済み")
        return 0

    for old, new, label in (
        (OLD_PORT, NEW_PORT, "EmbedderPort.onPortMessage"),
        (OLD_MSG, NEW_MSG, "GeckoViewConnection.sendMessage"),
    ):
        if old not in src:
            print(f"error: {label} の該当箇所が見つかりません。"
                  f"Gecko のバージョンが変わった可能性があります。", file=sys.stderr)
            print(f"       {path}", file=sys.stderr)
            return 1
        src = src.replace(old, new, 1)

    io.open(path, "w", encoding="utf-8").write(src)
    print("note: deserialize({}) -> deserialize(globalThis) "
          "(onPortMessage, sendMessage)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
