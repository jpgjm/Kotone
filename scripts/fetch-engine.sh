#!/bin/bash
# =============================================================================
# fetch-engine.sh
#
# Reynard の配布 IPA から Gecko エンジン一式を取り出し、
# Reynard 本家のビルドが生成する $GECKO_DIST/bin と同じ形に再構成する。
#
#   IPA 内のレイアウト                         →  engine/dist/bin/
#   ------------------------------------------    ------------------
#   Payload/Reynard.app/Frameworks/XUL         →  XUL
#   Payload/Reynard.app/Frameworks/*.dylib     →  *.dylib
#   .../GeckoView.framework/Frameworks/**      →  ** (chrome, modules, ...)
#
# 使い方:
#   ./scripts/fetch-engine.sh                        # engine/VERSION.txt に従って取得
#   ./scripts/fetch-engine.sh path/to/Reynard.ipa    # ローカルの IPA を使う
#
# 環境変数:
#   GITHUB_TOKEN  … あれば API レート制限を回避する
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/engine"
DIST_DIR="$ENGINE_DIR/dist"
BIN_DIR="$DIST_DIR/bin"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- VERSION.txt の読み込み ---------------------------------------------------
# 形式: KEY=VALUE (# 始まりはコメント)
#
# 注意: set -e + pipefail 下では「代入文へのコマンド置換」が地雷になる。
#   var="$(cmd)"  は cmd の終了コードを代入文が継承するため、
#   grep が非マッチ(1) や find|head が SIGPIPE(141) を返すとスクリプトが即死する。
#   read_var は awk 一本にして || true を付け、失敗しても空文字を返す。
if [ ! -f "$ENGINE_DIR/VERSION.txt" ]; then
	echo "error: engine/VERSION.txt がありません" >&2
	exit 1
fi

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
REYNARD_ASSET="$(require_var REYNARD_ASSET)"
EXPECTED_BUILDID="$(read_var GECKO_BUILDID)"
EXPECTED_MILESTONE="$(read_var GECKO_MILESTONE)"

# --- IPA の入手 ---------------------------------------------------------------
IPA_PATH="${1:-}"
if [ -z "$IPA_PATH" ]; then
	URL="https://github.com/${REYNARD_REPO}/releases/download/${REYNARD_TAG}/${REYNARD_ASSET}"
	echo "==> downloading ${URL}"
	IPA_PATH="$WORK_DIR/Reynard.ipa"
	AUTH=()
	[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	curl -fSL --retry 3 "${AUTH[@]}" -o "$IPA_PATH" "$URL"
else
	echo "==> using local IPA: $IPA_PATH"
fi

echo "==> unpacking"
unzip -q -o "$IPA_PATH" -d "$WORK_DIR/ipa"

# find | head は pipefail 下で SIGPIPE(141) を拾いうるのでグロブで探す
APP_DIR=""
for d in "$WORK_DIR/ipa/Payload"/*.app; do
	if [ -d "$d" ]; then APP_DIR="$d"; break; fi
done
if [ -z "$APP_DIR" ]; then
	echo "error: Payload/*.app が見つかりません" >&2
	exit 1
fi

FW="$APP_DIR/Frameworks"
GV_RES="$FW/GeckoView.framework/Frameworks"
for p in "$FW/XUL" "$GV_RES/application.ini" "$GV_RES/greprefs.js" "$GV_RES/chrome.manifest"; do
	if [ ! -e "$p" ]; then
		echo "error: 期待した構成ではありません (missing: ${p#"$APP_DIR/"})" >&2
		exit 1
	fi
done

# --- バージョン検証 -----------------------------------------------------------
# sed | head も同様。awk の exit で 1 行だけ取る。
ACTUAL_BUILDID="$(awk -F= '/^BuildID=/{print $2; exit}' "$GV_RES/platform.ini")" || ACTUAL_BUILDID=""
ACTUAL_MILESTONE="$(awk -F= '/^Milestone=/{print $2; exit}' "$GV_RES/platform.ini")" || ACTUAL_MILESTONE=""
if [ -z "$ACTUAL_BUILDID" ] || [ -z "$ACTUAL_MILESTONE" ]; then
	echo "error: platform.ini からバージョンを読めませんでした" >&2
	exit 1
fi
echo "==> Gecko ${ACTUAL_MILESTONE} (BuildID ${ACTUAL_BUILDID})"

if [ -n "$EXPECTED_BUILDID" ] && [ "$ACTUAL_BUILDID" != "$EXPECTED_BUILDID" ]; then
	echo "error: BuildID 不一致 (expected ${EXPECTED_BUILDID}, got ${ACTUAL_BUILDID})" >&2
	echo "       engine/VERSION.txt を更新するか、正しいリリースを指定してください。" >&2
	exit 1
fi
if [ -n "$EXPECTED_MILESTONE" ] && [ "$ACTUAL_MILESTONE" != "$EXPECTED_MILESTONE" ]; then
	echo "error: Milestone 不一致 (expected ${EXPECTED_MILESTONE}, got ${ACTUAL_MILESTONE})" >&2
	exit 1
fi

# --- 再構成 -------------------------------------------------------------------
echo "==> reconstructing \$GECKO_DIST/bin"
rm -rf "$DIST_DIR"
mkdir -p "$BIN_DIR"

# 1) Gecko のリソース一式 (chrome/ modules/ components/ actors/ res/ ...)
#    rsync でなく cp -R。macOS/Linux どちらでも動く。
cp -R "$GV_RES/." "$BIN_DIR/"

# 2) XUL と dylib 群
cp "$FW/XUL" "$BIN_DIR/XUL"
for f in "$FW"/*.dylib; do
	base="$(basename "$f")"
	# Swift ランタイムの後方互換 dylib は Gecko 由来ではないので除外。
	# deployment target 15.0 では Xcode が必要に応じて自前で埋め込む。
	case "$base" in
		libswift_*) echo "    skip $base (Swift runtime)"; continue ;;
	esac
	cp "$f" "$BIN_DIR/$base"
done

# 3) 実行時に不要なビルド生成物を削除（配布サイズ削減）
echo "==> stripping build leftovers"
for junk in xpcshell certutil pk12util nsinstall pingsender \
            gmp-fake gmp-fakeopenh264 \
            .mkdir.done .lldbinit \
            EventArtifactDefinitions.json ScalarArtifactDefinitions.json \
            dependentlibs.list.gtest; do
	rm -rf "${BIN_DIR:?}/$junk"
done

# 音楽アプリでは辞書とハイフネーションは不要（約 5MB）。
# 一般ブラウジングもさせたい場合は KEEP_DICTIONARIES=1 を付けて実行する。
if [ "${KEEP_DICTIONARIES:-0}" != "1" ]; then
	rm -rf "${BIN_DIR:?}/dictionaries" "${BIN_DIR:?}/hyphenation"
fi

# 4) 記録を残す（GPL-3.0 の Corresponding Source 追跡用）
cat > "$DIST_DIR/PROVENANCE.txt" <<EOF
source-repo:    https://github.com/${REYNARD_REPO}
source-tag:     ${REYNARD_TAG}
source-asset:   ${REYNARD_ASSET}
gecko-milestone: ${ACTUAL_MILESTONE}
gecko-buildid:  ${ACTUAL_BUILDID}
extracted-at:   $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

DIST_SIZE="$(du -sh "$DIST_DIR" 2>/dev/null | awk '{print $1; exit}')" || DIST_SIZE="?"
echo "==> done: ${DIST_SIZE} at engine/dist"
echo
cat "$DIST_DIR/PROVENANCE.txt"
