#!/bin/bash
# =============================================================================
# check-braces.sh — Swift ファイルの波括弧の収支を検査する
#
# rev.36 は Views の行を単体で削除した結果、対応する閉じ括弧が浮いて
#   error: extraneous '}' at top level
# でビルドが落ちた。行単位の機械的な編集では起こりやすい。
#
# Swift の構文解析はしない。文字列リテラルとコメントを除いたうえで
# { } を数え、収支が 0 でないファイルを報告するだけ。
# それでも「削除で片方だけ消えた」類は確実に捕まえられる。
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

python3 - <<'PY'
import pathlib, sys, re

bad = []
for path in sorted(pathlib.Path("Sources").rglob("*.swift")):
    text = path.read_text(encoding="utf-8", errors="replace")

    # 文字列リテラル・コメントを潰してから数える
    text = re.sub(r'"""(?:.|\n)*?"""', '""', text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r'//[^\n]*', '', text)
    text = re.sub(r'/\*(?:.|\n)*?\*/', '', text)

    depth = 0
    negative_at = None
    for i, line in enumerate(text.split("\n"), 1):
        depth += line.count("{") - line.count("}")
        if depth < 0 and negative_at is None:
            negative_at = i

    if depth != 0 or negative_at is not None:
        bad.append((path, depth, negative_at))

for path, depth, at in bad:
    if at is not None:
        print(f"  NG   {path}  行 {at} で閉じ括弧が過剰（最終収支 {depth:+d}）")
    else:
        print(f"  NG   {path}  収支 {depth:+d}")

if bad:
    print()
    for path, _, _ in bad:
        print(f"::error file={path}::波括弧の対応が取れていません")
    sys.exit(1)

print("波括弧の対応: 問題なし")
PY
