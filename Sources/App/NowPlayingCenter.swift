//
//  NowPlayingCenter.swift
//  Kotone — ロック画面 / コントロールセンター / AirPods の操作
//
//  ⚠️ 本プロジェクト独自のファイル。
//     ViviMusic の Sources/Playback/NowPlayingCenter.swift を下敷きにしつつ、
//     再生の実体が Gecko 内にあることに合わせて書き直してある。
//
//  MPRemoteCommandCenter … 外側からの操作（再生ボタン等）を受け取る
//  MPNowPlayingInfoCenter … 曲名・アートワーク・再生位置を外側へ知らせる
//
//  ---------------------------------------------------------------------
//  ViviMusic との違い
//
//  * 再生位置の真実は AVPlayer ではなく PlayerManager（= ページ）にある。
//    elapsedTime は PlayerManager.currentTime をそのまま渡す。
//
//  * AVAudioSession をここで .playback に設定する。
//    Gecko の cubeb がどう設定するか不明で、
//    設定されていないとバックグラウンドで音が止まる。
//    音楽アプリなので常に .playback でよい。
//
//  * seek / next / previous は HTTP ブリッジ経由でページに届く。
//    MediaSession の features に
//    play, pause, stop, seekTo, next, prev が揃っていることは実測済み。
//  ---------------------------------------------------------------------
//

import Combine
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class NowPlayingCenter {

    static let shared = NowPlayingCenter()

    private weak var player: PlayerManager?
    private var cancellables: Set<AnyCancellable> = []

    /// アートワーク取得の重複を防ぐため、直近の URL を覚えておく。
    private var lastArtworkURL: String?
    private var artworkTask: Task<Void, Never>?

    /// 直近に外へ渡した内容。無駄な更新を減らす。
    private var lastPublishedKey: String?

    private let log = MeasurementLog.shared

    private init() {}

    // MARK: - 接続

    func attach(to player: PlayerManager) {
        self.player = player

        configureAudioSession()
        setUpRemoteCommands()
        observe(player)

        log.append(.player, "[NowPlaying] 接続")
    }

    /// バックグラウンド再生に必要。
    ///
    /// Info.plist の `UIBackgroundModes: audio` だけでは足りず、
    /// カテゴリを `.playback` にしておかないと
    /// 画面を消した時点で音が止まる。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            log.append(.player, "[NowPlaying] AVAudioSession = .playback")
        } catch {
            log.append(.error, "[NowPlaying] AVAudioSession の設定に失敗: \(error)")
        }

        // 着信などで中断されたあと、再開できるようにする。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            log.append(.player, "[NowPlaying] 中断開始")

        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            log.append(.player, "[NowPlaying] 中断終了 shouldResume=\(options.contains(.shouldResume))")
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                player?.resume()
            }

        @unknown default:
            break
        }
    }

    // MARK: - リモートコマンド

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.playCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.resume()
            return .success
        }

        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.pause()
            return .success
        }

        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            Task { await player.next() }
            return .success
        }

        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            Task { await player.previous() }
            return .success
        }

        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let player = self?.player,
                  let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            player.seek(to: event.positionTime)
            return .success
        }

        for command in [center.playCommand, center.pauseCommand,
                        center.togglePlayPauseCommand, center.nextTrackCommand,
                        center.previousTrackCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = true
        }

        // 早送り / 巻き戻しは使わない。出しておくと押せてしまうので無効化する。
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
    }

    // MARK: - 状態の反映

    private func observe(_ player: PlayerManager) {
        cancellables.removeAll()

        // 曲・再生状態・長さが変わったら作り直す。
        player.$currentSong
            .combineLatest(player.$isPlaying, player.$duration)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.publish() }
            .store(in: &cancellables)

        // 再生位置は毎秒更新されるので、間引いてから渡す。
        // ロック画面は elapsedTime と rate から自前で補間するため、
        // 頻繁に送る必要がない。
        player.$currentTime
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.publishPositionOnly() }
            .store(in: &cancellables)
    }

    /// 全体を作り直す。
    private func publish() {
        guard let player, let song = player.currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            lastPublishedKey = nil
            lastArtworkURL = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if player.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
        }

        // 既存のアートワークは維持する。作り直しのたびに消えるとちらつく。
        if let existing = MPNowPlayingInfoCenter.default()
            .nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existing
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        let key = "\(song.title)\u{1}\(song.artist)"
        if key != lastPublishedKey {
            lastPublishedKey = key
            log.append(.player, "[NowPlaying] \(song.title) / \(song.artist)")
        }

        loadArtwork(song.thumbnailURL)
    }

    /// 位置と再生速度だけ差し替える。
    private func publishPositionOnly() {
        guard let player, player.currentSong != nil,
              var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        if player.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - アートワーク

    private func loadArtwork(_ urlText: String?) {
        guard let urlText, !urlText.isEmpty else { return }
        guard urlText != lastArtworkURL else { return }
        lastArtworkURL = urlText

        // MediaSession のアートワークは w60-h60 のような小さい版で届く。
        // ロック画面には大きい方が要るので、サイズ指定を差し替える。
        let large = Self.enlarged(urlText)
        guard let url = URL(string: large) else { return }

        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.lastArtworkURL == urlText else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    /// `=w60-h60-s-l90-rj` のようなサイズ指定を大きくする。
    /// 実測で届く形は 2 種類ある。
    ///   https://yt3.googleusercontent.com/…=w60-h60-s-l90-rj
    ///   https://i.ytimg.com/vi/<id>/mqdefault.jpg
    static func enlarged(_ url: String) -> String {
        if let range = url.range(of: "=w") {
            let base = String(url[..<range.lowerBound])
            return base + "=w544-h544-l90-rj"
        }
        for (small, large) in [("mqdefault", "maxresdefault"),
                               ("hqdefault", "maxresdefault"),
                               ("sddefault", "maxresdefault")] {
            if url.contains(small) {
                return url.replacingOccurrences(of: small, with: large)
            }
        }
        return url
    }
}
