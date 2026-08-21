#!/bin/bash
# =============================================================================
# import-reynard.sh
#
# Reynard の Swift/ObjC ラッパ層を Sources/ に展開する。
#
# Gecko の「バイナリ」は配布 IPA から取れるが (fetch-engine.sh)、
# Swift ラッパ層はソースからビルドする必要がある。
# 配布 IPA の GeckoView.framework には Modules/ も .swiftinterface も
# 含まれないため、Swift から import できないため。
#
# 本リポジトリは Reynard のソースをコミットせず、ビルド時に取得する方針。
# 取得元とハッシュは engine/VERSION.txt で固定し、PROVENANCE.txt に記録する。
#
# 使い方:
#   ./scripts/import-reynard.sh
#   ./scripts/import-reynard.sh --keep-src DIR   # 展開した全体を DIR に残す
#                                                # (fetch-headers.sh に渡せば
#                                                #  ダウンロードが 1 回で済む)
#   ./scripts/import-reynard.sh --from DIR       # ローカルの reynard-browser を使う
#   ./scripts/import-reynard.sh --clean          # Sources/ から取り込み分を削除
#
# 環境変数:
#   GITHUB_TOKEN … あれば API レート制限を回避する
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/engine"
SOURCES_DIR="$ROOT_DIR/Sources"

KEEP_SRC=""
FROM_DIR=""
CLEAN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--keep-src) KEEP_SRC="${2:-}"; shift 2 ;;
		--from)     FROM_DIR="${2:-}"; shift 2 ;;
		--clean)    CLEAN=1; shift ;;
		-h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)          echo "error: 不明な引数: $1" >&2; exit 1 ;;
	esac
done

# -----------------------------------------------------------------------------
# 対応表  <Sources/ 側>:<reynard-browser 側>
# docs/PLACEMENT.md と同じ内容。ここを唯一の定義とする。
#
# JIT は既定で取り込まない。libidevice_ffi.a が入手できないため。
# 詳細は docs/PLACEMENT.md の「JIT について」。
# -----------------------------------------------------------------------------
MAPPING="
GeckoView:browser/GeckoView
Helper:browser/Helper
Bridging:browser/Reynard/Bridging
Shared:browser/Reynard/Shared
ThirdParty:browser/Reynard/ThirdParty
"

# Sources/ 側で保護するファイル（本リポジトリ独自のもの。上書きしない）
# Sources/ 側で保護するファイル（本リポジトリ独自のもの。上書きしない）
#   Kotone-Bridging-Header.h … Sources/Bridging/
#   KotoneBridge.swift       … Sources/GeckoView/
#     GeckoEventDispatcherWrapper.addListener が internal なので、
#     GeckoView ターゲットの内側に置く必要がある。
#
# ⚠️ ここに足したら .gitignore の除外 (!) も必ず追加すること。
#    忘れると push されず、CI で
#      error: cannot find 'KotoneBridge' in scope
#    のように分かりにくい形で失敗する（rev.20 の実例）。
PROTECTED="Kotone-Bridging-Header.h KotoneBridge.swift KotoneHTTPBridge.swift"

# --- --clean -----------------------------------------------------------------
if [ "$CLEAN" -eq 1 ]; then
	for entry in $MAPPING; do
		dst="${entry%%:*}"
		d="$SOURCES_DIR/$dst"
		[ -d "$d" ] || continue
		find "$d" -mindepth 1 ! -name '.gitkeep' \
			$(for p in $PROTECTED; do printf '! -name %s ' "$p"; done) \
			-delete 2>/dev/null
		echo "cleaned Sources/$dst"
	done
	rm -f "$SOURCES_DIR/IMPORT_PROVENANCE.txt"
	exit 0
fi

read_var() {
	awk -F= -v k="$1" '$0 ~ "^" k "=" { sub("^" k "=", ""); print; exit }' \
		"$ENGINE_DIR/VERSION.txt" 2>/dev/null || true
}

REYNARD_REPO="$(read_var REYNARD_REPO)"
REYNARD_TAG="$(read_var REYNARD_TAG)"
EXPECTED_SHA="$(read_var REYNARD_SRC_SHA256)"

if [ -z "$REYNARD_REPO" ] || [ -z "$REYNARD_TAG" ]; then
	echo "error: engine/VERSION.txt に REYNARD_REPO / REYNARD_TAG がありません" >&2
	exit 1
fi

WORK_DIR="$(mktemp -d)" || { echo "error: mktemp 失敗" >&2; exit 1; }
cleanup() { [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# --- ソースの入手 -------------------------------------------------------------
ACTUAL_SHA=""
if [ -n "$FROM_DIR" ]; then
	SRC="$FROM_DIR"
	echo "==> using local source: $SRC"
else
	URL="https://github.com/${REYNARD_REPO}/archive/refs/tags/${REYNARD_TAG}.tar.gz"
	echo "==> downloading ${REYNARD_REPO}@${REYNARD_TAG}"
	if ! curl -fSL --retry 3 -o "$WORK_DIR/src.tar.gz" "$URL"; then
		echo "error: ソースを取得できませんでした: $URL" >&2
		echo "       タグが削除された可能性があります。" >&2
		echo "       過去のビルドの source-snapshot 成果物から復元できます。" >&2
		exit 1
	fi

	if command -v shasum > /dev/null 2>&1; then
		ACTUAL_SHA="$(shasum -a 256 "$WORK_DIR/src.tar.gz" | awk '{print $1}')"
	elif command -v sha256sum > /dev/null 2>&1; then
		ACTUAL_SHA="$(sha256sum "$WORK_DIR/src.tar.gz" | awk '{print $1}')"
	fi

	if [ -n "$EXPECTED_SHA" ] && [ -n "$ACTUAL_SHA" ]; then
		if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
			echo "error: tarball の SHA256 が engine/VERSION.txt と一致しません" >&2
			echo "       expected: $EXPECTED_SHA" >&2
			echo "       actual  : $ACTUAL_SHA" >&2
			echo "       タグが付け替えられた可能性があります。" >&2
			exit 1
		fi
		echo "==> sha256 verified"
	elif [ -n "$ACTUAL_SHA" ]; then
		echo "==> sha256: $ACTUAL_SHA"
		echo "    engine/VERSION.txt の REYNARD_SRC_SHA256 に設定すると"
		echo "    以降のビルドで検証されます。"
	fi

	SRC="$WORK_DIR/reynard"
	mkdir -p "$SRC"
	tar -xzf "$WORK_DIR/src.tar.gz" -C "$SRC" --strip-components=1 || {
		echo "error: 展開に失敗しました" >&2; exit 1; }
fi

# --- 配置 ---------------------------------------------------------------------
echo "==> importing"
TOTAL=0
for entry in $MAPPING; do
	dst="${entry%%:*}"
	rel="${entry#*:}"
	srcdir="$SRC/$rel"

	if [ ! -d "$srcdir" ]; then
		echo "error: $rel が見つかりません（Reynard の構成が変わった可能性）" >&2
		exit 1
	fi

	dstdir="$SOURCES_DIR/$dst"
	mkdir -p "$dstdir"

	# 既存の取り込み分だけ消す（.gitkeep と本リポジトリ独自ファイルは残す）
	find "$dstdir" -mindepth 1 ! -name '.gitkeep' \
		$(for p in $PROTECTED; do printf '! -name %s ' "$p"; done) \
		-delete 2>/dev/null

	cp -R "$srcdir/." "$dstdir/" || { echo "error: コピー失敗: $rel" >&2; exit 1; }

	# 保護ファイルと同名のものが来ていたら Reynard 側を捨てる
	for p in $PROTECTED; do
		[ -f "$srcdir/$p" ] && echo "    (skip $dst/$p — 本リポジトリのものを優先)"
	done

	n="$(find "$dstdir" -type f ! -name '.gitkeep' | wc -l | tr -d ' ')"
	TOTAL=$((TOTAL + n))
	printf '  %-12s <- %-28s %s ファイル\n' "$dst" "$rel" "$n"
done

# --- 使わないファイルの明示 ---------------------------------------------------
# どちらも project.yml の excludes でビルド対象から外してあるが、
# 誤解を避けるため置いたままにせず消す。
for f in \
	"$SOURCES_DIR/GeckoView/View/GeckoView.h" \
	"$SOURCES_DIR/Bridging/Reynard-Bridging-Header.h" \
	"$SOURCES_DIR/GeckoView/Info.plist" \
	"$SOURCES_DIR/Helper/Info.plist"; do
	if [ -f "$f" ]; then
		rm -f "$f"
		echo "  removed  ${f#"$ROOT_DIR/"}  (未使用)"
	fi
done

# Reynard 用の entitlements。無料 Personal Team では使えない private 権限を
# 含み、そのまま置くと appex にリソースとして混入する。
if [ -d "$SOURCES_DIR/Helper/Entitlements" ]; then
	rm -rf "$SOURCES_DIR/Helper/Entitlements"
	echo "  removed  Sources/Helper/Entitlements/  (Reynard 用・未使用)"
fi

# --- 記録 ---------------------------------------------------------------------
cat > "$SOURCES_DIR/IMPORT_PROVENANCE.txt" <<EOF
source-repo:   https://github.com/${REYNARD_REPO}
source-tag:    ${REYNARD_TAG}
sha256:        ${ACTUAL_SHA:-(local source)}
imported:      $(for e in $MAPPING; do printf '%s ' "${e%%:*}"; done)
excluded:      JIT (libidevice_ffi.a が入手できないため)
license:       GPL-3.0
generated-at:  $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# --- --keep-src ---------------------------------------------------------------
if [ -n "$KEEP_SRC" ] && [ -z "$FROM_DIR" ]; then
	rm -rf "$KEEP_SRC"
	mkdir -p "$(dirname "$KEEP_SRC")"
	mv "$SRC" "$KEEP_SRC" || { echo "warning: --keep-src に失敗しました" >&2; }
	echo "==> source kept at $KEEP_SRC"
	echo "    ./scripts/fetch-headers.sh \"$KEEP_SRC\" でダウンロードを再利用できます"
fi

echo "==> done: $TOTAL ファイル"
echo
cat "$SOURCES_DIR/IMPORT_PROVENANCE.txt"
