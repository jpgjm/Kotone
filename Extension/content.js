//
// content.js — Kotone Bridge
//
// music.youtube.com のページ側で動く。background.js からの依頼に答える。
//
// 注意: content script は「隔離ワールド」で動くため、ページの JS 変数
// （ytmusic-* 要素に生えている store など）には直接触れない。
// Firefox では wrappedJSObject でページ側オブジェクトに到達できるが、
// rev.20 では DOM の読み取りだけに留める。壊れにくさを優先する。
//

console.log("[kotone] content script loaded");

// ---------------------------------------------------------------------------
// ページ状態の読み取り
// ---------------------------------------------------------------------------

function text(sel, root) {
  const el = (root || document).querySelector(sel);
  return el ? el.textContent.trim() : null;
}

function probe() {
  const video = document.querySelector("video");
  const bar = document.querySelector("ytmusic-player-bar");

  return {
    // 疎通確認の最小情報
    href: location.href,
    title: document.title,

    // プレイヤーバーから読める情報
    track: text(".title.ytmusic-player-bar", bar),
    byline: text(".byline.ytmusic-player-bar", bar),

    // <video> は MSE で駆動されている。src は blob: になるはず。
    video: video
      ? {
          exists: true,
          src: (video.currentSrc || video.src || "").slice(0, 24),
          paused: video.paused,
          currentTime: video.currentTime,
          duration: isFinite(video.duration) ? video.duration : null,
          volume: video.volume,
          muted: video.muted,
          readyState: video.readyState,
        }
      : { exists: false },

    // ページが SPA として起動しきっているかの目安
    appReady: !!document.querySelector("ytmusic-app"),
    at: Date.now(),
  };
}

// ---------------------------------------------------------------------------
// background からの依頼
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 再生制御
//
// ページの JS 変数には触れず、<video> と DOM ボタンだけで操作する。
// 隔離ワールドからでも確実に届く範囲に限定している。
//
// 曲の切り替えは YouTube Music 側のキュー操作が必要なので、
// 現状はプレイヤーバーのボタンを押す方式。
// videoId 指定の再生は URL 遷移で行う（SPA なので watch?v= へ）。
// ---------------------------------------------------------------------------

function video() {
  return document.querySelector("video");
}

// ---------------------------------------------------------------------------
// ループ / シャッフル
//
// 状態はページの Redux ストアが持っている。pear-desktop も同じ場所を見ている。
//   src/providers/song-info-front.ts:66
//     document.querySelector('ytmusic-player-bar').getState().queue.repeatMode
//
// 以前は `repeat-mode` 属性を読もうとしていたが、そんな属性は無い。
// 読めないと必ず "off" を返す実装だったため、
//   * setRepeat が最大 3 回押して終わり、状態が合わない
//   * syncRepeatModeFromPage が常に off に上書きする
// という壊れ方をしていた。
//
// content script は隔離ワールドなので、ページ側のオブジェクトに
// 触るには wrappedJSObject を経由する必要がある。
// ---------------------------------------------------------------------------

function playerBar() {
  const el = document.querySelector("ytmusic-player-bar");
  if (!el) throw new Error("プレイヤーバーが見つかりません");
  return el;
}

/// ページの Redux ストアから状態を読む。
function pageQueueState() {
  const candidates = [];
  try {
    const bar = playerBar();
    candidates.push(bar.wrappedJSObject || bar);
  } catch (e) {
    // プレイヤーバーがまだ無い
  }
  const right = document.querySelector("#right-controls .repeat");
  if (right) {
    const host = right.wrappedJSObject || right;
    if (host.__dataHost) candidates.push(host.__dataHost);
  }

  for (const target of candidates) {
    try {
      if (typeof target.getState === "function") {
        const state = target.getState();
        if (state && state.queue) return state.queue;
      }
    } catch (e) {
      // 触れないことがある
    }
  }
  return null;
}

function repeatButton() {
  const el =
    document.querySelector("#right-controls .repeat") ||
    document.querySelector("ytmusic-player-bar .repeat");
  if (!el) throw new Error("ループボタンが見つかりません");
  return el;
}

/// 現在のループ状態。ページの言語に依存しない。
///
/// ストアの値は "NONE" / "ALL" / "ONE"。
/// 読めない場合は null を返す。"off" を返してしまうと、
/// 未取得と本当に off の区別がつかなくなる。
function currentRepeatMode() {
  const queue = pageQueueState();
  const raw = queue && queue.repeatMode;
  if (!raw) return null;

  const text = String(raw).toUpperCase();
  if (text.includes("ONE")) return "one";
  if (text.includes("ALL")) return "all";
  if (text.includes("NONE") || text.includes("OFF")) return "off";
  return null;
}

/// 現在のシャッフル状態。読めない場合は null。
function currentShuffleEnabled() {
  const queue = pageQueueState();
  if (!queue) return null;
  if (typeof queue.shuffleEnabled === "boolean") return queue.shuffleEnabled;
  if (typeof queue.isShuffled === "boolean") return queue.isShuffled;
  return null;
}

function clickPlayerButton(selector) {
  const bar = document.querySelector("ytmusic-player-bar");
  const el = (bar || document).querySelector(selector);
  if (!el) throw new Error("ボタンが見つかりません: " + selector);
  el.click();
  return true;
}

const commands = {
  probe: () => probe(),

  play: () => {
    const v = video();
    if (!v) throw new Error("video 要素がありません");
    return v.play().then(() => ({ ok: true, paused: v.paused }));
  },

  pause: () => {
    const v = video();
    if (!v) throw new Error("video 要素がありません");
    v.pause();
    return { ok: true, paused: v.paused };
  },

  toggle: () => {
    const v = video();
    if (!v) throw new Error("video 要素がありません");
    if (v.paused) {
      return v.play().then(() => ({ ok: true, paused: false }));
    }
    v.pause();
    return { ok: true, paused: true };
  },

  next: () => clickPlayerButton(".next-button"),
  previous: () => clickPlayerButton(".previous-button"),

  // ---------------------------------------------------------------------
  // ループ / シャッフル
  //
  // ページ側のボタンを押す。セレクタは pear-desktop が使っているものに合わせた
  //   src/providers/song-info-front.ts:66
  //     document.querySelector('#right-controls .repeat')
  //
  // ループは押すたびに off → all → one → off と巡回する。
  // 目的の状態にするため、必要な回数だけ押す。
  // 現在の状態は aria-label ではなく `repeat-mode` 属性から読む
  // （ページの言語に依存しないため）。
  // ---------------------------------------------------------------------

  repeatState: () => ({
    mode: currentRepeatMode(),
    shuffle: currentShuffleEnabled(),
  }),

  // ループを指定の状態にする。
  //
  // ページのボタンは押すたびに NONE → ALL → ONE → NONE と巡回する。
  // 状態を読めるので、目的の状態になるまで押す。
  // 読めない場合（ストアに触れない等）は 1 回だけ押して、
  // 結果をそのまま返す。嘘の成功を返さない。
  setRepeat: async (msg) => {
    const order = ["off", "all", "one"];
    if (order.indexOf(msg.mode) < 0) {
      throw new Error("不明な repeat モード: " + msg.mode);
    }

    const button = repeatButton();
    const readable = currentRepeatMode() !== null;

    if (!readable) {
      button.click();
      await new Promise(r => setTimeout(r, 150));
      return { ok: true, mode: currentRepeatMode(), readable: false };
    }

    // 3 回押せば必ず一巡する
    for (let i = 0; i < order.length; i++) {
      if (currentRepeatMode() === msg.mode) break;
      button.click();
      await new Promise(r => setTimeout(r, 150));
    }

    const mode = currentRepeatMode();
    if (mode !== msg.mode) {
      throw new Error(
        "ループを " + msg.mode + " にできませんでした（現在: " + mode + "）"
      );
    }
    return { ok: true, mode, readable: true };
  },

  cycleRepeat: async () => {
    repeatButton().click();
    await new Promise(r => setTimeout(r, 150));
    return { ok: true, mode: currentRepeatMode() };
  },

  // シャッフル。押した結果が実際に変わったかを確かめる。
  toggleShuffle: async () => {
    const el =
      document.querySelector("#right-controls .shuffle") ||
      document.querySelector("ytmusic-player-bar .shuffle");
    if (!el) throw new Error("シャッフルボタンが見つかりません");

    const before = currentShuffleEnabled();
    el.click();
    await new Promise(r => setTimeout(r, 200));
    const after = currentShuffleEnabled();

    return { ok: true, before, after, changed: before !== after };
  },

  seek: (msg) => {
    const v = video();
    if (!v) throw new Error("video 要素がありません");
    if (typeof msg.position !== "number") throw new Error("position が数値ではありません");
    v.currentTime = msg.position;
    return { ok: true, currentTime: v.currentTime };
  },

  setVolume: (msg) => {
    const v = video();
    if (!v) throw new Error("video 要素がありません");
    if (typeof msg.volume !== "number") throw new Error("volume が数値ではありません");
    v.volume = Math.max(0, Math.min(1, msg.volume));
    return { ok: true, volume: v.volume };
  },

  // ---------------------------------------------------------------------
  // ダウンロード
  //
  // ページのコンテキストから fetch する。こうすると
  //   * Cookie / 認証がそのまま乗る
  //   * 署名済み URL をそのまま使える（PlayerJSService が不要）
  //   * CORS を気にしなくてよい
  //
  // 音声 URL は InnerTube の player エンドポイントから取る。
  // ページと同じ origin なので、追加の認証情報は要らない。
  //
  // itag 140 (AAC 128kbps) を優先する。AVPlayer で扱いやすく、
  // WebM/Opus よりファイルが素直なため。
  // ---------------------------------------------------------------------

  // ページ自身が持っている再生情報を調べる。
  //
  // ページは既に再生できているので、その player レスポンスに
  // 使える URL が入っていれば、それが最も確実な入手経路になる。
  // YouTube Music は SABR で配信するため url が無い可能性もあるので、
  // まず実態を確かめられるようにしておく。
  playerResponseInfo: () => {
    let response = null;
    try {
      const w = window.wrappedJSObject || window;
      response = w.ytInitialPlayerResponse || null;
    } catch (e) {
      response = null;
    }
    if (!response) {
      const m = document.documentElement.innerHTML.match(
        /ytInitialPlayerResponse\s*=\s*(\{.+?\});/
      );
      if (m) {
        try {
          response = JSON.parse(m[1]);
        } catch (e) {
          response = null;
        }
      }
    }
    if (!response) return { found: false };

    const data = response.streamingData || {};
    const formats = data.adaptiveFormats || [];
    const audio = formats.filter(f => (f.mimeType || "").startsWith("audio/"));
    return {
      found: true,
      status: response.playabilityStatus && response.playabilityStatus.status,
      videoId: response.videoDetails && response.videoDetails.videoId,
      audioCount: audio.length,
      withUrl: audio.filter(f => f.url).length,
      withCipher: audio.filter(f => f.signatureCipher).length,
      itags: audio.map(f => f.itag),
      hasServerAbr: !!data.serverAbrStreamingUrl,
    };
  },

  resolveAudio: async (msg) => {
    const videoId = msg.videoId;
    if (!videoId) throw new Error("videoId がありません");

    // -------------------------------------------------------------------
    // クライアントを順に試す。
    //
    // WEB_REMIX はページと同じクライアントなので Cookie がそのまま効くが、
    // adaptiveFormats が signatureCipher（署名付き）で返ることが多い。
    // 復号には base.js の解析が要り、それは意図的に落としてある。
    //
    // VISIONOS は yt-dlp が「JS プレイヤー不要・poToken 不要」と
    // 分類している数少ないクライアントで、url がそのまま入ってくる。
    //   yt-dlp/extractor/youtube/_base.py の 'visionos'
    //   REQUIRE_JS_PLAYER: False, GVS_PO_TOKEN_POLICY なし
    //
    // ANDROID_VR も同様に JS プレイヤー不要だが、
    // yt-dlp の注記によると 2026-08-17 以降は全フォーマットが 403 になる
    // ため候補から外した。
    // -------------------------------------------------------------------
    // 実測（rev.49）での失敗理由:
    //   WEB_REMIX: UNPLAYABLE 動画を再生できません
    //     → Music カタログ外の動画は WEB_REMIX では再生不可扱いになる
    //   VISIONOS: LOGIN_REQUIRED ログインして bot ではないことを確認してください
    //     → 素の VISIONOS は bot 判定に引っかかる
    //
    // 対策として visitorData を添える。ページが既に持っている値なので、
    // セッションの継続として扱われやすくなる。
    // また WEB（www.youtube.com 相当）を足す。
    // Music カタログ外の動画はこちらなら再生可能扱いになる。
    const visitorData = pageVisitorData();

    const clients = [
      {
        name: "WEB_REMIX",
        context: {
          clientName: "WEB_REMIX",
          clientVersion: pageClientVersion(),
          hl: "ja",
          gl: "JP",
        },
      },
      {
        name: "VISIONOS",
        context: {
          clientName: "VISIONOS",
          clientVersion: "1.02",
          deviceMake: "Apple",
          deviceModel: "RealityDevice17,1",
          osName: "visionOS",
          osVersion: "26.5.23O471",
          hl: "ja",
          gl: "JP",
        },
      },
      {
        name: "WEB",
        context: {
          clientName: "WEB",
          clientVersion: "2.20250101.00.00",
          hl: "ja",
          gl: "JP",
        },
      },
    ];

    // 認証が効いているかを最初に記録する。
    // 「ログインしているのにダウンロードできない」の切り分け用。
    const authPresent = !!(await authorizationHeader("https://music.youtube.com"));
    const problems = [authPresent ? "auth=あり" : "auth=なし（SAPISID が読めません）"];

    for (const client of clients) {
      let json;
      try {
        // 絶対 URL にする。
        //
        // content script の fetch はページを基準に解決してくれない。
        // 相対パスを渡すと実測でこうなる:
        //   TypeError: /youtubei/v1/player?prettyPrint=false is not a valid URL.
        const endpoint =
          "https://music.youtube.com/youtubei/v1/player?prettyPrint=false";
        const origin = "https://music.youtube.com";
        const headers = { "Content-Type": "application/json" };

        // ログイン状態を伝える。無いと未ログイン扱いになる。
        const auth = await authorizationHeader(origin);
        if (auth) {
          headers["Authorization"] = auth;
          headers["X-Origin"] = origin;
          headers["X-Goog-AuthUser"] = "0";
        }
        if (visitorData) headers["X-Goog-Visitor-Id"] = visitorData;

        const res = await fetch(endpoint, {
          method: "POST",
          credentials: "include",
          headers,
          body: JSON.stringify({
            videoId,
            context: { client: client.context },
            playbackContext: {
              contentPlaybackContext: { html5Preference: "HTML5_PREF_WANTS" },
            },
          }),
        });
        if (!res.ok) {
          problems.push(client.name + ": HTTP " + res.status);
          continue;
        }
        json = await res.json();
      } catch (e) {
        problems.push(client.name + ": " + e);
        continue;
      }

      const status = json.playabilityStatus && json.playabilityStatus.status;
      if (status && status !== "OK") {
        problems.push(
          client.name + ": " + status + " " +
          ((json.playabilityStatus && json.playabilityStatus.reason) || "")
        );
        continue;
      }

      const formats = (json.streamingData && json.streamingData.adaptiveFormats) || [];
      const audio = formats
        .filter(f => (f.mimeType || "").startsWith("audio/") && f.url)
        .sort((a, b) => {
          // itag 140 (AAC 128kbps) を最優先。AVPlayer で扱いやすい。
          if (a.itag === 140 && b.itag !== 140) return -1;
          if (b.itag === 140 && a.itag !== 140) return 1;
          return (b.bitrate || 0) - (a.bitrate || 0);
        })[0];

      if (!audio) {
        const ciphered = formats.some(f => f.signatureCipher);
        const kinds = formats
          .filter(f => (f.mimeType || "").startsWith("audio/"))
          .map(f => f.itag)
          .join(",");
        problems.push(
          client.name + ": " +
          (ciphered ? "署名付き URL のみ" : "音声フォーマットなし") +
          (kinds ? " (itag " + kinds + ")" : "")
        );
        continue;
      }

      return {
        client: client.name,
        url: audio.url,
        itag: audio.itag,
        mimeType: audio.mimeType,
        bitrate: audio.bitrate,
        contentLength: audio.contentLength ? Number(audio.contentLength) : null,
      };
    }

    throw new Error("音声 URL を取得できません — " + problems.join(" / "));
  },

  // -------------------------------------------------------------------
  // videoId を指定して再生する。
  //
  // GeckoSession.load() でも開けるが、毎回**ページ全体を読み直す**ので
  //   * 数秒かかる
  //   * 子プロセスが増える
  //   * 連続で呼ぶと遷移が詰まる（rev.47 で実測）
  //
  // YouTube Music は SPA なので、内部のルーターで遷移させれば
  // ページを読み直さずに曲だけ切り替わる。
  // 履歴 API で URL を変えて popstate を出すと、
  // ページ側のルーターが拾って再生を始める。
  // -------------------------------------------------------------------
  // -------------------------------------------------------------------
  // URL を開いて再生する。
  //
  // 受け取った URL をそのまま使う。music.youtube.com へ組み立て直さない。
  // 書き換えると m.youtube.com の URL が音楽版へ飛ばされたり、
  // t= などのクエリが落ちたりする。
  //
  // 同じサイト内なら SPA のルーターで切り替える（ページを読み直さない）。
  // 別サイトなら普通に遷移する。
  // -------------------------------------------------------------------
  openURL: async (msg) => {
    if (!msg.url) throw new Error("url がありません");

    let target;
    try {
      target = new URL(msg.url);
    } catch (e) {
      throw new Error("url が不正です: " + msg.url);
    }

    const current = new URL(location.href);

    // 既に同じ動画を開いているなら、再生だけする
    const sameVideo =
      current.origin === target.origin &&
      current.pathname === target.pathname &&
      current.searchParams.get("v") === target.searchParams.get("v");
    if (sameVideo) {
      const v = video();
      if (v && v.paused) v.play().catch(() => {});
      return { ok: true, url: target.href, method: "already" };
    }

    // 別サイトなら SPA では切り替えられない
    if (current.origin !== target.origin) {
      location.assign(target.href);
      return { ok: true, url: target.href, method: "assign-cross-origin" };
    }

    // -------------------------------------------------------------------
    // 曲が実際に変わったかを <video> の currentSrc で見る。
    //
    // 以前は「URL が変わったか」で判定していたが、
    // pushState で URL を書き換えたのは自分自身なので**必ず通る**。
    // 実測でこうなっていた:
    //
    //   play いちごパフェが止まらない (XzLvfXMaP7c)
    //   openVideo ok: { method = spa }     ← 成功と報告
    //   metadata BE ME / Doul              ← 全然違う曲
    //
    // currentSrc は曲ごとに変わる blob URL なので、
    // 中身が切り替わったかを確かめられる。
    // -------------------------------------------------------------------
    const before = (() => {
      const v = video();
      return v ? v.currentSrc || v.src || "" : "";
    })();

    const changed = async (waitMs) => {
      const deadline = Date.now() + waitMs;
      while (Date.now() < deadline) {
        await new Promise(r => setTimeout(r, 150));
        const v = video();
        const now = v ? v.currentSrc || v.src || "" : "";
        if (now && now !== before) return true;
      }
      return false;
    };

    // 1. ページのルーターに拾わせる。
    //    YouTube のルーターは <a> のクリックを横取りするので、
    //    アンカーを作って本物のクリックを送る。
    //    pushState + popstate では反応しないことがある。
    try {
      const anchor = document.createElement("a");
      anchor.href = target.href;
      anchor.style.display = "none";
      (document.querySelector("ytmusic-app") || document.body).appendChild(anchor);
      anchor.click();
      anchor.remove();

      if (await changed(2500)) {
        return { ok: true, url: target.href, method: "spa" };
      }
    } catch (e) {
      // 次の手段へ
    }

    // 2. 効かなければ普通に遷移する。こちらは確実。
    location.assign(target.href);
    return { ok: true, url: target.href, method: "assign" };
  },
};

browser.runtime.onMessage.addListener((msg) => {
  if (!msg || typeof msg !== "object") return;

  const handler = commands[msg.type];
  if (!handler) {
    return Promise.reject(new Error("unknown content command: " + msg.type));
  }
  try {
    return Promise.resolve(handler(msg));
  } catch (e) {
    return Promise.reject(e);
  }
});

// ---------------------------------------------------------------------------
// 自発的な通知
//
// rev.20 では最小限。再生状態の変化だけを知らせる。
// 曲情報は MediaSessionDelegate 経由でネイティブに届いているので、
// ここで二重に送る必要はない。
// ---------------------------------------------------------------------------

function watchVideo() {
  const video = document.querySelector("video");
  if (!video || video.dataset.kotoneWatched === "1") return;
  video.dataset.kotoneWatched = "1";

  // 再生位置を定期的に知らせる。
  //
  // MediaSession の positionState は状態変化時にしか飛んでこないため、
  // それだけではネイティブ側の再生バーが曲の途中で止まってしまう。
  // timeupdate は 1 秒に 4 回ほど発火するので間引いて送る。
  let lastSent = 0;
  video.addEventListener("timeupdate", () => {
    const now = Date.now();
    if (now - lastSent < 900) return;
    lastSent = now;
    browser.runtime.sendMessage({
      type: "video",
      event: "timeupdate",
      currentTime: video.currentTime,
      duration: isFinite(video.duration) ? video.duration : null,
      paused: video.paused,
    });
  });

  for (const ev of ["play", "pause", "ended"]) {
    video.addEventListener(ev, () => {
      browser.runtime.sendMessage({
        type: "video",
        event: ev,
        currentTime: video.currentTime,
        duration: isFinite(video.duration) ? video.duration : null,
      });
    });
  }
  console.log("[kotone] video element watched");
}

// SPA なので <video> は後から現れる。出現を待つ。
const observer = new MutationObserver(() => watchVideo());
observer.observe(document.documentElement, { childList: true, subtree: true });
watchVideo();
