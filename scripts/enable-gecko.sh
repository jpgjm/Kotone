#!/bin/bash
# =============================================================================
# enable-gecko.sh — project.yml のトグルブロックを一括で切り替える
#
#   ./scripts/enable-gecko.sh                 # Gecko 統合を有効化 (0-B2)
#   ./scripts/enable-gecko.sh --disable       # 無効化 (0-B1 に戻す)
#   ./scripts/enable-gecko.sh --status        # 状態表示のみ
#   ./scripts/enable-gecko.sh --force         # ソース未配置でも有効化
#   ./scripts/enable-gecko.sh --with-jit      # JIT を有効化（独立）
#   ./scripts/enable-gecko.sh --without-jit   # JIT を無効化（独立）
#
# 手で 1 箇所でも漏らすとリンクエラーか実行時クラッシュになり、
# 切り分けが面倒になるため、関連箇所を必ず同時に切り替える。
#
# ---------------------------------------------------------------------------
# マーカーの系統は 2 つあり、互いに独立して切り替わる。
#
#   GECKO-TOGGLE:*   Gecko 統合本体
#     flag           settings.base.GECKO_INTEGRATION の NO/YES
#     bridging       Kotone の bridging header / リンク設定
#     deps           Kotone の dependencies + postBuildScripts
#
#   JIT-TOGGLE:*     ペアリング JIT（任意）
#     sources        Kotone の sources に Sources/JIT を追加
#     settings       KOTONE_ENABLE_JIT 定義と libidevice_ffi.a の検索パス
#
# JIT を既定で外しているのは、Sources/JIT/RPPairing/libidevice_ffi.a が
# reynard-browser のリポジトリにも配布 IPA にも含まれていないため。
# Rust ビルド (tools/development/build-idevice.sh) の成果物であり、
# 静的ライブラリなのでバイナリからの抽出もできない。
# Gecko は JIT なしでも動作する（SpiderMonkey がインタプリタになり遅いだけ）。
#
# JIT の結合は閉じていることを確認済み。
# Sources/{GeckoView,Helper,Shared} から JIT シンボルへの参照は 0 件で、
# 唯一の接点は bridging header の #import "JITEnabler.h" だった。
#
# 仕組み:
#   マーカー行 "# >>> <FAMILY>:<name> >>>" 〜 "# <<< <FAMILY>:<name> <<<"
#   の間にある「<インデント>#@ <本文>」を「<インデント><本文>」に置き換える。
#   無効化はその逆。コメント文言に依存しないので説明文を書き換えても壊れない。
#   通常のコメント（# で始まり #@ でない行）は触らない。
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/project.yml"

GECKO_ACTION=""     # enable | disable | ""(触らない)
JIT_ACTION=""       # enable | disable | ""(触らない)
STATUS_ONLY=0
FORCE=0
EXPLICIT=0

for arg in "$@"; do
	case "$arg" in
		--disable)     GECKO_ACTION="disable"; EXPLICIT=1 ;;
		--enable)      GECKO_ACTION="enable";  EXPLICIT=1 ;;
		--with-jit)    JIT_ACTION="enable";    EXPLICIT=1 ;;
		--without-jit) JIT_ACTION="disable";   EXPLICIT=1 ;;
		--status)      STATUS_ONLY=1;          EXPLICIT=1 ;;
		--force)       FORCE=1 ;;
		-h|--help)
			sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "error: 不明な引数: $arg" >&2
			exit 1
			;;
	esac
done

# 引数なし（--force のみ含む）= Gecko を有効化
if [ "$EXPLICIT" -eq 0 ]; then
	GECKO_ACTION="enable"
fi

if [ ! -f "$PROJECT" ]; then
	echo "error: project.yml が見つかりません: $PROJECT" >&2
	exit 1
fi

# --- 系統ごとの状態判定 -------------------------------------------------------
# その系統のいずれかのブロックに #@ が残っていれば disabled とみなす。
family_state() {
	if awk -v fam="$1" '
		$0 ~ ("^[[:space:]]*# >>> " fam ":[a-z]+ >>>") { inb = 1; next }
		$0 ~ ("^[[:space:]]*# <<< " fam ":[a-z]+ <<<") { inb = 0; next }
		inb && /^[[:space:]]*#@ / { found = 1 }
		END { exit(found ? 0 : 1) }
	' "$PROJECT"; then
		echo "disabled"
	else
		echo "enabled"
	fi
}

count_sources() {
	find "$ROOT_DIR/Sources/$1" -type f \
		! -name '.gitkeep' ! -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

show_status() {
	echo "Gecko 統合 : $(family_state GECKO-TOGGLE)"
	echo "JIT        : $(family_state JIT-TOGGLE)"
	echo
	echo "GECKO_INTEGRATION: $(awk -F': *' '/^[[:space:]]*GECKO_INTEGRATION:/ {print $2; exit}' "$PROJECT")"
	echo
	if [ -f "$ROOT_DIR/Sources/IMPORT_PROVENANCE.txt" ]; then
		echo "取り込み済み: $(awk -F': *' '/^source-tag:/ {print $2; exit}' "$ROOT_DIR/Sources/IMPORT_PROVENANCE.txt")"
	else
		echo "取り込み: 未実施（CI が取得します）"
	fi
	echo
	echo "配置済みソース:"
	for d in GeckoView Helper Bridging Shared ThirdParty JIT App; do
		n="$(count_sources "$d")"
		mark=" "
		[ "${n:-0}" -gt 0 ] && mark="o"
		printf '  [%s] %-11s %s ファイル\n' "$mark" "$d" "${n:-0}"
	done
}

if [ "$STATUS_ONLY" -eq 1 ]; then
	show_status
	exit 0
fi

# --- 有効化前のチェック -------------------------------------------------------
check_sources() {
	# JIT は必須ではないので対象外
	missing=""
	for d in GeckoView Helper Bridging Shared; do
		n="$(count_sources "$d")"
		[ "${n:-0}" -eq 0 ] && missing="$missing $d"
	done
	if [ -n "$missing" ]; then
		# 本リポジトリは Reynard のソースをコミットせず CI で取得する方針なので、
		# ローカルで未配置なのは正常。import-reynard.sh があるなら通す。
		if [ -x "$ROOT_DIR/scripts/import-reynard.sh" ]; then
			echo "note: Sources/ が空です:$missing"
			echo "      CI の \"Import Reynard sources\" ステップが取得します。"
			echo "      手元でも試すなら ./scripts/import-reynard.sh を実行してください。"
		else
			echo "error: Reynard のソースが未配置です:$missing" >&2
			echo "       docs/PLACEMENT.md を参照してください。" >&2
			echo "       意図的に空のまま有効化する場合は --force を付けてください。" >&2
			return 1
		fi
	fi

	# JIT が中途半端に置かれていたら知らせる
	n="$(count_sources JIT)"
	if [ "${n:-0}" -gt 0 ] && [ ! -f "$ROOT_DIR/Sources/JIT/RPPairing/libidevice_ffi.a" ]; then
		echo "note: Sources/JIT/ にファイルがありますが libidevice_ffi.a がありません。"
		echo "      JIT は無効のままにします（--with-jit は使えません）。"
	fi
	return 0
}

check_jit_sources() {
	if [ ! -f "$ROOT_DIR/Sources/JIT/RPPairing/libidevice_ffi.a" ]; then
		echo "error: Sources/JIT/RPPairing/libidevice_ffi.a がありません。" >&2
		echo "       reynard-browser の tools/development/build-idevice.sh を" >&2
		echo "       実行して生成し、配置してください（Rust と Cargo が必要）。" >&2
		echo "       JIT なしでも Gecko は動作します（遅くなるだけ）。" >&2
		return 1
	fi
	return 0
}

if [ "$GECKO_ACTION" = "enable" ] && [ "$FORCE" -eq 0 ]; then
	check_sources || exit 1
fi

# Phase 1 以降、Sources/App は GeckoView を無条件に import する。
# 無効化すると必ずビルドが失敗するので、先に警告する。
if [ "$GECKO_ACTION" = "disable" ]; then
	if grep -qs "^import GeckoView" "$ROOT_DIR"/Sources/App/*.swift; then
		echo "warning: Sources/App が 'import GeckoView' を含んでいます。" >&2
		echo "         無効化するとビルドは必ず失敗します" >&2
		echo "         (error: unable to resolve module dependency: 'GeckoView')。" >&2
		echo "         0-B1 の配管検証に戻す目的でのみ使ってください。" >&2
		echo >&2
	fi
fi
if [ "$JIT_ACTION" = "enable" ] && [ "$FORCE" -eq 0 ]; then
	check_jit_sources || exit 1
fi

# --- 書き換え -----------------------------------------------------------------
apply_family() {
	fam="$1"
	mode="$2"
	before="$(family_state "$fam")"
	if [ "$before" = "${mode}d" ]; then
		echo "  $fam : 既に $before です"
		return 0
	fi

	tmp="$(mktemp)" || { echo "error: mktemp 失敗" >&2; return 1; }

	# 無効化時に "#@ " を差し込む位置は「マーカー行のインデント」に合わせる。
	# 行ごとの先頭空白を使うと、ブロック内で相対インデントを持つ行
	#   (例 "  excludes:") が往復のたびにずれてしまう。
	awk -v fam="$fam" -v mode="$mode" '
		BEGIN { inb = 0; base = 0 }
		$0 ~ ("^[[:space:]]*# >>> " fam ":[a-z]+ >>>") {
			match($0, /^[[:space:]]*/); base = RLENGTH
			inb = 1; print; next
		}
		$0 ~ ("^[[:space:]]*# <<< " fam ":[a-z]+ <<<") { inb = 0; print; next }
		inb {
			if (mode == "enable") {
				if (match($0, /^[[:space:]]*#@ /)) {
					print substr($0, 1, RSTART + RLENGTH - 4) substr($0, RSTART + RLENGTH)
					next
				}
				if ($0 ~ /^[[:space:]]*GECKO_INTEGRATION:/) {
					sub(/:[[:space:]]*"?NO"?[[:space:]]*$/, ": \"YES\"")
					print; next
				}
			} else {
				if ($0 ~ /^[[:space:]]*GECKO_INTEGRATION:/) {
					sub(/:[[:space:]]*"?YES"?[[:space:]]*$/, ": \"NO\"")
					print; next
				}
				if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) { print; next }
				match($0, /^[[:space:]]*/)
				ind = (RLENGTH < base) ? RLENGTH : base
				print substr($0, 1, ind) "#@ " substr($0, ind + 1)
				next
			}
		}
		{ print }
	' "$PROJECT" > "$tmp" || { rm -f "$tmp"; echo "error: 書き換え失敗" >&2; return 1; }

	if [ ! -s "$tmp" ]; then
		rm -f "$tmp"
		echo "error: 出力が空になりました" >&2
		return 1
	fi

	if command -v python3 > /dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
		if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$tmp" 2>/dev/null; then
			echo "error: 書き換え後の YAML が不正です" >&2
			rm -f "$tmp"
			return 1
		fi
	fi

	mv "$tmp" "$PROJECT"
	echo "  $fam : $before -> $(family_state "$fam")"
	return 0
}

cp "$PROJECT" "$PROJECT.bak"

RC=0
if [ -n "$GECKO_ACTION" ]; then apply_family GECKO-TOGGLE "$GECKO_ACTION" || RC=1; fi
if [ -n "$JIT_ACTION" ];   then apply_family JIT-TOGGLE   "$JIT_ACTION"   || RC=1; fi

if [ "$RC" -ne 0 ]; then
	echo "エラーが発生したため project.yml.bak から復元します。" >&2
	cp "$PROJECT.bak" "$PROJECT"
	exit 1
fi

echo
echo "変更前のファイルは project.yml.bak に保存しました。"
echo
show_status

if [ "$GECKO_ACTION" = "enable" ]; then
	echo
	echo "次の手順:"
	echo "  1. push して GitHub Actions の build を実行"
	echo "     gecko_integration は project.yml から自動判定されます"
	echo "  2. SideStore で \"Keep App Extensions\" を有効にしてインストール"
fi
