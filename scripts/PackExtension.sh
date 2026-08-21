#!/bin/sh
# =============================================================================
# PackExtension.sh — Extension/ を .xpi にまとめてアプリに同梱する
#
# .xpi の実体は zip。manifest.json が ZIP のルート直下に来る必要があるので、
# ディレクトリの「中」で zip する。
#
# 生成物: <App>.app/kotone-bridge.xpi
#
# インストールは起動時に自動では行わない。
# アドオン画面（🧩）の行をタップしたときに、tmp へコピーしてから
# file:// URL として AddonRuntime.install(url:) に渡す。
# バンドル内は読み取り専用なので、直接渡さず必ず staging する。
# =============================================================================
set -eu

SRC="${SRCROOT}/Extension"
OUT="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/kotone-bridge.xpi"

if [ ! -f "${SRC}/manifest.json" ]; then
	echo "error: ${SRC}/manifest.json がありません" >&2
	exit 1
fi

mkdir -p "$(dirname "${OUT}")"
rm -f "${OUT}"

# -X で拡張属性を落とす。macOS の ._ ファイルが混ざると Gecko が弾く。
( cd "${SRC}" && zip -qrX "${OUT}" . -x '.*' -x '__MACOSX/*' -x '*.md' )

echo "note: packed $(cd "${SRC}" && ls | tr '\n' ' ')-> kotone-bridge.xpi"
