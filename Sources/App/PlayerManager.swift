//
//  PlayerManager.swift
//  Kotone — ViviMusic の Views が使う再生インタフェースの Gecko 実装
//
//  ⚠️ ViviMusic 由来ではなく本プロジェクトの新規実装。
//     ViviMusic の Playback/PlayerManager.swift（AVPlayer + 自前 InnerTube）は
//     65 秒問題の当事者だったので取り込んでいない。
//     API だけ同じにして、中身を Gecko に差し替える。
//
//  ---------------------------------------------------------------------
//  読み取りと操作で経路が違う
//
//    読み取り  MediaSessionDelegate  → タイトル / アーティスト / アルバム /
//                                      アートワーク / 再生位置 / 長さ / 状態
//    操作      KotoneHTTPBridge      → play / pause / next / seek / openVideo
//
//  MediaSession は Gecko がページから拾って流してくるので、
//  Kotone が何もしなくても最新の状態が届く。
//  一方 Swift からページを操作する経路は HTTP ブリッジしかない
//  （正規のメッセージングはペイロードが空になる。KotoneBridge 冒頭参照）。
//  ---------------------------------------------------------------------
//
//  ---------------------------------------------------------------------
//  シグネチャは ViviMusic の PlayerManager に揃えてある。
//
//  Views/ が `await player.play(...)` の形で呼ぶ 6 メソッドは async にした。
//  実測した呼び出し箇所:
//    play(10) setQueue(3) shufflePlay(2) next(2) skip(1) previous(1)
//
//  RepeatMode は Views から直接参照されていない（cycleRepeatMode 経由のみ）
//  ため、ViviMusic のようなネストではなくトップレベルで宣言している。
//  ---------------------------------------------------------------------
//
//  ログには層が分かる接頭辞を付ける。
//    [PM]      PlayerManager 自身
//    [PM→web]  ページへの操作
//    [web→PM]  MediaSession からの反映
//

import Combine
import Foundation
import GeckoView

enum RepeatMode: String, CaseIterable, Codable {
    case off
    case one
    case all

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    /// PlayerView が使う。ViviMusic の元実装と同じ名前・同じ意味。
    var iconName: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var isActive: Bool { self != .off }
}

@MainActor
final class PlayerManager: ObservableObject {

    static let shared = PlayerManager()

    // MARK: - Views が読む状態

    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isShuffled = false
    @Published var lastErrorMessage: String?

    /// ローカルファイル再生。Gecko 構成では未対応。
    @Published private(set) var isPlayingLocal = false

    // スリープタイマー
    @Published private(set) var isSleepTimerActive = false
    @Published private(set) var sleepTimerEndDate: Date?
    @Published private(set) var sleepAtEndOfTrack = false
    private var sleepTimer: Timer?

    private let log = MeasurementLog.shared
    private var bridge: KotoneHTTPBridge { .shared }

    /// 再生開始は Gecko のセッションに URL を渡して行う。
    ///
    /// ------------------------------------------------------------------
    /// 当初は content.js の location.assign() で遷移させていたが、
    /// GeckoSession.load() の方が素直で確実。
    ///
    ///   * 拡張機能の注入タイミングに依存しない
    ///   * ブラウザ UI が既に使っている実証済みの経路
    ///   * content script が未注入の状態でも曲を開始できる
    ///
    /// 一方 play / pause / seek / next は「ページ内の操作」なので
    /// 引き続き HTTP ブリッジを使う。URL 遷移では実現できない。
    ///
    /// BrowserViewController.startSession() が設定する。
    /// ------------------------------------------------------------------
    weak var session: GeckoSession?

    private init() {}

    // MARK: - 再生

    func play(song: Song, queue newQueue: [Song]? = nil) async {
        log.append(.player, "[PM] play \(song.title) (\(song.id))")
        isLoading = true
        currentSong = song

        if let newQueue, !newQueue.isEmpty {
            queue = newQueue
            currentIndex = newQueue.firstIndex(where: { $0.id == song.id }) ?? 0
        } else if let index = queue.firstIndex(where: { $0.id == song.id }) {
            currentIndex = index
        } else {
            queue = [song]
            currentIndex = 0
        }

        open(song)
    }

    /// `Song.id` から再生する URL を決める。
    ///
    /// ------------------------------------------------------------------
    /// **URL が渡されたら、そのまま使う。**
    ///
    /// 以前は videoId を取り出して `music.youtube.com/watch?v=…` に
    /// 組み立て直していたが、その必要はない。
    /// 受け取った URL をそのまま開けば、ページ側が再生してくれる。
    ///
    /// 書き換えると失うものもある。
    ///   * `m.youtube.com` の URL を渡されたのに音楽版へ飛ばしてしまう
    ///   * `t=` などのクエリが落ちる
    ///   * Music カタログ外の動画が `music.youtube.com` で開けない
    ///
    /// 素の videoId が来たときだけ、URL を組み立てる。
    /// ------------------------------------------------------------------
    static func playbackURL(for raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 既に URL ならそのまま
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return text
        }
        // ホストから始まる形（youtu.be/… など）
        if text.contains("/"), text.contains(".") {
            return "https://" + text
        }
        // 素の videoId
        return "https://music.youtube.com/watch?v=" + text
    }

    /// URL から videoId を取り出す。ページ内遷移に使う。
    ///
    /// 対応する形:
    ///   6qkUHaRXvtE                                    そのまま
    ///   https://youtu.be/6qkUHaRXvtE?si=…              パスの先頭
    ///   https://www.youtube.com/watch?v=…&t=10         クエリ v
    ///   https://music.youtube.com/watch?v=…&list=…     クエリ v（list も拾う）
    ///   https://www.youtube.com/shorts/…               パスの末尾
    static func extractVideoID(from raw: String) -> (id: String, playlistID: String?) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("/") || text.contains("?") else {
            return (text, nil)   // 素の videoId
        }
        guard let components = URLComponents(string: text) else { return (text, nil) }

        let items = components.queryItems ?? []
        let list = items.first { $0.name == "list" }?.value

        if let v = items.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return (v, list)
        }

        let segments = components.path.split(separator: "/").map(String.init)
        if let last = segments.last, !last.isEmpty, last != "watch" {
            return (last, list)
        }
        return (text, list)
    }

    // ------------------------------------------------------------------
    // 遷移の直列化
    //
    // 実測（rev.47）で、`session.load()` を短時間に何度も呼ぶと
    // **以降の遷移が一切始まらなくなる**（page start が来ない）。
    //
    //   20:30:56.277  music.youtube.com へ戻した  ← 4 回連続で発火
    //   20:32:54.875  [PM→web] load …            ← 以降 page start が来ない
    //
    // 直前の遷移が終わる前に次を投げると Gecko 側で詰まるとみられる。
    // 同じ URL の連打も無駄なので弾く。
    // ------------------------------------------------------------------

    /// 進行中の遷移。`onPageStop` で解除する。
    private var pendingNavigation: String?
    private var navigationStartedAt: Date?

    /// `BrowserViewController.onPageStop` から呼ぶ。
    func navigationDidFinish(success: Bool) {
        if let url = pendingNavigation {
            log.append(.player, "[PM] 遷移完了 success=\(success) \(url)")
        }
        pendingNavigation = nil
        navigationStartedAt = nil
        isLoading = false
    }

    /// 直前の遷移が終わっているか。長く終わらない場合は諦めて次を通す。
    private var canNavigate: Bool {
        guard pendingNavigation != nil, let started = navigationStartedAt else { return true }
        // 15 秒経っても page stop が来ないなら、取りこぼしとみなす
        return Date().timeIntervalSince(started) > 15
    }

    /// 曲を開く。
    ///
    /// 渡された URL をそのまま開く。ページ側が再生する。
    /// 拡張機能が繋がっていればページ内遷移（読み直しなし）、
    /// 繋がっていなければ `GeckoSession.load()`。
    private func open(_ song: Song) {
        let url = Self.playbackURL(for: song.id)
        if url != song.id {
            log.append(.player, "[PM] 再生 URL: \(url)")
        }

        // ------------------------------------------------------------
        // 拡張機能が繋がっていれば、そちらでページ内遷移させる。
        //
        // session.load() は毎回ページ全体を読み直すため
        //   * 数秒かかる
        //   * 子プロセスが増える（実測で 1 曲ごとに 1〜3 個）
        //   * 連続で呼ぶと以降の遷移が詰まる（rev.47 で実測）
        //
        // YouTube は SPA なので、ページ内で切り替えれば
        // 読み直しが起きず、これらを全部避けられる。
        // ------------------------------------------------------------
        if bridge.isExtensionConnected {
            Task { @MainActor in
                do {
                    let result = try await self.bridge.openURL(url)
                    self.log.append(.player, "[PM→web] openVideo ok: \(result ?? "nil")")
                    self.lastErrorMessage = nil
                } catch {
                    // 拡張機能側は、YouTube 以外を開いていても
                    // そのタブを書き換えて目的の URL に行くので、
                    // ここに来るのは拡張機能自体が応答しないとき。
                    // 最後の手段としてセッションを直接動かす。
                    self.log.append(
                        .player,
                        "[PM] 拡張機能が応答しません（\(error.localizedDescription)）。"
                            + "セッションで直接遷移します"
                    )
                    self.loadDirectly(url)
                }
            }
            return
        }

        // 拡張機能が未接続のときは、ページ全体を読み直す。
        // 起動直後など content script がまだ入っていない場合。
        loadDirectly(url)
    }

    /// `GeckoSession.load()` で直接遷移する。連打を弾く守りを通す。
    private func loadDirectly(_ url: String) {
        guard let session else {
            log.append(.error, "[PM] session も拡張機能も使えません")
            return
        }
        if pendingNavigation == url {
            log.append(.player, "[PM] 同じ URL の遷移が進行中。無視")
            return
        }
        guard canNavigate else {
            log.append(.player, "[PM] 前の遷移が未完了。無視: \(url)")
            return
        }
        pendingNavigation = url
        navigationStartedAt = Date()
        session.load(url)
        log.append(.player, "[PM→web] load \(url)")
    }

    func togglePlayPause() {
        log.append(.player, "[PM] togglePlayPause (isPlaying=\(isPlaying))")
        send("toggle") { try await self.bridge.togglePlayPause() }
    }

    func resume() {
        log.append(.player, "[PM] resume")
        send("play") { try await self.bridge.play() }
    }

    func pause() {
        log.append(.player, "[PM] pause")
        send("pause") { try await self.bridge.pause() }
    }

    func next() async {
        log.append(.player, "[PM] next")
        send("next") { try await self.bridge.next() }
    }

    func previous() async {
        log.append(.player, "[PM] previous")
        send("previous") { try await self.bridge.previous() }
    }

    func seek(to position: TimeInterval) {
        log.append(.player, String(format: "[PM] seek to %.1f", position))
        currentTime = position
        send("seek") { try await self.bridge.seek(to: position) }
    }

    /// キュー内の任意の曲へ。ページのキューとは独立なので曲を開き直す。
    func skip(to index: Int) async {
        guard queue.indices.contains(index) else {
            log.append(.error, "[PM] skip: 範囲外 \(index) / \(queue.count)")
            return
        }
        log.append(.player, "[PM] skip to \(index)")
        await play(song: queue[index], queue: queue)
    }

    // MARK: - キュー

    func setQueue(_ songs: [Song], startAt index: Int = 0) async {
        log.append(.player, "[PM] setQueue \(songs.count) 曲, startAt=\(index)")
        queue = songs
        guard songs.indices.contains(index) else { return }
        currentIndex = index
        await play(song: songs[index], queue: songs)
    }

    func shufflePlay(_ songs: [Song]) async {
        guard !songs.isEmpty else { return }
        log.append(.player, "[PM] shufflePlay \(songs.count) 曲")
        let shuffled = songs.shuffled()
        isShuffled = true
        await setQueue(shuffled, startAt: 0)
    }

    func addToQueue(_ song: Song) {
        queue.append(song)
        log.append(.player, "[PM] addToQueue \(song.title) (計 \(queue.count))")
    }

    func playNext(_ song: Song) {
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(song, at: insertAt)
        log.append(.player, "[PM] playNext \(song.title) at \(insertAt)")
    }

    func removeFromQueue(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
        if currentIndex >= queue.count { currentIndex = max(0, queue.count - 1) }
        log.append(.player, "[PM] removeFromQueue (残り \(queue.count))")
    }

    func moveQueueItems(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        log.append(.player, "[PM] moveQueueItems")
    }

    /// シャッフル。ページ側のボタンを押す。
    ///
    /// ViviMusic では Kotone 側でキューを並べ替えていたが、
    /// Gecko 構成では**キューを持っているのはページ側**なので、
    /// ページのシャッフルボタンを押さないと実際には効かない。
    /// シャッフル。ページ側のボタンを押し、**結果で状態を決める**。
    ///
    /// 先に Kotone 側を反転させると、ページが応じなかったときに
    /// 表示だけが切り替わって実態とずれる。
    func toggleShuffle() {
        Task { @MainActor in
            guard bridge.isExtensionConnected else {
                log.append(.error, "[PM] 拡張機能が接続していません（toggleShuffle）")
                return
            }
            do {
                let result = try await bridge.toggleShuffle()
                if let dict = result as? [String: Any],
                   let after = dict["after"] as? Bool {
                    isShuffled = after
                    log.append(.player, "[PM] shuffle -> \(after)")
                } else {
                    // 状態を読めない場合だけ、押した前提で反転する
                    isShuffled.toggle()
                    log.append(.player, "[PM] shuffle -> \(isShuffled)（状態は未確認）")
                }
                lastErrorMessage = nil
            } catch {
                log.append(.error, "[PM→web] toggleShuffle 失敗: \(error.localizedDescription)")
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// ループ。ページ側のボタンを押して状態を合わせる。
    ///
    /// ページのボタンは押すたびに off → all → one → off と巡回する。
    /// Kotone 側で次の状態を決め、それをページに指示する
    /// （`setRepeat`）ことで、両者のずれを防ぐ。
    /// ループ。ページ側のボタンを押し、**結果で状態を決める**。
    func cycleRepeatMode() {
        let requested = repeatMode.next
        Task { @MainActor in
            guard bridge.isExtensionConnected else {
                log.append(.error, "[PM] 拡張機能が接続していません（setRepeat）")
                return
            }
            do {
                let result = try await bridge.setRepeat(requested.rawValue)
                if let dict = result as? [String: Any],
                   let mode = dict["mode"] as? String,
                   let parsed = RepeatMode(rawValue: mode) {
                    repeatMode = parsed
                    log.append(.player, "[PM] repeatMode -> \(mode)")
                } else {
                    repeatMode = requested
                    log.append(.player, "[PM] repeatMode -> \(requested.rawValue)（状態は未確認）")
                }
                lastErrorMessage = nil
            } catch {
                log.append(.error, "[PM→web] setRepeat 失敗: \(error.localizedDescription)")
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// ページ側のループ状態を読み取って Kotone 側に反映する。
    /// 曲を開いた直後など、ページが独自に状態を持っている場合に使う。
    func syncRepeatModeFromPage() {
        Task { @MainActor in
            guard bridge.isExtensionConnected else { return }
            guard let result = try? await bridge.request("repeatState"),
                  let dict = result as? [String: Any] else { return }

            // mode が nil のときは「読めなかった」であって off ではない。
            // 以前は読めないと必ず "off" が返る実装で、
            // ページを開くたびに Kotone 側の表示を off に潰していた。
            if let mode = dict["mode"] as? String,
               let parsed = RepeatMode(rawValue: mode) {
                if parsed != repeatMode {
                    repeatMode = parsed
                    log.append(.player, "[PM] repeatMode をページから同期 -> \(mode)")
                }
            } else {
                log.append(.player, "[PM] ページのループ状態を読めませんでした")
            }

            if let shuffle = dict["shuffle"] as? Bool, shuffle != isShuffled {
                isShuffled = shuffle
                log.append(.player, "[PM] shuffle をページから同期 -> \(shuffle)")
            }
        }
    }

    // MARK: - 再生位置
    //
    // ------------------------------------------------------------------
    // 再生バーがページとずれていた原因。
    //
    // currentTime は MediaSession の positionState でしか更新しておらず、
    // これは**状態変化時にしか飛んでこない**。曲の途中では止まったままになる。
    //
    // 対策は 2 段構え。
    //   1. content.js が timeupdate を約 1 秒おきに送る（実測値）
    //   2. その間はローカルのタイマーで補間する（見た目の滑らかさ）
    //
    // 実測値が来たら必ずそちらで上書きするので、ずれは蓄積しない。
    // ------------------------------------------------------------------

    private var tickTimer: Timer?
    private var lastPositionUpdate: Date?

    /// 拡張機能からのイベント。BrowserViewController が中継する。
    func applyBridgeEvent(_ payload: [String: Any]) {
        guard payload["type"] as? String == "video" else { return }
        let event = payload["event"] as? String ?? ""

        if let time = doubleValue(payload["currentTime"]) {
            currentTime = time
            lastPositionUpdate = Date()
        }
        if let total = doubleValue(payload["duration"]), total > 0 {
            duration = total
        }

        switch event {
        case "play":
            applyPlaybackState(isPlaying: true)
        case "pause", "ended":
            applyPlaybackState(isPlaying: false)
        default:
            break   // timeupdate は位置だけ
        }
    }

    /// JSON 由来の数値は String で来ることがある（`currentTime = "3.224479"`）。
    private func doubleValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let text = raw as? String { return Double(text) }
        return nil
    }

    /// 実測値の間を補間する。
    private func startTicking() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, let last = self.lastPositionUpdate else { return }
                let elapsed = Date().timeIntervalSince(last)
                // 実測が途絶えたら補間もやめる（曲の終わりや遷移中）
                guard elapsed < 5 else { return }
                let estimated = self.currentTime + 0.25
                if self.duration <= 0 || estimated <= self.duration {
                    self.currentTime = estimated
                }
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - スリープタイマー

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = end
        isSleepTimerActive = true
        sleepAtEndOfTrack = false
        log.append(.player, "[PM] sleepTimer \(minutes) 分")

        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60),
                                          repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.log.append(.player, "[PM] sleepTimer 発火")
                self?.pause()
                self?.cancelSleepTimer()
            }
        }
    }

    func setSleepAtEndOfTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
        isSleepTimerActive = true
        log.append(.player, "[PM] sleepAtEndOfTrack")
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndDate = nil
        isSleepTimerActive = false
        sleepAtEndOfTrack = false
    }

    // MARK: - ページからの反映
    //
    // BrowserViewController の MediaSessionDelegate から呼ばれる。

    func applyMetadata(title: String?, artist: String?, album: String?, artworkURL: String?) {
        // 遷移中は、ページのタイトルがそのまま曲名として流れてくる。
        //
        //   08:54:23  metadata title = 七月、繋いだ星に（feat. nayuta） | YouTube Music
        //             artist =   album =   art =
        //
        // ロック画面が一瞬これを表示してしまうので捨てる。
        // 正しい曲情報は数百 ms 後に改めて届く。
        let looksLikePageTitle =
            (title?.hasSuffix("| YouTube Music") ?? false)
            || (title?.hasSuffix("- YouTube Music") ?? false)
        if looksLikePageTitle,
           (artist ?? "").isEmpty,
           (artworkURL ?? "").isEmpty {
            log.append(.player, "[web→PM] 遷移中のページタイトルを無視")
            return
        }

        isLoading = false

        // videoId はここでは分からない。既存のキューから題名で照合する。
        // 合致しなければ、表示用に暫定の Song を作る。
        if let title, !title.isEmpty {
            if let match = queue.first(where: { $0.title == title }) {
                currentSong = match
                currentIndex = queue.firstIndex(where: { $0.id == match.id }) ?? currentIndex
            } else {
                currentSong = Song(
                    id: currentSong?.id ?? "web:\(title)",
                    title: title,
                    artist: artist ?? "",
                    album: album,
                    albumID: nil,
                    durationSeconds: duration > 0 ? Int(duration) : nil,
                    thumbnailURL: artworkURL,
                    artistID: nil
                )
            }
        }
        log.append(.player, "[web→PM] metadata \(title ?? "-") / \(artist ?? "-")")
    }

    func applyPlaybackState(isPlaying playing: Bool) {
        if playing {
            lastPositionUpdate = Date()
            startTicking()
        } else {
            stopTicking()
        }
        isPlaying = playing
        if playing { isLoading = false }
        log.append(.player, "[web→PM] \(playing ? "playing" : "paused")")
    }

    func applyPosition(_ position: TimeInterval, duration newDuration: TimeInterval, rate: Double) {
        lastPositionUpdate = Date()
        guard position.isFinite, position >= 0 else { return }
        currentTime = position
        if newDuration.isFinite, newDuration > 0 { duration = newDuration }

        // 曲末尾でのスリープ指定
        if sleepAtEndOfTrack, duration > 0, position >= duration - 1 {
            log.append(.player, "[PM] sleepAtEndOfTrack 発火")
            pause()
            cancelSleepTimer()
        }
    }

    func applyPlaybackNone() {
        isPlaying = false
        log.append(.player, "[web→PM] playback none")
    }

    // MARK: - 送信の共通処理

    /// YouTube に戻す。
    ///
    /// 再生や一時停止はページ内の操作なので、別サイトに居ると届かない。
    /// 曲を指定しない復帰なので、行き先は音楽版のホームでよい。
    private func ensureOnMusicPage() {
        guard let session else { return }
        let url = "https://music.youtube.com/"
        // 失敗したコマンドの数だけ呼ばれるので、必ず間引く。
        // 実測では 4 回連続で発火して遷移が詰まった。
        guard pendingNavigation != url, canNavigate else { return }
        pendingNavigation = url
        navigationStartedAt = Date()
        session.load(url)
        log.append(.player, "[PM] music.youtube.com へ戻した")
    }

    private func send(_ label: String, _ action: @escaping () async throws -> Any?) {
        guard bridge.isExtensionConnected else {
            let message = "ブリッジ未接続のため操作できません (\(label))"
            lastErrorMessage = message
            log.append(.error, "[PM→web] \(message)")
            return
        }
        Task { @MainActor in
            do {
                let result = try await action()
                log.append(.player, "[PM→web] \(label) ok: \(String(describing: result))")
                lastErrorMessage = nil
            } catch {
                let message = "\(label) 失敗: \(error.localizedDescription)"
                lastErrorMessage = message
                log.append(.error, "[PM→web] \(message)")

                // ページを離れていると content script が居らず必ず失敗する。
                // 実測: 「YouTube のページを開いていません」
                // 測定用ブラウザでは AMO などへ自由に遷移できるため起きる。
                // 最終形（Gecko を背面に固定）では起きないが、
                // 起きたときに自力で復帰できるようにしておく。
                // 再生や一時停止は「今開いているページ」に対する操作なので、
                // ページを離れていると届かない。YouTube に戻しておく。
                //
                // openVideo（= openURL）は自前で目的の URL へ遷移するため、
                // ここで戻すと指定した曲が失われる。除外する。
                let leftThePage = message.contains("YouTube のページを開いていません")
                if leftThePage, label != "openVideo" {
                    ensureOnMusicPage()
                }
            }
            isLoading = false
        }
    }
}
