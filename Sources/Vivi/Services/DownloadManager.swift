//
//  DownloadManager.swift
//  ViviMusic
//
//  曲をローカルに保存してオフライン再生を可能にする。
//  保存先: <Documents>/Downloads/<videoId>.m4a
//
//  取得は StreamFetcher に任せる。
//  googlevideo は「Range ヘッダ付きの小分けリクエスト」しか受け付けず、
//  一括取得や `&range=` クエリは 403 で拒否されるため、
//  URLSessionDownloadTask で丸ごと取りにいく方式は使えない。
//

import Foundation
// KotoneHTTPBridge は GeckoView ターゲット側にあるため import が要る。
// （GeckoEventDispatcherWrapper.addListener が internal なので、
//   ブリッジは GeckoView の内側に置く必要があった）
import GeckoView

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// videoId → 進捗 (0.0 ... 1.0)。キーが無い = ダウンロード中でない。
    @Published private(set) var progress: [String: Double] = [:]
    /// ダウンロード完了済みの videoId 集合。
    @Published private(set) var downloadedIDs: Set<String> = []
    /// ダウンロード済みの曲 (メタ情報つき、新しい順)。
    @Published private(set) var downloadedSongs: [Song] = []

    /// 進行中のダウンロード。キャンセルに使う。
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {
        loadPersisted()
    }

    // MARK: - パス

    private var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for videoID: String) -> URL {
        downloadsDirectory.appendingPathComponent("\(videoID).m4a")
    }

    /// ダウンロード済みならローカル URL を返す。無ければ nil。
    /// PlayerManager がこれを見てローカル優先再生を決める。
    nonisolated func localFileURL(for videoID: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("\(videoID).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(_ videoID: String) -> Bool {
        downloadedIDs.contains(videoID)
    }

    func isDownloading(_ videoID: String) -> Bool {
        progress[videoID] != nil
    }

    // MARK: - ダウンロード

    /// 曲をダウンロードする。既に完了 / 進行中なら何もしない。
    ///
    /// 複数曲をまとめて落とすときは呼び出し側で順に await すれば
    /// 直列に処理される (同時に何十本も走らせない)。
    func download(_ song: Song) async {
        guard !isDownloaded(song.id), !isDownloading(song.id) else { return }

        let task = Task { await performDownload(song) }
        tasks[song.id] = task
        await task.value
        tasks[song.id] = nil
    }

    // ------------------------------------------------------------------
    // Kotone: ダウンロードは拡張機能側の fetch で行う。
    //
    // ViviMusic は YouTubeAPI.resolveStream + StreamFetcher で
    // googlevideo から直接取得していたが、その層は Gecko に置き換えた。
    // 署名デコード (PlayerJSService) と BotGuard (PoTokenService) も
    // 一緒に落としてある。
    //
    // 代わりに **ページのコンテキストで fetch する**。
    //   * Cookie / 認証がそのまま乗る
    //   * 署名済み URL をそのまま使える
    //   * CORS を気にしなくてよい
    //
    // 取得した URL は署名付きで、Swift 側から普通に GET できる。
    // ダウンロード自体は URLSession に任せる（進捗が取れるため）。
    // ------------------------------------------------------------------

    /// 拡張機能が繋がっていれば利用できる。
    static var isSupported: Bool { KotoneHTTPBridge.shared.isExtensionConnected }

    /// 直近の失敗理由。UI に出す。
    @Published var lastErrorMessage: String?

    private func performDownload(_ song: Song) async {
        // 測定ログにも出す。EventLog だけだと診断ログ画面を開くまで
        // 気づけず、切り分けに時間がかかる。
        MeasurementLog.shared.append(.player, "[DL] 開始 \(song.title) (\(song.id))")

        guard KotoneHTTPBridge.shared.isExtensionConnected else {
            fail(song, "拡張機能が接続していません")
            return
        }

        // 1. ページ側で音声 URL を解決する
        let resolved: [String: Any]
        do {
            let result = try await KotoneHTTPBridge.shared.resolveAudio(videoId: song.id)
            guard let dict = result as? [String: Any], let _ = dict["url"] as? String else {
                fail(song, "音声 URL を取得できませんでした")
                return
            }
            resolved = dict
        } catch {
            fail(song, "音声 URL の解決に失敗: \(error.localizedDescription)")
            return
        }

        guard let urlText = resolved["url"] as? String, let url = URL(string: urlText) else {
            fail(song, "音声 URL が不正です")
            return
        }

        let itag = (resolved["itag"] as? NSNumber)?.intValue ?? 0
        let mime = resolved["mimeType"] as? String ?? ""
        let client = resolved["client"] as? String ?? "?"
        EventLog.log(.downloadStart, videoID: song.id,
                     message: "\(client) itag=\(itag) \(mime)")
        MeasurementLog.shared.append(
            .player,
            "[DL] URL 解決 \(client) itag=\(itag) \(mime)"
        )

        // 2. 実データを取る
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                fail(song, "取得に失敗しました (HTTP \(http.statusCode))")
                try? FileManager.default.removeItem(at: temp)
                return
            }

            // 保存先は既存の規約に合わせて `<videoID>.m4a` 固定。
            // localFileURL(for:) がこの名前を前提にしているため、
            // 拡張子を可変にすると再生側が見つけられなくなる。
            //
            // itag 140 は audio/mp4 なのでそのまま .m4a でよい。
            // WebM/Opus しか無い場合は AVPlayer が再生できないので弾く。
            guard !mime.contains("webm") else {
                fail(song, "この曲は WebM 形式のみで、保存しても再生できません")
                try? FileManager.default.removeItem(at: temp)
                return
            }
            let destination = fileURL(for: song.id)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)

            downloadedIDs.insert(song.id)
            if !downloadedSongs.contains(song) { downloadedSongs.append(song) }
            persist()
            progress[song.id] = nil
            lastErrorMessage = nil
            EventLog.log(.downloadOK, videoID: song.id, message: destination.lastPathComponent)
            MeasurementLog.shared.append(
                .player,
                "[DL] 完了 \(song.id) \(destination.lastPathComponent)"
            )
        } catch {
            fail(song, "保存に失敗: \(error.localizedDescription)")
        }
    }

    private func fail(_ song: Song, _ message: String) {
        progress[song.id] = nil
        lastErrorMessage = message
        EventLog.log(.downloadNG, videoID: song.id, message: message)
        MeasurementLog.shared.append(.error, "[DL] 失敗 \(song.id): \(message)")
    }

    func cancel(_ videoID: String) {
        tasks[videoID]?.cancel()
        tasks[videoID] = nil
        progress[videoID] = nil
        EventLog.log(.downloadNG, videoID: videoID, message: "ユーザー操作でキャンセル")
    }

    /// ダウンロード済みファイルを削除する。
    func delete(_ videoID: String) {
        let url = fileURL(for: videoID)
        try? FileManager.default.removeItem(at: url)
        downloadedIDs.remove(videoID)
        downloadedSongs.removeAll { $0.id == videoID }
        persist()
        EventLog.log(.storage, videoID: videoID, message: "ダウンロード削除")
    }

    /// ダウンロード済みファイルの合計サイズ (バイト)。
    func totalBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    /// 人が読めるサイズ表記。
    func totalSizeText() -> String {
        ByteCountFormatter.string(fromByteCount: totalBytes(), countStyle: .file)
    }

    // MARK: - 永続化

    private static let storageKey = "DownloadManager.songs"

    private func loadPersisted() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let songs = try? JSONDecoder().decode([Song].self, from: data) else { return }

        // ファイルが実在するものだけ有効にする (アプリ再インストール後の食い違い対策)
        let valid = songs.filter { localFileURL(for: $0.id) != nil }
        downloadedSongs = valid
        downloadedIDs = Set(valid.map(\.id))

        if valid.count != songs.count {
            EventLog.log(.storage,
                         message: "ダウンロード記録 \(songs.count) 件中 \(valid.count) 件のみ実ファイルあり")
            persist()
        }
        EventLog.log(.bootstrap, message: "ダウンロード済み \(valid.count) 件を読み込み")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(downloadedSongs) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
