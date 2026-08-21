//
//  YouTubeAPI.swift
//  ViviMusic
//
//  UI から使う高レベル API。InnerTube + Parsers を束ねる。
//  「どのクライアントで叩くか」「失敗したらどこにフォールバックするか」は
//  ここに集約する。
//

import Foundation

enum YouTubeAPI {

    /// browseId 定数。
    enum BrowseID {
        static let home = "FEmusic_home"
        static let explore = "FEmusic_explore"
        static let charts = "FEmusic_charts"
        static let newReleases = "FEmusic_new_releases_albums"
    }

    // MARK: - ホーム

    /// ホームフィード (Quick picks / おすすめ / 最近のトレンド など) を 1 ページ取得する。
    ///
    /// InnerTube の `FEmusic_home` は初回応答で先頭の数棚しか返さない。
    /// 「新作」「おすすめのアルバム」などの下の方の棚は、返ってきた
    /// continuation トークンで追加リクエストを投げないと取得できない。
    /// 本家 VIVI Music の `HomeViewModel.loadMoreYouTubeItems()` と同じ挙動。
    ///
    /// - Parameter continuation: 2 ページ目以降のトークン。nil なら先頭ページ。
    static func home(continuation: String? = nil) async throws -> HomeFeed {
        let started = Date()

        // continuation を送るときは browseId を付けない (本家と同じ)。
        // 両方付けると InnerTube 側が browseId を優先し、
        // 毎回 1 ページ目が返ってきて先に進めなくなる。
        let json: JSON
        if let continuation {
            json = try await InnerTube.shared.browse(browseID: nil, continuation: continuation)
        } else {
            json = try await InnerTube.shared.browse(browseID: BrowseID.home)
        }

        let sections = Parsers.sections(json)
        let next = Parsers.continuationToken(json)

        EventLog.logDuration(
            .home, start: started,
            message: (continuation == nil ? "先頭ページ" : "追加ページ")
                + " \(sections.count) セクション取得 / "
                + (next == nil ? "続きなし" : "続きあり")
        )
        if sections.isEmpty && continuation == nil {
            EventLog.log(.home, message: "セクションが 0 件。レスポンス構造が変わった可能性")
        }
        return HomeFeed(sections: sections, continuation: next)
    }

    // MARK: - 探索 / トレンド

    /// 探索タブ (新着リリース / ムード / チャート入口)。
    static func explore() async throws -> [HomeSection] {
        let started = Date()
        let json = try await InnerTube.shared.browse(browseID: BrowseID.explore)
        let sections = Parsers.sections(json)
        EventLog.logDuration(.explore, start: started,
                             message: "explore \(sections.count) セクション")
        return sections
    }

    /// チャート (トレンド)。国別の人気曲・人気アーティストが返る。
    static func charts() async throws -> [HomeSection] {
        let started = Date()
        let json = try await InnerTube.shared.browse(browseID: BrowseID.charts)
        let sections = Parsers.sections(json)
        EventLog.logDuration(.explore, start: started,
                             message: "charts \(sections.count) セクション")
        return sections
    }

    /// 新着アルバム。
    static func newReleases() async throws -> [HomeSection] {
        let started = Date()
        let json = try await InnerTube.shared.browse(browseID: BrowseID.newReleases)
        let sections = Parsers.sections(json)
        EventLog.logDuration(.explore, start: started,
                             message: "newReleases \(sections.count) セクション")
        return sections
    }

    /// 任意の browseId を辿る (アルバム / プレイリスト / アーティストページ)。
    static func browse(_ browseID: String) async throws -> [HomeSection] {
        let json = try await InnerTube.shared.browse(browseID: browseID)
        return Parsers.sections(json)
    }

    /// アルバム / プレイリスト / アーティストの詳細ページを取得する。
    ///
    /// プレイリストの browseId は "VL" 接頭辞が要る場合がある。
    /// "PL..." のまま渡されたら補ってから叩く。
    static func browsePage(route: BrowseRoute) async throws -> BrowsePage {
        let started = Date()

        var browseID = route.browseID
        if route.kind == .playlist, browseID.hasPrefix("PL") {
            browseID = "VL" + browseID
        }

        let json = try await InnerTube.shared.browse(browseID: browseID)
        let page = Parsers.browsePage(json,
                                      kind: route.kind,
                                      fallbackTitle: route.title,
                                      fallbackThumbnail: route.thumbnailURL)

        EventLog.logDuration(
            .home, start: started,
            message: "\(route.kind.displayName) \(browseID) → 曲 \(page.songs.count) / 棚 \(page.sections.count)"
        )
        if page.isEmpty {
            EventLog.log(.home, message: "\(browseID) の中身が空。レスポンス構造が想定と違う可能性")
        }
        return page
    }

    // MARK: - 検索

    /// 絞り込みを指定して検索し、区画ごとに分類して返す。
    ///
    /// 「すべて」では YouTube Music と同じく
    /// 上位の結果 / 曲 / 動画 / アルバム / アーティスト / プレイリスト
    /// が見出しつきで返る。
    static func search(_ query: String,
                       filter: SearchFilter) async throws -> [SearchSection] {
        let started = Date()
        let json = try await InnerTube.shared.search(query: query, params: filter.params)
        var sections = Parsers.searchSections(json)

        // 曲で 0 件なら動画でも探す。
        // YouTube Music に登録が無くても YouTube 側にはあることが多い。
        if sections.isEmpty, filter == .song {
            EventLog.log(.search, message: "曲で 0 件 → 動画で再検索")
            let videoJSON = try await InnerTube.shared.search(query: query,
                                                             params: SearchFilter.video.params)
            sections = Parsers.searchSections(videoJSON)
        }

        let total = sections.reduce(0) { $0 + $1.items.count }
        EventLog.logDuration(.search, start: started,
                             message: "\"\(query)\" [\(filter.title)] → "
                                 + "\(sections.count) 区画 / \(total) 件")
        return sections
    }

    /// 曲だけを平坦なリストで得る (キューを組む用途)。
    static func searchSongs(_ query: String) async throws -> [Song] {
        let sections = try await search(query, filter: .song)
        return sections.flatMap { $0.items.compactMap(\.song) }
    }

    /// 検索候補 (オートコンプリート) を取得する。
    /// 失敗しても検索自体は続けられるので、エラーは投げずに空配列を返す。
    static func searchSuggestions(_ input: String) async -> [SearchSuggestion] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }
        do {
            let json = try await InnerTube.shared.searchSuggestions(input: trimmed)
            let suggestions = Parsers.searchSuggestions(json)
            EventLog.log(.search, message: "候補 \"\(trimmed)\" → \(suggestions.count) 件")
            return suggestions
        } catch {
            if (error as? URLError)?.code != .cancelled {
                EventLog.logError(.search, error: error, context: "検索候補 \"\(trimmed)\"")
            }
            return []
        }
    }

    // MARK: - 再生ストリーム解決

    /// 再生用の音声ストリームを解決する。
    ///
    /// クライアントの優先順位 (2026-08 の実測に基づく):
    ///   ANDROID_VR 1.43.32  ← MAIN_CLIENT。発行される URL の制限が最も緩い
    ///   ANDROID_VR 1.61.48  ← フォールバック 1
    ///   IOS                 ← フォールバック 2
    ///   WEB_REMIX           ← 通常動画では UNPLAYABLE になるので後ろ
    ///   TVHTML5             ← ログイン時のみ。bot 判定下の最後の砦
    ///
    /// IOS を最優先にしていた頃は、URL が Range ヘッダを小分けにしないと
    /// 403 を返す挙動のため再生できなかった。ANDROID_VR の URL にはその制限がない。
    ///
    /// 各候補について、URL が実際に使えるかを HEAD で確認してから採用する
    /// (本家の `validateStatus` と同じ考え方)。
    /// - Parameter excluding: 使わないクライアント名。
    ///   再生の途中で 403 になったときに、同じ URL を出したクライアントを
    ///   もう一度試しても無駄なので除外するために使う。
    ///   全部除外されてしまう場合は、指定を無視して通常の順で試す。
    /// 再生 URL を解決する。
    ///
    /// 解決したあと、そのアイデンティティが googlevideo に絞られて
    /// いないかを検査し、絞られていれば visitorData を引き直して
    /// やり直す。健全なものが出るまで最大 `maxIdentityRedraws` 回。
    ///
    /// ── なぜ要るか ──────────────────────────────────────
    /// 制限は **匿名セッション単位**でかかっており、
    /// 悪い籤を引くとそのセッションを使う限り必ず約 65 秒で 403 になる。
    /// 引き直すと 3 回に 1 回ほど健全なものが当たる (Opaline の観測)。
    ///
    /// 検査は HEAD 1 回で済み、枠も消費しない。
    /// 403 になってから対処するより、始める前に確かめるほうが速い。
    // ------------------------------------------------------------------
    // Kotone: 再生ストリームの解決は取り除いた。
    //
    // ViviMusic では resolveStream / resolveStreamOnce が
    // PlayerJSService（署名デコード）・PoTokenService（BotGuard）・
    // StreamProbe を使って googlevideo の URL を組み立てていた。
    // 65 秒で打ち切られる問題の当事者でもあった。
    //
    // Kotone では再生を Gecko 内の公式プレイヤーに任せるため、
    // この層は丸ごと不要になる。videoId を PlayerManager に渡すと
    // KotoneHTTPBridge 経由で watch?v= へ遷移する。
    //
    // 検索・ブラウズ（home / explore / search など）はそのまま使う。
    // ------------------------------------------------------------------

    static func songInfo(videoID: String) async throws -> Song {
        let json = try await InnerTube.shared.player(videoID: videoID, client: .ios)
        return Parsers.song(fromPlayerResponse: json, fallbackID: videoID)
    }

    /// 関連曲。キューの自動継続に使う。
    static func related(videoID: String) async -> [Song] {
        do {
            let json = try await InnerTube.shared.next(videoID: videoID)
            let songs = Parsers.relatedSongs(json)
            EventLog.log(.queue, videoID: videoID, message: "関連曲 \(songs.count) 件")
            return songs
        } catch {
            EventLog.logError(.queue, videoID: videoID, error: error, context: "related")
            return []
        }
    }
}
