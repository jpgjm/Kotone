#!/bin/bash
# =============================================================================
# check-symbols.sh — Swift のシンボル検査
#
# 実体は scripts/check_swift_symbols.py。
# Swift のコメントと文字列を 1 文字ずつ読んで落とす処理が要るため、
# シェルの中に Python を埋め込む形をやめて外部ファイルにした。
# 引用符の入れ子で壊れやすかったのも理由。
#
# CI の Install XcodeGen より前に実行する。
# macOS ランナーを 10 分使ってから型エラーで落ちるのを避けるため。
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

exec python3 scripts/check_swift_symbols.py
