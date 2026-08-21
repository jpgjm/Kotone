//
//  BrowserViewController.swift
//  Kotone — Phase 1 測定用の最小ブラウザ
//
//  目的は「使えるブラウザ」ではなく「測定できること」。
//  README の Phase 1 測定項目に対応する:
//
//    1. music.youtube.com で 65 秒を超えて連続再生できるか  ← 最重要
//    2. MediaSessionDelegate に曲情報が届くか
//    3. デスクトップ UA で iPad の表示が実用に耐えるか
//    4. ログインできるか
//    5. バックグラウンドで再生が継続するか
//    6. メモリ使用量
//
//  再生時間はストップウォッチではなく MediaSession の positionState を
//  そのまま記録する。ページ内の実再生位置なので、65 秒の壁を
//  超えたかどうかを客観的に判定できる。
//

import Foundation
import GeckoView
import UIKit

final class BrowserViewController: UIViewController {

    // MARK: - Gecko

    private let geckoView = GeckoView()
    private var session: GeckoSession?

    // MARK: - UI

    private let urlField = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private lazy var backButton = makeToolButton("chevron.backward", #selector(goBack))
    private lazy var forwardButton = makeToolButton("chevron.forward", #selector(goForward))
    private lazy var reloadButton = makeToolButton("arrow.clockwise", #selector(reloadPage))
    private lazy var desktopButton = makeToolButton("desktopcomputer", #selector(toggleDesktopMode))
    /// 音楽 UI へ戻る。設定画面の「ブラウザ画面を開く」と対になる導線。
    private lazy var backToMusicButton = makeToolButton("music.note.house", #selector(backToMusic))
    private lazy var addonButton = makeToolButton("puzzlepiece.extension", #selector(showAddons))
    private lazy var logButton = makeToolButton("list.bullet.rectangle", #selector(showLog))
    private lazy var diagButton = makeToolButton("checklist", #selector(showDiagnostics))

    // MARK: - State

    private var usesDesktopMode = true
    private var appliedUserAgentMode = -1
    private var appliedForcedMobile = false
    private var childProcessCount = 0
    private var didActivateAddons = false
    private let log = MeasurementLog.shared

    private static let homeURL = "https://music.youtube.com"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 自前のツールバーを持っているので、この画面ではナビゲーションバーを隠す。
        // 押した先（アドオン / 測定ログ / 診断）では表示する。
        navigationItem.largeTitleDisplayMode = .never

        setUpInterface()
        startSession()

        AddonController.shared.presenter = self
        // AddonController.shared.activate() はここでは呼ばない。
        // 最初のページが描画されてから接続する（理由は AddonController 参照）。

        // Gecko の子プロセス起動を記録する。
        // App Extension が実際に何個・どの種類で立ち上がっているかを見る。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChildProcessStart(_:)),
            name: Notification.Name("GeckoRuntime.ChildProcessDidStart"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenURL(_:)),
            name: .kotoneOpenURL,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 押した先の画面では戻るボタンが要るので表示に戻す。
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AddonController.shared.presenter = self
    }

    /// Gecko の子プロセス（= Reynard Helper.appex のインスタンス）が起動した
    @objc private func handleChildProcessStart(_ note: Notification) {
        let pid = (note.userInfo?["pid"] as? NSNumber)?.int32Value ?? -1
        let type = note.userInfo?["processType"] as? String ?? "?"
        childProcessCount += 1
        log.append(.info, "child process #\(childProcessCount) started — type=\(type) pid=\(pid)")
    }

    /// アドオン画面や設定ページからの遷移要求
    @objc private func handleOpenURL(_ note: Notification) {
        guard let url = note.userInfo?["url"] as? String else { return }
        DispatchQueue.main.async { self.load(url) }
    }

    // MARK: - Session

    /// Gecko の既定 pref を上書きする。セッションを開く前に呼ぶこと。
    ///
    /// ------------------------------------------------------------------
    /// ⚠️ 署名要求はここでは外せない。
    ///
    ///   modules/AppConstants.sys.mjs:115  MOZ_REQUIRE_SIGNING: true
    ///   modules/addons/AddonSettings.sys.mjs:32
    ///     if (AppConstants.MOZ_REQUIRE_SIGNING && !Cu.isInAutomation) {
    ///       makeConstant("REQUIRE_SIGNING", true);   // pref を読まない
    ///     }
    ///
    /// `greprefs.js:1246` は `xpinstall.signatures.required` を false に
    /// しているが、`defaults/pref/mobile.js:38` が true で上書きし、
    /// さらに `AppConstants` がコンパイル時に固定している。
    /// **pref をどう設定しても未署名 .xpi は入らない。**
    ///
    /// 自作アドオンは組み込み経路
    /// (`AddonManager.installBuiltinAddon`) で入れる。
    /// `KotoneBridge.installBuiltIn()` を参照。
    ///
    /// 以下の pref は害が無く、file:// からの取得を妨げないために残す。
    /// ------------------------------------------------------------------
    private func applyDefaultPrefs() {
        GeckoRuntime.setDefaultPrefs([
            "xpinstall.whitelist.required": false,
            "xpinstall.whitelist.fileRequest": true,

            // 自動再生を許可する。
            //
            // defaults/pref/mobile.js:33 が
            //   pref("media.geckoview.autoplay.request", true);
            // としており、自動再生の可否を embedder に問い合わせる作りになっている。
            // Kotone はその応答を実装していないため、URL を読み込んでも
            // 再生が始まらない。音楽アプリなので常に許可でよい。
            "media.geckoview.autoplay.request": false,
            "media.autoplay.default": 0,          // 0 = allowed
            "media.autoplay.blocking_policy": 0,
        ])
        log.append(.info, "default prefs applied")
    }

    private func startSession() {
        applyDefaultPrefs()

        let session = GeckoSession(settings: settings(for: Self.homeURL))
        session.progressDelegate = self
        session.promptDelegate = self
        session.navigationDelegate = self
        session.contentDelegate = self
        session.mediaSessionDelegate = self

        session.open()
        geckoView.session = session
        self.session = session

        // PlayerManager は再生開始をこのセッションへの URL 読み込みで行う。
        // 拡張機能に依存しない経路にしておく。
        PlayerManager.shared.session = session

        log.append(.info, "session opened — Gecko \(GeckoRuntime.version)")
        load(Self.homeURL)
    }

    /// UA は URL によって変わる（UserAgentPolicy 参照）。
    /// AMO と moz-extension:// では Android UA が強制される。
    private func settings(for url: String) -> GeckoSessionSettings {
        UserAgentPolicy.settings(for: url, prefersDesktop: usesDesktopMode)
    }

    /// 遷移先に応じて UA を貼り替える。
    /// これをやらないと AMO で「Firefox へ追加」ボタンが出ず、
    /// アドオンを 1 つもインストールできない。
    private func applyUserAgent(for url: String) {
        let config = UserAgentPolicy.configuration(for: url, prefersDesktop: usesDesktopMode)
        guard config.mode != appliedUserAgentMode || config.forcedMobile != appliedForcedMobile else {
            return
        }
        appliedUserAgentMode = config.mode
        appliedForcedMobile = config.forcedMobile
        session?.updateSettings(settings(for: url))
        log.append(
            .info,
            "user agent -> \(config.mode == 1 ? "desktop" : "mobile")"
                + (config.forcedMobile ? " (このサイトでは強制)" : "")
        )
    }

    private func load(_ text: String) {
        guard let url = normalizedURL(from: text) else { return }
        urlField.text = url
        applyUserAgent(for: url)
        session?.load(url)
        log.append(.nav, "load \(url)")
    }

    private func normalizedURL(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        // about: / moz-extension: などスキームだけの形も URL として扱う。
        // rev.15 では about:blank が検索クエリに化けていた。
        for scheme in ["about:", "moz-extension:", "data:", "javascript:", "resource:", "chrome:"]
        where trimmed.hasPrefix(scheme) {
            return trimmed
        }
        if trimmed.contains(" ") || !trimmed.contains(".") {
            let q = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? trimmed
            return "https://duckduckgo.com/?q=\(q)"
        }
        return "https://\(trimmed)"
    }

    // MARK: - Actions

    @objc private func goBack() { session?.goBack() }
    @objc private func goForward() { session?.goForward() }
    @objc private func reloadPage() { session?.reload() }

    @objc private func toggleDesktopMode() {
        usesDesktopMode.toggle()
        session?.updateSettings(settings(for: urlField.text ?? Self.homeURL))
        session?.reload()
        updateDesktopButton()
        log.append(.info, "user agent -> \(usesDesktopMode ? "desktop" : "mobile")")
    }

    /// 最初のページが描画されてから AddonRuntime に接続する。
    /// 起動直後に接続すると Gecko の JS ランタイム初期化前に
    /// list() が飛んで SIGSEGV になる（rev.17 のクラッシュ）。
    private func activateAddonsIfReady() {
        guard !didActivateAddons else { return }
        didActivateAddons = true
        AddonController.shared.presenter = self
        AddonController.shared.activate()

        // WebExtension ↔ Swift ブリッジ。
        // AddonRuntime と同じく、Gecko が立ち上がってから listener を張る。
        KotoneBridge.shared.delegate = self
        KotoneBridge.shared.activate()

        // ★ こちらが主経路。
        // 正規のメッセージング（connectNative / sendNativeMessage）は
        // 構造化クローンの復元が空を返すため使えない（KotoneBridge 冒頭参照）。
        // ポートとトークンは拡張機能に渡す必要がある（下記 handoff）。
        KotoneHTTPBridge.shared.delegate = self
        if KotoneHTTPBridge.shared.start() {
            let http = KotoneHTTPBridge.shared
            log.append(.bridge, "HTTP ブリッジ起動: 127.0.0.1:\(http.port)")

            // ポートとトークンは scripts/AddGecko.sh が生成した
            // kotone-config.js を両者が読むことで揃えている。
            // 実行時の受け渡し経路は不要。
        }

        Task { @MainActor in
            await AddonController.shared.refresh()

            // 組み込みアドオンはアプリの再起動で消える。
            // ログ実測: 前回入れたのに次回起動時は「installed addons: (なし)」。
            // GeckoView は起動のたびに ensureBuiltIn を呼ぶ設計なので、
            // こちらも毎回呼ぶ。バージョンが同じなら何もしない（冪等）。
            let message = await AddonController.shared.installBridge()
            self.log.append(.bridge, "起動時の組み込み: \(message.replacingOccurrences(of: "\n", with: " "))")
        }
    }

    @objc private func backToMusic() {
        NotificationCenter.default.post(name: .kotoneShowMusicUI, object: nil)
    }

    @objc private func showAddons() {
        navigationController?.pushViewController(AddonsViewController(), animated: true)
    }

    @objc private func showLog() {
        navigationController?.pushViewController(MeasurementLogViewController(), animated: true)
    }

    @objc private func showDiagnostics() {
        navigationController?.pushViewController(DiagnosticsViewController(), animated: true)
    }

    private func updateDesktopButton() {
        desktopButton.setImage(
            UIImage(systemName: usesDesktopMode ? "desktopcomputer" : "iphone"),
            for: .normal
        )
    }

    // MARK: - Layout

    private func makeToolButton(_ symbol: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    private func setUpInterface() {
        urlField.borderStyle = .roundedRect
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .go
        urlField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        urlField.delegate = self

        progressView.progress = 0
        progressView.alpha = 0

        let bar = UIStackView(arrangedSubviews: [
            backToMusicButton, backButton, forwardButton, reloadButton, urlField,
            desktopButton, addonButton, logButton, diagButton,
        ])
        bar.axis = .horizontal
        bar.spacing = 4
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        for v in [bar, progressView, geckoView] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            progressView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            geckoView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            geckoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            geckoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            geckoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateDesktopButton()
    }
}

// MARK: - UITextFieldDelegate

extension BrowserViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        load(textField.text ?? "")
        return true
    }
}

// MARK: - ProgressDelegate

extension BrowserViewController: ProgressDelegate {
    func onPageStart(session: GeckoSession, url: String) {
        log.append(.nav, "page start")
        UIView.animate(withDuration: 0.15) { self.progressView.alpha = 1 }
    }

    func onProgressChange(session: GeckoSession, progress: Int) {
        progressView.setProgress(Float(progress) / 100, animated: true)
    }

    func onPageStop(session: GeckoSession, success: Bool) {
        log.append(success ? .nav : .error, "page stop success=\(success)")
        PlayerManager.shared.navigationDidFinish(success: success)
        if success {
            activateAddonsIfReady()
            // ページを開き直すとループ状態がページ側の値に戻るので、
            // Kotone 側の表示を実態に合わせる。
            PlayerManager.shared.syncRepeatModeFromPage()
        }
        UIView.animate(withDuration: 0.25) { self.progressView.alpha = 0 } completion: { _ in
            self.progressView.setProgress(0, animated: false)
        }
    }
}

// MARK: - NavigationDelegate

extension BrowserViewController: NavigationDelegate {
    func onLocationChange(session: GeckoSession, url: String?, permissions: [ContentPermission]) {
        urlField.text = url
        // リダイレクトで AMO に飛んだ場合にも UA を合わせる
        if let url { applyUserAgent(for: url) }
    }

    func onCanGoBack(session: GeckoSession, canGoBack: Bool) {
        backButton.isEnabled = canGoBack
    }

    func onCanGoForward(session: GeckoSession, canGoForward: Bool) {
        forwardButton.isEnabled = canGoForward
    }
}

// MARK: - ContentDelegate

extension BrowserViewController: ContentDelegate {
    func onTitleChange(session: GeckoSession, title: String) {
        self.title = title.isEmpty ? "Kotone" : title
    }

    func onFirstContentfulPaint(session: GeckoSession) {
        log.append(.info, "first contentful paint — \(MeasurementLog.memoryFootprint())")
        activateAddonsIfReady()
    }

    /// 子プロセスが落ちたときに気づけるようにする。
    /// JIT 無しだと SpiderMonkey が重く、メモリ不足で kill される可能性がある。
    func onCrash(session: GeckoSession) {
        log.append(.error, "*** content process CRASHED ***")
    }

    func onKill(session: GeckoSession) {
        log.append(.error, "*** content process KILLED (メモリ不足の可能性) ***")
    }
}

// MARK: - MediaSessionDelegate
//
// Phase 1 の測定 1 と 2 はここで取る。
// positionState はページ内の実再生位置なので、
// これが 65 秒を超えて伸び続ければ「65 秒の壁を越えた」と判定できる。

extension BrowserViewController: MediaSessionDelegate {
    func onActivated(session: GeckoSession) {
        log.append(.media, "media session activated")
        log.resetPlaybackWatch()
    }

    func onDeactivated(session: GeckoSession) {
        log.append(.media, "media session deactivated")
    }

    func onMetadata(session: GeckoSession, metadata: MediaSessionMetadata) {
        // PlayerManager の読み取り側はここが唯一の供給源。
        PlayerManager.shared.applyMetadata(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            artworkURL: metadata.artworkUrl
        )
        log.append(.media, """
            metadata
              title  = \(metadata.title ?? "-")
              artist = \(metadata.artist ?? "-")
              album  = \(metadata.album ?? "-")
              art    = \(metadata.artworkUrl ?? "-")
            """)
    }

    func onPlaybackPlaying(session: GeckoSession) {
        log.append(.media, "playing")
        PlayerManager.shared.applyPlaybackState(isPlaying: true)
    }

    func onPlaybackPaused(session: GeckoSession) {
        log.append(.media, "paused")
        PlayerManager.shared.applyPlaybackState(isPlaying: false)
    }

    func onPlaybackNone(session: GeckoSession) {
        log.append(.media, "playback none")
        PlayerManager.shared.applyPlaybackNone()
    }

    func onFeatures(session: GeckoSession, features: MediaSessionFeatures) {
        var names: [String] = []
        if features.contains(.play) { names.append("play") }
        if features.contains(.pause) { names.append("pause") }
        if features.contains(.stop) { names.append("stop") }
        if features.contains(.seekTo) { names.append("seekTo") }
        if features.contains(.nextTrack) { names.append("next") }
        if features.contains(.prevTrack) { names.append("prev") }
        log.append(.media, "features: \(names.joined(separator: ", "))")
    }

    func onPositionState(session: GeckoSession, state: MediaSessionPositionState) {
        log.notePlaybackPosition(state.position, duration: state.duration, rate: state.playbackRate)
        PlayerManager.shared.applyPosition(
            state.position, duration: state.duration, rate: state.playbackRate
        )
    }
}


// MARK: - KotoneBridgeDelegate

extension BrowserViewController: KotoneBridgeDelegate {

    func bridgeDidConnect(_ bridge: KotoneBridge) {
        log.append(.bridge, "connected — extension=\(bridge.extensionId ?? "?")")
    }

    func bridgeDidDisconnect(_ bridge: KotoneBridge) {
        log.append(.bridge, "disconnected")
    }

    func bridge(_ bridge: KotoneBridge, didReceiveEvent payload: [String: Any]) {
        let summary = payload.keys.sorted()
            .map { "\($0)=\(payload[$0] ?? "nil")" }
            .joined(separator: " ")
        log.append(.bridge, "event \(summary)")
    }

    func bridge(_ bridge: KotoneBridge, log message: String) {
        log.append(.bridge, message)
    }
}


// MARK: - KotoneHTTPBridgeDelegate

extension BrowserViewController: KotoneHTTPBridgeDelegate {

    func httpBridge(_ bridge: KotoneHTTPBridge, didReceiveEvent payload: [String: Any]) {
        // content.js からの通知。実体は payload の中。
        let body = (payload["payload"] as? [String: Any]) ?? payload

        // 再生位置はここが主な供給源。
        // MediaSession の positionState は状態変化時しか来ないため、
        // これが無いと再生バーが曲の途中で止まる。
        PlayerManager.shared.applyBridgeEvent(body)

        // timeupdate は 1 秒おきに来るのでログには出さない。
        if body["event"] as? String != "timeupdate" {
            let summary = body.keys.sorted()
                .map { "\($0)=\(body[$0] ?? "nil")" }
                .joined(separator: " ")
            log.append(.bridge, "HTTP event \(summary)")
        }
    }

    func httpBridge(_ bridge: KotoneHTTPBridge, log message: String) {
        log.append(.bridge, "HTTP: \(message)")
    }
}


// MARK: - PromptDelegate
//
// ------------------------------------------------------------------------
// これが無いと再生開始後にページ遷移できなくなる。
//
// 実測（rev.40）:
//   11:12:44  NAV  page stop success=true      ← 最後に成功した遷移
//   11:13:00       （再生開始）
//   11:13:43  NAV  load https://duckduckgo.com/…   ← page start が来ない
//   11:15:31  PLAYER [PM→web] load …               ← 来ない
//
// YouTube Music は再生中に beforeunload を張る。Gecko は離脱の可否を
// embedder に問い合わせ、応答があるまで遷移を保留する。
// PromptDelegate を設定していないと問い合わせが宙に浮き、
// **URL バーの文字だけ変わって遷移しない**状態になる。
//
// Kotone は Gecko を再生エンジンとして使うので、離脱確認は常に許可でよい。
// 他のプロンプト（alert / choice など）も自動で閉じる。
// ページに勝手なダイアログを出させないため、UI は一切出さない。
// ------------------------------------------------------------------------

extension BrowserViewController: PromptDelegate {

    func onPrompt(session: GeckoSession, request: PromptRequest) async -> PromptResponse? {
        switch request {
        case .button(let button):
            // beforeunload はここに来る。0 番目が肯定側（離脱する）。
            log.append(.nav, "prompt(button): \(button.message) → 0 を選択")
            return .button(0)

        case .alert(let alert):
            log.append(.nav, "prompt(alert): \(alert.message) → 閉じる")
            return nil

        default:
            // 入力系（text / auth / file / choice など）は UI を出さずに閉じる。
            // Kotone は Gecko を再生エンジンとして使うだけなので、
            // ページに勝手なダイアログを出させない。
            log.append(.nav, "prompt(その他) id=\(request.id) → 応答せず閉じる")
            return nil
        }
    }

    func onPromptDismiss(session: GeckoSession, promptId: String) {
        log.append(.nav, "prompt dismissed: \(promptId)")
    }
}
