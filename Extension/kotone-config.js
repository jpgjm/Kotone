//
// kotone-config.js
//
// ⚠️ このファイルは scripts/AddGecko.sh がビルド時に上書きする。
//    ここに書いてある値は使われない（リポジトリ上の見た目のための既定値）。
//
// アプリ側 (KotoneHTTPBridge) は同じファイルをバンドルから読んで
// ポートとトークンを合わせる。両者が同じ 1 ファイルを見ることで、
// 実行時の受け渡し経路を不要にしている。
//
const KOTONE_BRIDGE_PORT = 0;
const KOTONE_BRIDGE_TOKEN = "";
