#!/bin/sh
# =============================================================================
# AddGecko.sh  —  Xcode の Run Script Phase から呼ばれる
#
# reynard-browser の browser/Scripts/AddGecko.sh を元に、以下を変更:
#   * ソースがビルド済み Gecko ($GECKO_DIST/bin) であることを前提にした
#   * default-theme のコピーを削除（抽出済みリソースに既に含まれるため）
#   * CODE_SIGNING_ALLOWED=NO のとき codesign を丸ごとスキップ
#     （GitHub Actions で未署名 IPA を作り、SideStore 側で署名するため）
#   * rsync ではなく cp -R を使用（環境差を減らす）
#
# 出力先レイアウトは Reynard の配布 IPA と完全に一致させること。
# XUL はこのレイアウトを前提にリソースを解決する。
#
#   <App>.app/Frameworks/XUL
#   <App>.app/Frameworks/*.dylib
#   <App>.app/Frameworks/GeckoView.framework/Frameworks/**
# =============================================================================
set -eu

GECKO_DIST_BIN="${GECKO_DIST}/bin"
APP_BUNDLE="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
FRAMEWORKS_DIR="${APP_BUNDLE}/Frameworks"
GECKOVIEW_FW="${FRAMEWORKS_DIR}/GeckoView.framework"
GECKOVIEW_FW_FRAMEWORKS="${GECKOVIEW_FW}/Frameworks"

if [ ! -f "${GECKO_DIST_BIN}/XUL" ]; then
	echo "error: ${GECKO_DIST_BIN}/XUL がありません。" >&2
	echo "       先に ./scripts/fetch-engine.sh を実行してください。" >&2
	exit 1
fi

mkdir -p "${FRAMEWORKS_DIR}"
mkdir -p "${GECKOVIEW_FW_FRAMEWORKS}"

echo "note: copying Gecko engine from ${GECKO_DIST_BIN}"

# --- XUL と dylib 群 ---------------------------------------------------------
cp -fL "${GECKO_DIST_BIN}/XUL" "${FRAMEWORKS_DIR}/XUL"
for f in "${GECKO_DIST_BIN}"/*.dylib; do
	[ -f "$f" ] || continue
	cp -fL "$f" "${FRAMEWORKS_DIR}/"
done

# --- 残りのリソース ----------------------------------------------------------
# XUL / *.dylib / テスト類を除外して GeckoView.framework/Frameworks へ
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
cp -RL "${GECKO_DIST_BIN}/." "${STAGING}/"
rm -f "${STAGING}/XUL"
rm -f "${STAGING}"/*.dylib
find "${STAGING}" \( -name 'Test*' -o -name 'test_*' -o -name '*_unittest' \) -prune -exec rm -rf {} + 2>/dev/null || true

rm -rf "${GECKOVIEW_FW_FRAMEWORKS}"
mkdir -p "${GECKOVIEW_FW_FRAMEWORKS}"
cp -R "${STAGING}/." "${GECKOVIEW_FW_FRAMEWORKS}/"

# --- Kotone Bridge を組み込みアドオンとして配置 -------------------------------
#
# このビルドは MOZ_REQUIRE_SIGNING=true でコンパイルされており
# (modules/AppConstants.sys.mjs:115)、AddonSettings は pref を見ずに
# REQUIRE_SIGNING を定数化する。未署名 .xpi は必ず installError=-5 になる。
#
# 一方 AddonManager.installBuiltinAddon() は署名検査を通らない。
# そこで Extension/ を Gecko リソース配下に置き、組み込みとして入れる。
#
# ただし GeckoViewWebExtension.sys.mjs の validateBuiltInLocation が
#     if (uri.scheme !== "resource" || uri.host !== "android") { ... }
#     if (uri.fileName !== "") { ... }
# を要求する。この iOS ビルドでは resource:// の URI が nsIURL として
# 公開されていないらしく uri.fileName が undefined になり、
# undefined !== "" が真になるため
#     resource://android/           (パスは "/" だけ)
#     resource://android/bridge/
# のどちらも「folders URIs must end with a "/"」で弾かれた。
# 末尾スラッシュの問題ではない。
#
# Gecko のリソースは展開状態(omni.ja に固められていない)で .purgecaches も
# あるため、.mjs を直接書き換えれば反映される。
# validateBuiltInLocation を緩め、file:// も受け付けるようにする。
#
# 改変対象は Mozilla のコード(MPL-2.0)。THIRD_PARTY_NOTICES.md に記載すること。
KOTONE_EXT_SRC="${SRCROOT}/Extension"
if [ -f "${KOTONE_EXT_SRC}/manifest.json" ]; then
	KOTONE_RES_DIR="${GECKOVIEW_FW_FRAMEWORKS}/kotone-bridge"
	rm -rf "${KOTONE_RES_DIR}"
	mkdir -p "${KOTONE_RES_DIR}"
	cp -R "${KOTONE_EXT_SRC}/." "${KOTONE_RES_DIR}/"
	rm -f "${KOTONE_RES_DIR}"/*.md

	# ローカル HTTP ブリッジの接続情報を生成する。
	# 拡張機能（background の先頭で読み込む）と
	# アプリ（KotoneHTTPBridge がバンドルから読む）が同じファイルを見る。
	# 実行時に値を受け渡す経路が要らなくなる。
	KOTONE_HTTP_PORT=47821
	KOTONE_HTTP_TOKEN="$(uuidgen | tr 'A-Z' 'a-z')"
	cat > "${KOTONE_RES_DIR}/kotone-config.js" <<EOF
// 自動生成 — scripts/AddGecko.sh
// 拡張機能とアプリが同じ値を参照するための設定。
const KOTONE_BRIDGE_PORT = ${KOTONE_HTTP_PORT};
const KOTONE_BRIDGE_TOKEN = "${KOTONE_HTTP_TOKEN}";
EOF
	echo "note: http bridge config port=${KOTONE_HTTP_PORT}"
	echo "note: built-in bridge staged at kotone-bridge/"

	MANIFEST="${GECKOVIEW_FW_FRAMEWORKS}/chrome.manifest"
	if [ -f "${MANIFEST}" ]; then
		grep -v "^resource android " "${MANIFEST}" > "${MANIFEST}.tmp" || true
		mv "${MANIFEST}.tmp" "${MANIFEST}"
		printf 'resource android file:kotone-bridge/\n' >> "${MANIFEST}"
		echo "note: registered resource://android/ -> kotone-bridge/"
	fi

	GVWE="${GECKOVIEW_FW_FRAMEWORKS}/modules/GeckoViewWebExtension.sys.mjs"
	if [ -f "${GVWE}" ]; then
		python3 "${SRCROOT}/scripts/relax-builtin-location.py" "${GVWE}" || exit 1
		# 構造化クローンの復元先が {} になっており、拡張機能からの
		# メッセージが中身を失って空の辞書として届く問題を直す。
		python3 "${SRCROOT}/scripts/fix-port-message.py" "${GVWE}" || exit 1
	else
		echo "warning: GeckoViewWebExtension.sys.mjs が見つかりません" >&2
	fi
else
	echo "warning: ${KOTONE_EXT_SRC}/manifest.json が無いため組み込み配置をスキップ" >&2
fi

# --- 署名 --------------------------------------------------------------------
#
# 重要: engine/dist/bin/ の XUL と dylib には
# **Reynard 配布 IPA の署名がそのまま残っている**。
# 抽出元の Reynard.app は Xcode の archive で署名されており、
# その LC_CODE_SIGNATURE ごとコピーされてくるため。
#
#   XUL: LC_CODE_SIGNATURE offset=0x0D01A110 size=0x1A4B40
#        CodeDirectory ident='XUL' teamID=(なし)
#
# この署名は Kotone のバンドルに対しては無効なので、
# 放置すると起動時に dyld が拒否する:
#
#   Library not loaded: @rpath/XUL
#   Reason: ... 'Kotone.app/Frameworks/XUL' (code signature invalid ... errno=1)
#           sliceOffset=0x00000000, codeBlobOffset=0x0D01A110, codeBlobSize=0x001A4B40
#
# ← codeBlobOffset / codeBlobSize が Reynard の値と完全一致することから、
#    再署名されずに残っていることが確認できる。
#
# CI (CODE_SIGNING_ALLOWED=NO) では自前で署名できないので、
# **古い署名を取り除く**。こうすることで、後段の署名ツール
# (SideStore など) が「未署名の Mach-O」として扱えるようになる。
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] || [ "${CODE_SIGNING_REQUIRED:-YES}" = "NO" ]; then
	echo "note: CODE_SIGNING_ALLOWED=NO — removing stale signatures from Gecko binaries"
	for file in "${FRAMEWORKS_DIR}/XUL" "${FRAMEWORKS_DIR}"/*.dylib; do
		[ -f "${file}" ] || continue
		if codesign --remove-signature "${file}" 2> /dev/null; then
			echo "    stripped $(basename "${file}")"
		else
			echo "    (no signature) $(basename "${file}")"
		fi
	done
	exit 0
fi

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY_NAME:-Apple Development}}"
echo "note: signing Gecko binaries with ${SIGN_IDENTITY}"

for file in "${FRAMEWORKS_DIR}/XUL" "${FRAMEWORKS_DIR}"/*.dylib; do
	[ -f "${file}" ] || continue
	codesign --force --sign "${SIGN_IDENTITY}" \
		--preserve-metadata=identifier,entitlements "${file}"
done

codesign --force --sign "${SIGN_IDENTITY}" "${GECKOVIEW_FW}"
