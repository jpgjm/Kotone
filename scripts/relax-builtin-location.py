#!/usr/bin/env python3
"""
relax-builtin-location.py

Gecko の GeckoViewWebExtension.sys.mjs にある validateBuiltInLocation を緩める。
scripts/AddGecko.sh からビルド時に呼ばれる。

背景
----
このビルドは MOZ_REQUIRE_SIGNING=true でコンパイルされている
(modules/AppConstants.sys.mjs:115)。AddonSettings は pref を一切見ずに
REQUIRE_SIGNING を定数化するため、未署名の .xpi は必ず
installError = -5 (ERROR_SIGNEDSTATE_REQUIRED) になる。

AddonManager.installBuiltinAddon() は署名検査を通らないので、自作アドオンは
そちらで入れる。ところが Gecko 側の入口が 2 つの条件を課している。

    if (uri.scheme !== "resource" || uri.host !== "android") { ... }
    if (uri.fileName !== "") { ... }

1 つ目: resource://android は Android の APK 用で、この iOS ビルドには
        そもそも登録されていない。
2 つ目: uri.fileName は nsIURL 由来。この iOS ビルドの resource:// URI は
        nsIURL として公開されていないらしく undefined を返す。
        undefined !== "" が真になるため、

            resource://android/            (パスは "/" だけ)
            resource://android/kotone-bridge/
            resource://android/bridge/

        のいずれも「folders URIs must end with a "/"」で弾かれた。
        末尾スラッシュの問題ではない。

対処
----
Gecko のリソースは展開状態（omni.ja に固められていない）で、起動キャッシュを
落とす .purgecaches も置かれている。したがって .mjs を書き換えれば反映される。

  * scheme は resource:// に加えて file:// を許可する
    （アプリバンドル内のフォルダを直接指せるようにする）
  * host の "android" 縛りを外す
  * fileName の判定は文字列として取れたときだけ行う

冪等。既に当たっていれば何もしない。

改変対象は Mozilla のコード（MPL-2.0）。THIRD_PARTY_NOTICES.md に記載する。
"""

import io
import sys

MARK = "/* kotone: relaxed */"

OLD_SCHEME = '''    if (uri.scheme !== "resource" || uri.host !== "android") {
      aCallback.onError(`Only resource://android/... URIs are allowed.`);
      return null;
    }'''

NEW_SCHEME = '''    /* kotone: relaxed */
    // Kotone: allow file:// as well. resource://android is an Android/APK
    // concept and is not registered on this iOS build, so we point at a
    // folder inside the app bundle instead.
    if (uri.scheme !== "resource" && uri.scheme !== "file") {
      aCallback.onError(`Only resource:// or file:// URIs are allowed.`);
      return null;
    }'''

OLD_FILENAME = '''    if (uri.fileName !== "") {
      aCallback.onError(
        `This URI does not point to a folder. Note: folders URIs must end with a "/".`
      );
      return null;
    }'''

NEW_FILENAME = '''    // Kotone: uri.fileName comes from nsIURL. On this iOS build the
    // resource:// URI is not exposed as nsIURL, so fileName is undefined and
    // `undefined !== ""` wrongly rejects every folder URI. Only check when we
    // actually got a string.
    if (typeof uri.fileName === "string" && uri.fileName !== "") {
      aCallback.onError(
        `This URI does not point to a folder. Note: folders URIs must end with a "/".`
      );
      return null;
    }'''


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: relax-builtin-location.py <GeckoViewWebExtension.sys.mjs>",
              file=sys.stderr)
        return 1

    path = sys.argv[1]
    try:
        src = io.open(path, encoding="utf-8").read()
    except OSError as e:
        print(f"error: {path} を読めません: {e}", file=sys.stderr)
        return 1

    if MARK in src:
        print("note: validateBuiltInLocation は既に緩和済み")
        return 0

    for old, new, label in (
        (OLD_SCHEME, NEW_SCHEME, "scheme/host check"),
        (OLD_FILENAME, NEW_FILENAME, "fileName check"),
    ):
        if old not in src:
            print(f"error: {label} の該当箇所が見つかりません。"
                  f"Gecko のバージョンが変わった可能性があります。", file=sys.stderr)
            print(f"       {path}", file=sys.stderr)
            return 1
        src = src.replace(old, new, 1)

    io.open(path, "w", encoding="utf-8").write(src)
    print("note: validateBuiltInLocation relaxed "
          "(resource:// + file://, fileName 判定を緩和)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
