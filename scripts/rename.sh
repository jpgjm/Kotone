#!/bin/bash
# =============================================================================
# rename.sh — アプリ名と Bundle ID をまとめて変更する
#
#   ./scripts/rename.sh <NewName> <com.new.bundleid>
#
# 例:
#   ./scripts/rename.sh Kotone com.hayato.kotone
#
# !!! 注意 !!!
#   "Reynard Helper" という文字列は絶対に置換しない。
#   XUL がこのファイル名で PlugIns/ を検索するため。
#   このスクリプトはその文字列を保護している。
# =============================================================================
set -euo pipefail

if [ $# -ne 2 ]; then
	echo "usage: $0 <NewName> <com.new.bundleid>" >&2
	exit 1
fi

NEW_NAME="$1"
NEW_ID="$2"
OLD_NAME="$(grep -m1 '^name:' project.yml | awk '{print $2}')"
OLD_ID="$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER: ' project.yml | awk '{print $2}')"

if [ "$OLD_NAME" = "$NEW_NAME" ]; then
	echo "既に $NEW_NAME です"
	exit 0
fi

echo "  name:      $OLD_NAME -> $NEW_NAME"
echo "  bundle id: $OLD_ID -> $NEW_ID"

# "Reynard Helper" を含む行は触らない
FILES=$(grep -rl "$OLD_NAME" \
	--include='*.yml' --include='*.sh' --include='*.md' \
	--include='*.swift' --include='*.h' --include='*.plist' \
	--include='*.json' . 2>/dev/null | grep -v '^./engine/dist' || true)

for f in $FILES; do
	# Bundle ID を先に置換（NEW_NAME に OLD_ID が含まれる事故を防ぐ）
	sed -i.bak "s|${OLD_ID}|${NEW_ID}|g" "$f"
	# アプリ名。"Reynard Helper" は OLD_NAME を含まないので安全だが、
	# 念のため単語境界で置換する。
	sed -i.bak "s|\\b${OLD_NAME}\\b|${NEW_NAME}|g" "$f"
	rm -f "$f.bak"
done

# ブリッジングヘッダのファイル名
if [ -f "Sources/Bridging/${OLD_NAME}-Bridging-Header.h" ]; then
	mv "Sources/Bridging/${OLD_NAME}-Bridging-Header.h" \
	   "Sources/Bridging/${NEW_NAME}-Bridging-Header.h"
fi

echo
echo "完了。以下が保護されていることを確認してください:"
grep -rn "Reynard Helper" project.yml || echo "  !!! 'Reynard Helper' が project.yml から消えています !!!"
