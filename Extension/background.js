//
// background.js — Kotone Bridge
//
// Swift 側との窓口はここ 1 箇所に集約する。
//
// なぜ content script から直接 sendNativeMessage しないか:
//
//   * Gecko は送信元によって配送先の dispatcher を変える。
//     background script → EventDispatcher.instance （ランタイム）
//     content script    → getDispatcherForWindow   （セッション）
//     content script 直結は allowContentMessaging の条件に依存し、
//     GeckoViewConnection のコンストラクタで例外になりうる。
//
//   * content script はページ遷移のたびに作り直される。
//     YouTube Music は SPA だが、リロードや別ドメインへの遷移で消える。
//     background script なら接続を永続化できる。
//
// 経路:
//   Swift  --GeckoView:WebExtension:PortMessageFromApp-->  background
//   background  --tabs.sendMessage-->  content
//   content  --runtime.sendMessage-->  background
//   background  --port.postMessage-->  Swift
//

const NATIVE_APP = "kotone";

// ---------------------------------------------------------------------------
// ポーリング
//
// 以前は長時間ポーリング（サーバ側で接続を保留）にしていたが、
// 実測で数分後にブリッジごと死んだ。
//
//   19:14:05  拡張機能が接続しました
//   19:18:36  最後の HTTP event
//   19:23:05  以降すべてタイムアウト
//
// 保留された接続が回収されず、/event も含めて通らなくなっていた。
//
// 短い間隔で問い合わせる方式に変える。ループバック通信なので
// 毎秒 2〜3 往復は負荷にならない。接続が残らないので同じ死に方はしない。
//
// 拡張機能からのイベントは同じ往復に相乗りさせて、接続数を半分にする。
// ---------------------------------------------------------------------------

const POLL_INTERVAL_MS = 400;

/// Swift へ送るイベントの待ち行列。次の /poll に相乗りさせる。
let pendingEvents = [];

function queueEvent(payload) {
  pendingEvents.push(payload);
  // 溜まりすぎたら古いものを捨てる（timeupdate は落としてよい）
  if (pendingEvents.length > 50) {
    pendingEvents = pendingEvents.slice(-20);
  }
}

/// 応答が返らないコマンドでループ全体が止まらないようにする。
function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(label + " が " + ms + "ms で応答しません")), ms)
    ),
  ]);
}

// ページ遷移の直後は content script がまだ入っていない。
//
//   09:17:42  openVideo 失敗: Could not establish connection.
//             Receiving end does not exist.
//
// 少し待って入り直すのを待つ。SPA 遷移でも再注入されることがある。
async function callContentWithRetry(payload, attempts = 4) {
  let lastError;
  for (let i = 0; i < attempts; i++) {
    try {
      return await callContent(payload);
    } catch (e) {
      lastError = e;
      const text = String((e && e.message) || e);
      const transient =
        text.includes("Receiving end does not exist") ||
        text.includes("message port closed") ||
        text.includes("を開いていません");
      if (!transient) throw e;
      await new Promise(r => setTimeout(r, 400));
    }
  }
  throw lastError;
}

// ---------------------------------------------------------------------------
// URL を開く。
//
// content script が入っていないページ（AMO など）を開いたままでも
// **エラーにしない**。そのタブをそのまま目的の URL に書き換える。
//
// 以前は「YouTube のページを開いていません」で失敗し、
// ネイティブ側のフォールバックに頼っていた。
// 拡張機能はタブを操作できるので、ここで完結させた方が素直。
// ---------------------------------------------------------------------------
async function openURL(url) {
  if (!url) throw new Error("url がありません");

  // 1. YouTube のタブがあれば content script に任せる（ページ内遷移）
  const tabs = await musicTabs();
  if (tabs.length) {
    try {
      return await callContentWithRetry({ type: "openURL", url });
    } catch (e) {
      console.warn("[kotone] content 経由に失敗。タブを書き換える", e);
    }
  }

  // 2. 無ければ現在のタブを書き換える
  const active = (await browser.tabs.query({ active: true }))[0]
    || (await browser.tabs.query({}))[0];
  if (!active) throw new Error("書き換えられるタブがありません");

  await browser.tabs.update(active.id, { url });
  return { ok: true, url, method: "tabs.update" };
}

async function runCommand(msg) {
  let result = null;
  let error = null;
  try {
    if (msg.type === "ping") {
      result = { pong: true, at: Date.now() };
    } else if (msg.type === "openURL") {
      result = await withTimeout(
        openURL((msg.payload && msg.payload.url) || msg.url),
        // 曲が実際に変わったかの確認に最大 2.5 秒、
        // content 経由が失敗したらタブ書き換えに回るので、その分を見込む
        15000,
        msg.type
      );
    } else if (msg.type === "content") {
      // YouTube 外から戻る場合、読み込みと注入で最大 10 秒かかる。
      result = await withTimeout(callContentWithRetry(msg.payload || {}), 15000, msg.type);
    } else {
      result = await withTimeout(
        callContentWithRetry(Object.assign({ type: msg.type }, msg.payload || {})),
        // resolveAudio はネットワークを叩くので長めに取る。
        // それ以外も、YouTube 外から戻る場合は読み込みを待つ。
        msg.type === "resolveAudio" ? 25000 : 15000,
        msg.type
      );
    }
  } catch (e) {
    error = String((e && e.message) || e);
  }
  if (msg.requestId !== undefined) {
    try {
      await httpCall("/reply", { requestId: msg.requestId, result, error });
    } catch (e) {
      console.error("[kotone] reply failed", e);
    }
  }
}

async function httpPollLoop() {
  while (HTTP.alive) {
    try {
      const events = pendingEvents;
      pendingEvents = [];
      const res = await httpCall("/poll", { events });

      // コマンドは待たずに走らせる。1 本が詰まっても
      // 次のポーリングは進む。
      for (const msg of (res && res.messages) || []) {
        runCommand(msg);
      }
    } catch (e) {
      console.error("[kotone] poll failed", e);
      await new Promise(r => setTimeout(r, 2000));
      continue;
    }
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS));
  }
}


let port = null;
let connecting = false;

// ---------------------------------------------------------------------------
// ネイティブ接続
// ---------------------------------------------------------------------------

async function reportPermissions() {
  try {
    const perms = await browser.permissions.getAll();
    console.log("[kotone] permissions", JSON.stringify(perms));
  } catch (e) {
    console.log("[kotone] permissions unavailable", e);
  }
}

function connect() {
  if (port || connecting) return;
  connecting = true;

  // connectNative は geckoViewAddons 権限が無いと
  // Firefox 標準の NativeApp（外部プロセス起動）に流れてしまい、
  // iOS には該当プロセスが無いので必ず失敗する。
  //   ExtensionParent.sys.mjs:259
  //     if (context.extension.hasPermission("geckoViewAddons")) {
  //       return new GeckoViewConnection(...)   ← ここに入る必要がある
  //     } else if (sender.verified) {
  //       return new NativeApp(context, nativeApp)
  //     }
  // geckoViewAddons は privileged 権限だが、組み込みアドオンは
  // builtIn ⇒ isPrivileged なので付与される
  // （Extension.sys.mjs getIsPrivileged）。
  try {
    port = browser.runtime.connectNative(NATIVE_APP);
    connecting = false;

    port.onMessage.addListener(handleNativeMessage);

    port.onDisconnect.addListener(() => {
      const err = browser.runtime.lastError;
      console.log("[kotone] native port disconnected", err && err.message);
      port = null;
      // Swift 側が落ちた場合に備えて張り直す
      setTimeout(connect, 1000);
    });

    // 受信側でネスト辞書が潰れていないか判別できるよう、
    // 階層と型のバリエーションを入れておく。
    post({
      type: "hello",
      version: browser.runtime.getManifest().version,
      num: 42,
      flag: true,
      nested: { a: 1, b: "two" },
      list: [1, 2, 3],
    });
    console.log("[kotone] native port connected");
  } catch (e) {
    connecting = false;
    port = null;
    console.error("[kotone] connectNative failed", e);
    setTimeout(connect, 2000);
  }
}

// ---------------------------------------------------------------------------
// 送受信は「JSON 文字列」で行う。
//
// オブジェクトをそのまま postMessage すると、Swift 側には
// 空の辞書として届く。実測:
//
//   BRIDGE  受信の生データ (GeckoView:WebExtension:PortMessage)
//     data: __NSDictionaryM = { }
//
// Gecko 側は
//   onPortMessage(holder) {
//     this.dispatcher.sendRequest("...:PortMessage", { data: holder.deserialize({}) });
//   }
// と、構造化クローンを空オブジェクトをグローバルとして復元している。
// その結果できたオブジェクトが JS→ネイティブ変換で列挙できず、
// 空辞書になっているとみられる。
//
// 文字列なら単純な値なので変換を通り抜けられる。
// ---------------------------------------------------------------------------

function post(payload) {
  if (!port) {
    console.warn("[kotone] post skipped, no port:", payload && payload.type);
    return false;
  }
  try {
    port.postMessage(JSON.stringify(payload));
    return true;
  } catch (e) {
    console.error("[kotone] postMessage failed", e);
    port = null;
    setTimeout(connect, 1000);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Swift からの指示
// ---------------------------------------------------------------------------

async function handleNativeMessage(raw) {
  // Swift 側も JSON 文字列で送ってくる。オブジェクトで来た場合にも備える。
  let msg = raw;
  if (typeof raw === "string") {
    try {
      msg = JSON.parse(raw);
    } catch (e) {
      console.error("[kotone] JSON.parse failed", raw, e);
      msg = null;
    }
  }

  // Swift → 拡張機能 の到達確認。届いていなければ何も出ない。
  try {
    post({
      type: "echo",
      rawType: typeof raw,
      raw: typeof raw === "string" ? raw : JSON.stringify(raw ?? null),
    });
  } catch (e) {
    console.error("[kotone] echo failed", e);
  }

  if (!msg || typeof msg !== "object") return;

  // requestId があれば必ず返す。Swift 側は await できる。
  const reply = (result, error) => {
    if (msg.requestId === undefined) return;
    post({
      type: "reply",
      requestId: msg.requestId,
      result: result === undefined ? null : result,
      error: error === undefined ? null : String(error),
    });
  };

  try {
    switch (msg.type) {
      case "ping":
        reply({ pong: true, at: Date.now() });
        break;

      // rev.20 の疎通確認用。ページからタイトルなどを取ってくる。
      case "probe":
        reply(await callContent({ type: "probe" }));
        break;

      // 任意のコマンドを content script に中継する。
      // 再生制御はここに載せていく（rev.21 以降）。
      case "content":
        reply(await callContent(msg.payload || {}));
        break;

      default:
        reply(null, "unknown message type: " + msg.type);
    }
  } catch (e) {
    reply(null, e);
  }
}

// ---------------------------------------------------------------------------
// content script との中継
// ---------------------------------------------------------------------------

// content script が入っているタブ。
// music だけでなく通常の YouTube も対象にする。
// 「URL を受け取って再生するだけ」なので、
// music.youtube.com に限定する理由が無い。
async function musicTabs() {
  return await browser.tabs.query({
    url: [
      "*://music.youtube.com/*",
      "*://www.youtube.com/*",
      "*://m.youtube.com/*",
    ],
  });
}

async function callContent(payload) {
  let tabs = await musicTabs();

  // YouTube を開いていなければ、そのタブを音楽版に書き換えて待つ。
  //
  // 再生や一時停止はページ内の操作なので、別サイトに居ると届かない。
  // 以前はここでエラーにしてネイティブ側に処理を投げ返していたが、
  // 拡張機能はタブを操作できるので、ここで戻した方が素直。
  if (!tabs.length) {
    const active = (await browser.tabs.query({ active: true }))[0];
    if (!active) throw new Error("操作できるタブがありません");

    console.log("[kotone] YouTube 外なので戻す:", active.url);
    await browser.tabs.update(active.id, { url: "https://music.youtube.com/" });

    // 読み込みと content script の注入を待つ
    for (let i = 0; i < 20; i++) {
      await new Promise(r => setTimeout(r, 500));
      tabs = await musicTabs();
      if (tabs.length) break;
    }
    if (!tabs.length) throw new Error("YouTube に戻れませんでした");
  }
  // 単一タブ想定。複数あれば最後にアクティブだったものを使う。
  const tab = tabs.find((t) => t.active) || tabs[0];
  return await browser.tabs.sendMessage(tab.id, payload);
}

// content script からの自発的な通知（再生状態の変化など）
browser.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || typeof msg !== "object") return;
  const tabId = sender.tab ? sender.tab.id : null;
  post({ type: "event", tabId, payload: msg });
  // 直接 POST せず、次の /poll に相乗りさせる。
  // timeupdate が毎秒来るため、1 件ずつ接続を張ると数が増えすぎる。
  queueEvent(msg);
});

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 経路の比較用。
//
// ポート経由（connectNative）は中身が空で届く問題が続いている。
// sendNativeMessage は Gecko 側の別コード
// （GeckoViewConnection.sendMessage）を通るので、こちらなら
// 通る可能性がある。両方投げて Swift 側で比べる。
//
// sendNativeMessage は Swift の応答をそのまま解決値として返すため、
// これが使えるなら「要求 → 応答」も成立する。
// ---------------------------------------------------------------------------
async function probeSendNativeMessage() {
  const payload = {
    type: "hello-direct",
    version: browser.runtime.getManifest().version,
    num: 42,
    nested: { a: 1, b: "two" },
  };
  for (const body of [JSON.stringify(payload), payload]) {
    try {
      const reply = await browser.runtime.sendNativeMessage(NATIVE_APP, body);
      console.log("[kotone] sendNativeMessage reply", reply);
    } catch (e) {
      console.error("[kotone] sendNativeMessage failed", e);
    }
  }
}

// ---------------------------------------------------------------------------
// 代替経路: ローカル HTTP
//
// 正規のメッセージング（connectNative / sendNativeMessage）は
// 構造化クローンの復元が空になるため使えない可能性が高い。
// Gecko の機構を一切通さない経路として、127.0.0.1 の HTTP を使う。
//
// 接続先は kotone-config.js が定義する（AddGecko.sh がビルド時に生成し、
// アプリ起動時のポートとトークンを埋め込む）。
// ---------------------------------------------------------------------------

const HTTP = {
  base: null,
  token: null,
  alive: false,
};

function httpConfigured() {
  return typeof KOTONE_BRIDGE_PORT === "number" && KOTONE_BRIDGE_PORT > 0;
}

async function httpCall(path, body) {
  if (!HTTP.base) return null;
  const res = await fetch(HTTP.base + path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Kotone-Token": HTTP.token,
    },
    body: JSON.stringify(body || {}),
  });
  if (!res.ok) throw new Error("HTTP " + res.status);
  return await res.json();
}

async function httpStart() {
  if (!httpConfigured()) {
    console.log("[kotone] http bridge not configured");
    return;
  }
  HTTP.base = `http://127.0.0.1:${KOTONE_BRIDGE_PORT}`;
  HTTP.token = KOTONE_BRIDGE_TOKEN;

  try {
    await httpCall("/hello", {
      version: browser.runtime.getManifest().version,
      num: 42,
      nested: { a: 1, b: "two" },
    });
    HTTP.alive = true;
    console.log("[kotone] http bridge connected");
    httpPollLoop();
  } catch (e) {
    console.error("[kotone] http hello failed", e);
    setTimeout(httpStart, 3000);
  }
}

reportPermissions();
connect();
setTimeout(probeSendNativeMessage, 1500);
setTimeout(httpStart, 500);
