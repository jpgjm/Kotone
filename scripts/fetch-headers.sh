#!/bin/bash
# =============================================================================
# fetch-headers.sh
#
# Gecko の EXPORTS.GeckoView ヘッダを再構成して
# engine/dist/include/GeckoView/ に配置する。
#
# 配布 IPA には .h が 1 つも含まれないため、ここだけはソースから作る。
# ただし firefox リポジトリの clone は不要で、必要なのは 2 ファイルだけ。
#
#   1. mozilla-firefox/firefox の raw URL から 2 ファイル取得
#        toolkit/xre/IOSBootstrap.h
#        widget/uikit/GeckoViewSwiftSupport.h
#   2. reynard-browser の patches を 3 つ適用
#        toolkit/xre/IOSBootstrap.h.patch              (差分)
#        widget/uikit/GeckoViewSwiftSupport.h.patch    (差分)
#        widget/uikit/GeckoViewRuntimeSupport.h.patch  (新規作成 = 全文入り)
#   3. dist/include/GeckoView/ へ配置（moz.build の EXPORTS.GeckoView と同じ配置）
#
# 依存の閉包は上記 3 ファイル + システムヘッダのみ。
# mozilla/Types.h 等は #ifdef MOZILLA_CLIENT の内側なのでアプリ側では不要。
#
# 使い方:
#   ./scripts/fetch-headers.sh                    # patches をネットから取得
#   ./scripts/fetch-headers.sh ~/src/reynard      # ローカルの reynard-browser を使う
#
# 環境変数:
#   GITHUB_TOKEN … あれば API レート制限を回避する
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/engine"
INCLUDE_DIR="$ENGINE_DIR/dist/include/GeckoView"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# set -e + pipefail 下では grep の非マッチ(1) が代入文を殺すため awk + || true。
read_var() {
	awk -F= -v k="$1" '$0 ~ "^" k "=" { sub("^" k "=", ""); print; exit }' \
		"$ENGINE_DIR/VERSION.txt" 2>/dev/null || true
}

require_var() {
	local v
	v="$(read_var "$1")" || v=""
	if [ -z "$v" ]; then
		echo "error: engine/VERSION.txt に $1 がありません" >&2
		exit 1
	fi
	printf '%s' "$v"
}

REYNARD_REPO="$(require_var REYNARD_REPO)"
REYNARD_TAG="$(require_var REYNARD_TAG)"
FIREFOX_REPO="$(require_var FIREFOX_REPO)"
FIREFOX_TAG="$(require_var FIREFOX_TAG)"

# --- 1. reynard-browser の patches を用意 -------------------------------------
REYNARD_SRC="${1:-}"
if [ -n "$REYNARD_SRC" ]; then
	PATCH_DIR="$REYNARD_SRC/patches"
	echo "==> using local patches: $PATCH_DIR"
else
	echo "==> downloading reynard-browser@${REYNARD_TAG}"
	curl -fSL --retry 3 \
		-o "$WORK_DIR/reynard.tar.gz" \
		"https://github.com/${REYNARD_REPO}/archive/refs/tags/${REYNARD_TAG}.tar.gz"
	mkdir -p "$WORK_DIR/reynard"
	# patches/ 以下だけ展開する
	tar -xzf "$WORK_DIR/reynard.tar.gz" -C "$WORK_DIR/reynard" --strip-components=1 \
		--wildcards '*/patches/*' 2>/dev/null \
		|| tar -xzf "$WORK_DIR/reynard.tar.gz" -C "$WORK_DIR/reynard" --strip-components=1
	PATCH_DIR="$WORK_DIR/reynard/patches"
fi

for p in \
	"toolkit/xre/IOSBootstrap.h.patch" \
	"widget/uikit/GeckoViewSwiftSupport.h.patch" \
	"widget/uikit/GeckoViewRuntimeSupport.h.patch"; do
	if [ ! -f "$PATCH_DIR/$p" ]; then
		echo "error: patch がありません: $PATCH_DIR/$p" >&2
		exit 1
	fi
done

# --- 2. upstream の 2 ファイルを取得 -------------------------------------------
SRC="$WORK_DIR/src"
mkdir -p "$SRC/toolkit/xre" "$SRC/widget/uikit"
RAW="https://raw.githubusercontent.com/${FIREFOX_REPO}/${FIREFOX_TAG}"

for f in toolkit/xre/IOSBootstrap.h widget/uikit/GeckoViewSwiftSupport.h; do
	echo "==> fetching ${FIREFOX_TAG}:${f}"
	curl -fSL --retry 3 -o "$SRC/$f" "$RAW/$f"
done

# --- 3. patch 適用 -------------------------------------------------------------
cd "$SRC"
apply() {
	echo "==> patching $1"
	# --fuzz=0 で文脈のずれを許さない。ずれたらバージョン不整合なので止める。
	patch -p1 --fuzz=0 --no-backup-if-mismatch < "$PATCH_DIR/$1"
}
apply "widget/uikit/GeckoViewRuntimeSupport.h.patch"   # 新規作成（全文入り）
apply "toolkit/xre/IOSBootstrap.h.patch"
apply "widget/uikit/GeckoViewSwiftSupport.h.patch"

# --- 4. EXPORTS.GeckoView と同じ配置にする -------------------------------------
# moz.build:
#   toolkit/xre       EXPORTS.GeckoView += ["IOSBootstrap.h"]
#   widget/uikit      EXPORTS.GeckoView += ["GeckoViewRuntimeSupport.h",
#                                           "GeckoViewSwiftSupport.h"]
rm -rf "$INCLUDE_DIR"
mkdir -p "$INCLUDE_DIR"
cp "$SRC/toolkit/xre/IOSBootstrap.h"                 "$INCLUDE_DIR/"
cp "$SRC/widget/uikit/GeckoViewSwiftSupport.h"       "$INCLUDE_DIR/"
cp "$SRC/widget/uikit/GeckoViewRuntimeSupport.h"     "$INCLUDE_DIR/"

# --- 5. mozilla-config.h の最小版を生成 ---------------------------------------
#
# Sources/GeckoView/Runtime/GeckoRuntimeBridge.mm が
#
#     #import "mozilla-config.h"
#     + (NSString *)version { return @MOZILLA_VERSION; }
#
# としている。本物の mozilla-config.h は Gecko のビルドが
# obj-dir/dist/include/ に生成する巨大な設定ヘッダで、配布 IPA には含まれない。
#
# 取り込んだソースの中で mozilla-config.h を参照しているのはこの 1 ファイルだけで、
# 必要なマクロも MOZILLA_VERSION ひとつだけなので、最小版を生成して代替する。
# 値は engine/VERSION.txt の GECKO_MILESTONE（fetch-engine.sh が
# platform.ini と照合済み）から取る。
#
# 注意: Gecko 本体をビルドするようになったら、この生成をやめて
#       本物の dist/include/mozilla-config.h を使うこと。
MILESTONE="$(read_var GECKO_MILESTONE)"
if [ -z "$MILESTONE" ]; then
	echo "error: engine/VERSION.txt に GECKO_MILESTONE がありません" >&2
	exit 1
fi

cat > "$ENGINE_DIR/dist/include/mozilla-config.h" <<EOF
/* 自動生成 — scripts/fetch-headers.sh
 *
 * 本物の mozilla-config.h は Gecko のビルド成果物であり、
 * Reynard の配布 IPA には含まれない。
 * 取り込んだソースが必要とするマクロだけを定義した最小版。
 *
 * 参照元: Sources/GeckoView/Runtime/GeckoRuntimeBridge.mm
 */

#ifndef mozilla_config_h_minimal
#define mozilla_config_h_minimal

/* GeckoRuntimeBridge.mm が @MOZILLA_VERSION として NSString 化する */
#ifndef MOZILLA_VERSION
#  define MOZILLA_VERSION "${MILESTONE}"
#endif

#ifndef MOZILLA_VERSION_U
#  define MOZILLA_VERSION_U ${MILESTONE}
#endif

#endif /* mozilla_config_h_minimal */
EOF
echo "==> generated mozilla-config.h (MOZILLA_VERSION=\"${MILESTONE}\")"

# --- 6. 検証 -------------------------------------------------------------------
for h in IOSBootstrap.h GeckoViewSwiftSupport.h GeckoViewRuntimeSupport.h ../mozilla-config.h; do
	[ -s "$INCLUDE_DIR/$h" ] || { echo "error: $h が空です" >&2; exit 1; }
done

# GeckoViewRuntimeSupport.h は純 C なのでその場でコンパイル検証できる
if command -v cc > /dev/null 2>&1; then
	cat > "$WORK_DIR/check.c" <<'EOF'
#include <GeckoView/GeckoViewRuntimeSupport.h>
int main(void) {
  JITRuntimeInfo a = {0}; ChildJITStatus b = {0}; DeviceOSVersion c = {0};
  (void)a; (void)b; (void)c; return 0;
}
EOF
	if cc -I"$ENGINE_DIR/dist/include" -fsyntax-only "$WORK_DIR/check.c" 2>/dev/null; then
		echo "==> syntax check: OK"
	else
		echo "warning: GeckoViewRuntimeSupport.h の構文検査に失敗しました" >&2
	fi
fi

cat > "$ENGINE_DIR/dist/include/PROVENANCE.txt" <<EOF
firefox-repo:  https://github.com/${FIREFOX_REPO}
firefox-tag:   ${FIREFOX_TAG}
patched-with:  https://github.com/${REYNARD_REPO} @ ${REYNARD_TAG}
files:
  GeckoView/IOSBootstrap.h              (upstream + patch)
  GeckoView/GeckoViewSwiftSupport.h     (upstream + patch)
  GeckoView/GeckoViewRuntimeSupport.h   (patch 由来の新規ファイル)
  mozilla-config.h                      (最小版を自動生成 / MOZILLA_VERSION のみ)
license:       MPL-2.0
generated-at:  $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "==> done"
ls -l "$INCLUDE_DIR"
echo
cat "$ENGINE_DIR/dist/include/PROVENANCE.txt"
