#!/usr/bin/env python3
"""
check_swift_symbols.py

Swift のソースを走査して、次の 4 つを検査する。
scripts/check-symbols.sh から呼ばれる。

  1. 独自型のメンバー呼び出しに定義があるか
  2. project.yml で除外したファイルが他から参照されていないか
  3. pushViewController を使う画面が UINavigationController に載っているか
  4. 同一ファイル内で使っている自分のメンバーに定義があるか

4 番目は rev.52 の失敗を受けて追加した。編集ミスで
PlayerManager の pendingNavigation / canNavigate / navigationDidFinish と、
KotoneHTTPBridge の resolveAudio / setRepeat / toggleShuffle / cycleRepeat を
まとめて消していたが、どの検査も気づけなかった。

---------------------------------------------------------------------------
コメントと文字列の除去について

正規表現でやると壊れる。Swift の複数行文字列

    log.append(.player, \"\"\"
        title = \\(title)
        \"\"\")

の中には裸の " が入るため、単一行文字列用の正規表現と噛み合って本文まで食う。
実測では PlayerManager.swift が 22,215 文字 → 5,201 文字まで削られ、
self. の参照が 1 つも見えなくなっていた。
つまり検査は「常に OK」を返していた。誤って OK を出す検査は無い方がまし。

先頭から 1 文字ずつ読むことで確実にした。
---------------------------------------------------------------------------
"""

import pathlib
import re
import sys


def strip_swift(source: str) -> str:
    """コメントと文字列リテラルを空白に置き換える。"""
    out = []
    i, n = 0, len(source)
    triple = '"' * 3
    while i < n:
        if source.startswith(triple, i):
            j = source.find(triple, i + 3)
            i = n if j < 0 else j + 3
            out.append(' "" ')
            continue
        if source[i] == '"':
            j = i + 1
            while j < n and source[j] != '"' and source[j] != '\n':
                j += 2 if source[j] == '\\' else 1
            i = j + 1
            out.append(' "" ')
            continue
        if source.startswith('//', i):
            j = source.find('\n', i)
            i = n if j < 0 else j
            out.append(' ')
            continue
        if source.startswith('/*', i):
            j = source.find('*/', i + 2)
            i = n if j < 0 else j + 2
            out.append(' ')
            continue
        out.append(source[i])
        i += 1
    return ''.join(out)


OWN_TYPES = ["AddonController", "AddonCatalog", "MeasurementLog",
             "KotoneBridge", "KotoneHTTPBridge", "PlayerManager",
             "NowPlayingCenter", "UserAgentPolicy"]

# 「自分のメンバーを使っているか」を見るファイル。
# 変数経由（self.bridge.foo）で呼ばれるものは型名検査では拾えない。
SELF_CHECK = [
    "Sources/App/PlayerManager.swift",
    "Sources/GeckoView/KotoneHTTPBridge.swift",
    "Sources/GeckoView/KotoneBridge.swift",
    "Sources/App/NowPlayingCenter.swift",
    "Sources/App/AddonController.swift",
]

# self.bridge が指す型
BRIDGE_FILE = "Sources/GeckoView/KotoneHTTPBridge.swift"

# self. を付けずに参照される重要なプロパティ。
#
# rev.52 は編集ミスで PlayerManager の遷移管理を丸ごと消したが、
# これらは `pendingNavigation == url` のように self. 抜きで使われるため、
# self. だけを見る検査では拾えなかった。
# 消えたら困るものを名指しで見る。
TRACKED_PROPERTIES = {
    "Sources/App/PlayerManager.swift": [
        "pendingNavigation", "navigationStartedAt", "canNavigate",
        "tickTimer", "lastPositionUpdate",
    ],
    "Sources/GeckoView/KotoneHTTPBridge.swift": [
        "outbox", "pending", "lastPollAt", "portDispatcher",
    ],
}


def main() -> int:
    files = sorted(pathlib.Path("Sources").rglob("*.swift"))
    if not files:
        print("Sources/*.swift が見つかりません")
        return 0

    bodies = {p: strip_swift(p.read_text(encoding="utf-8", errors="replace"))
              for p in files}
    everything = "\n".join(bodies.values())
    missing = []

    # --- 1. 独自型のメンバー ------------------------------------------------
    declared_types = {}
    for typ in OWN_TYPES:
        decl = re.compile(
            r"\b(?:final\s+)?(?:public\s+)?"
            r"(?:class|struct|enum|actor|extension)\s+" + re.escape(typ) + r"\b"
        )
        declared_types[typ] = [p for p, b in bodies.items() if decl.search(b)]

    pattern = r"\b(" + "|".join(OWN_TYPES) + r")\.(?:shared\.)?([a-zA-Z_][a-zA-Z0-9_]*)\s*\("
    seen = set()
    for m in re.finditer(pattern, everything):
        typ, member = m.group(1), m.group(2)
        if (typ, member) in seen:
            continue
        seen.add((typ, member))
        paths = declared_types.get(typ) or []
        if not paths:
            continue
        scope = "\n".join(bodies[p] for p in paths)
        found = (re.search(r"\bfunc\s+" + re.escape(member) + r"\s*[(<]", scope)
                 or re.search(r"\b(?:let|var)\s+" + re.escape(member) + r"\b", scope))
        print(f"  {'OK  ' if found else 'MISS'} {typ}.{member}")
        if not found:
            print(f"::error::{typ}.{member} の定義が見つかりません")
            missing.append(f"{typ}.{member}")

    # --- 2. 除外ファイルへの参照 -------------------------------------------
    try:
        import yaml
        spec = yaml.safe_load(open("project.yml", encoding="utf-8"))
        excluded = []
        for target in spec.get("targets", {}).values():
            for entry in target.get("sources", []) or []:
                if isinstance(entry, dict):
                    for pat in entry.get("excludes", []) or []:
                        if pat.endswith(".swift") and "*" not in pat:
                            excluded.append(pathlib.Path(pat).name)
        for name in sorted(set(excluded)):
            typename = name[:-len(".swift")]
            users = [p for p, b in bodies.items()
                     if p.name != name
                     and re.search(r"\b" + re.escape(typename) + r"\s*\(", b)]
            print(f"  {'MISS' if users else 'OK  '} {typename}  (ビルド対象外)")
            if users:
                for p in users:
                    print(f"::error::{typename} はビルド対象外ですが {p} が参照しています")
                missing.append(typename)
    except ImportError:
        print("  (PyYAML が無いため除外ファイルの検査をスキップ)")

    # --- 3. ナビゲーション --------------------------------------------------
    nav_users = [p for p, b in bodies.items()
                 if re.search(r"navigationController\?\.(push|pop)ViewController", b)]
    if nav_users:
        wrapped = re.search(r"UINavigationController\(rootViewController:", everything)
        for p in nav_users:
            print(f"  {'OK  ' if wrapped else 'MISS'} {p.stem}  (navigationController を使用)")
            if not wrapped:
                print(f"::error::{p.stem} が pushViewController を使っていますが、"
                      f"UINavigationController に載せている箇所がありません")
                missing.append(p.stem)

    # --- 4. 同一ファイル内の自メンバー -------------------------------------
    bridge_path = pathlib.Path(BRIDGE_FILE)
    bridge_body = bodies.get(bridge_path, "")

    for text in SELF_CHECK:
        path = pathlib.Path(text)
        body = bodies.get(path)
        if body is None:
            continue

        declared = set(re.findall(r"\b(?:func|var|let)\s+([a-z][A-Za-z0-9_]*)", body))
        # 引数名・パターン束縛・for の変数など、宣言とみなすもの
        declared |= set(re.findall(r"([a-z][A-Za-z0-9_]*)\s*:\s*[A-Z\[]", body))
        declared |= set(re.findall(r"\bfor\s+([a-z][A-Za-z0-9_]*)\s+in\b", body))
        declared |= set(re.findall(r"\b(?:if|guard)\s+let\s+([a-z][A-Za-z0-9_]*)", body))
        declared |= set(re.findall(r"\bcase\s+(?:let\s+)?([a-z][A-Za-z0-9_]*)", body))

        used = set(re.findall(r"\bself\.([a-z][A-Za-z0-9_]*)", body))
        via_bridge = set(re.findall(r"\bself\.bridge\.([a-z][A-Za-z0-9_]*)\s*\(", body))

        # self. を付けない参照も見る。
        # rev.52 で消えた pendingNavigation はこの形で使われており、
        # self. だけを見ていた検査では拾えなかった。
        #
        # 対象は「そのファイルが宣言している private なプロパティ」に限る。
        # 局所変数や標準ライブラリまで見ると誤検出だらけになるため。
        own_properties = set(re.findall(
            r"\bprivate\s+(?:static\s+)?(?:var|let)\s+([a-z][A-Za-z0-9_]*)", body
        ))
        # 宣言が消えても使用箇所は残る。使われているのに宣言が無いものを探す。
        for name in TRACKED_PROPERTIES.get(str(path), []):
            if re.search(r"\b" + re.escape(name) + r"\b", body) and name not in own_properties:
                used.add(name)

        gone = []
        for name in sorted(used - declared):
            if name in via_bridge:
                continue
            gone.append(name)
        for name in sorted(via_bridge):
            if not re.search(r"\bfunc\s+" + re.escape(name) + r"\b", bridge_body):
                gone.append(f"bridge.{name}")

        if gone:
            for name in gone:
                print(f"  MISS {path.name}: {name}")
                print(f"::error::{path.name} が {name} を使っていますが定義がありません")
                missing.append(f"{path.name}:{name}")
        else:
            print(f"  OK   {path.name}  (自メンバーの参照は解決済み)")

    # --- 5. 型名の重複はやめた ---------------------------------------------
    #
    # 入れ子の型を区別できないため、誤検出しかしなかった。
    #   Coordinator … CookieLoginView と SafariView がそれぞれ内側に持つ
    #   Keys        … EqualizerSettings と TogetherManager の内側
    #   Kind / Tab  … 同様
    # いずれも正当な定義。Swift の名前空間を正しく追うにはパーサが要る。
    # 誤って error を出す検査は無い方がまし。

    print()
    if missing:
        print(f"未解決: {len(missing)} 件")
        return 1
    print("未定義の参照なし")
    return 0


if __name__ == "__main__":
    sys.exit(main())
