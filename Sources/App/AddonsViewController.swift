//
//  AddonsViewController.swift
//  Kotone — アドオン管理画面
//
//  やれること:
//    * インストール済み WebExtension の一覧
//    * 有効 / 無効の切り替え
//    * 削除
//    * おすすめアドオン（uBlock Origin など）を AMO で開く
//    * .xpi の URL を直接指定してインストール
//
//  AMO を開くと UserAgentPolicy が自動で Android UA に切り替える。
//  デスクトップ UA のままだとインストールボタンが出ないため。
//

import GeckoView
import UIKit

final class AddonsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case bridge
        case player
        case installed
        case recommended
        case manual

        var title: String {
            switch self {
            case .bridge:      return "Kotone Bridge"
            case .player:      return "PlayerManager"
            case .installed:   return "インストール済み"
            case .recommended: return "おすすめ"
            case .manual:      return "URL から追加"
            }
        }
    }

    private var addons: [Addon] = []

    // MARK: - Lifecycle

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "アドオン"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh, target: self, action: #selector(reload)
        )
        AddonController.shared.presenter = self
        // ここに来ている時点でページは既に開かれており Gecko は起動済み。
        // activate() は冪等なので二重呼び出しは無害。
        AddonController.shared.activate()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AddonController.shared.presenter = self
        reload()
    }

    @objc private func reload() {
        Task { @MainActor in
            addons = await AddonController.shared.refresh()
            tableView.reloadData()
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .player:
            return "ViviMusic の Views が使う PlayerManager の Gecko 実装です。"
                + "再生 / 一時停止 / 次 / シークを順に実行し、"
                + "MediaSession から状態が返ってくるかを確認します。"
        case .bridge:
            return "ネイティブ UI とページを繋ぐ内部用アドオンです。"
                + "このビルドは署名必須（MOZ_REQUIRE_SIGNING）なので、"
                + "未署名の .xpi は入りません。"
                + "署名検査を通らない「組み込みアドオン」として導入します。"
        case .recommended:
            return "AMO ではユーザーエージェントが自動的に Android 版へ切り替わります。"
                + "デスクトップ表示のままだと「Firefox へ追加」ボタンが現れないためです。"
        case .manual:
            return "署名済みの .xpi を直接指定できます。"
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .bridge:      return 2
        case .player:      return 2
        case .installed:   return max(addons.count, 1)
        case .recommended: return AddonCatalog.recommended.count
        case .manual:      return 1
        case .none:        return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        cell.detailTextLabel?.numberOfLines = 0

        switch Section(rawValue: indexPath.section) {
        case .bridge:
            if indexPath.row == 0 {
                cell.textLabel?.text = "同梱の Kotone Bridge をインストール"
                cell.detailTextLabel?.text = "組み込みアドオンとして入れます"
                cell.textLabel?.textColor = .link
                cell.accessoryType = .disclosureIndicator
            } else {
                cell.textLabel?.text = "ブリッジ疎通テスト"
                cell.detailTextLabel?.text = "ページ情報を取得して結果を表示します"
                cell.textLabel?.textColor = .link
                cell.accessoryType = .disclosureIndicator
            }

        case .player:
            if indexPath.row == 0 {
                cell.textLabel?.text = "PlayerManager を通しで試す"
                cell.detailTextLabel?.text = "pause → play → seek → 状態確認"
            } else {
                cell.textLabel?.text = "URL 指定で曲を再生"
                cell.detailTextLabel?.text =
                    "GeckoSession.load() で watch?v= を開く（拡張機能に依存しない）"
            }
            cell.textLabel?.textColor = .link
            cell.accessoryType = .disclosureIndicator

        case .installed:
            guard !addons.isEmpty else {
                cell.textLabel?.text = "まだありません"
                cell.detailTextLabel?.text = "下の「おすすめ」から追加してください"
                cell.textLabel?.textColor = .secondaryLabel
                cell.selectionStyle = .none
                return cell
            }
            let addon = addons[indexPath.row]
            let meta = addon.metaData
            cell.textLabel?.text = meta.name ?? addon.id
            var detail = "v\(meta.version)"
            if !meta.enabled { detail += " ・ 無効" }
            if meta.isBlocklisted { detail += " ・ ブロック済み" }
            if meta.isUnsigned { detail += " ・ 未署名" }
            if meta.isUnsupported { detail += " ・ 非対応" }
            cell.detailTextLabel?.text = detail
            cell.textLabel?.textColor = meta.enabled ? .label : .secondaryLabel

            let toggle = UISwitch()
            toggle.isOn = meta.enabled
            toggle.isEnabled = meta.enabled || meta.canBeEnabled
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle

        case .recommended:
            let entry = AddonCatalog.recommended[indexPath.row]
            cell.textLabel?.text = entry.name
            cell.detailTextLabel?.text = entry.detail
            cell.accessoryType = .disclosureIndicator

        case .manual:
            cell.textLabel?.text = ".xpi の URL を入力…"
            cell.textLabel?.textColor = .link
            cell.accessoryType = .disclosureIndicator

        case .none:
            break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section) {
        case .bridge:
            if indexPath.row == 0 {
                installBridge()
            } else {
                runBridgeProbe()
            }

        case .player:
            if indexPath.row == 0 {
                runPlayerManagerTest()
            } else {
                promptForVideoId()
            }

        case .recommended:
            let entry = AddonCatalog.recommended[indexPath.row]
            NotificationCenter.default.post(
                name: .kotoneOpenURL, object: nil, userInfo: ["url": entry.url]
            )
            navigationController?.popViewController(animated: true)

        case .manual:
            promptForXPI()

        default:
            break
        }
    }

    // 削除はスワイプで
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .installed && !addons.isEmpty
    }

    /// ブリッジのインストール。
    /// rev.23 までは結果をログにしか出しておらず、
    /// 画面上は「タップしても無反応」に見えていた。必ず結果を表示する。
    private func installBridge() {
        let alert = UIAlertController(
            title: "Kotone Bridge",
            message: "インストール中…",
            preferredStyle: .alert
        )
        present(alert, animated: true)

        Task { @MainActor in
            let result = await AddonController.shared.installBridge()
            alert.message = result
            alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
            reload()
        }
    }

    /// rev.20 の完了条件。
    /// SwiftUI(UIKit) → KotoneBridge → background.js → content.js → ページ
    /// の往復が通るかを 1 タップで確かめる。
    private func runBridgeProbe() {
        let alert = UIAlertController(title: "疎通テスト", message: "実行中…", preferredStyle: .alert)
        present(alert, animated: true)

        Task { @MainActor in
            var body: String

            // 代替経路（ローカル HTTP）が生きていればそちらを優先する。
            // 正規経路は構造化クローンの復元が空になる問題を抱えている。
            if KotoneHTTPBridge.shared.isExtensionConnected {
                let http = KotoneHTTPBridge.shared
                do {
                    // 1. 単純な往復
                    let pong = try await http.request("ping")
                    // 2. content script までの往復
                    let probe = try await http.probe()
                    // 3. 実際にページを操作できるか
                    // ページ自身が持っている再生情報。
                    // ダウンロード経路の切り分けに使う。
                    let pageInfo = try? await http.playerResponseInfo()
                    // ループ / シャッフルの状態が読めているか
                    let repeatInfo = try? await http.request("repeatState")
                    let toggled = try await http.togglePlayPause()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let restored = try await http.togglePlayPause()

                    body = """
                        ✅ 往復成功（HTTP 経路）

                        ping: \(pong ?? "nil")

                        probe:
                        \(format(probe))

                        再生制御: \(format(toggled)) → \(format(restored))

                        ページの再生情報:
                        \(format(pageInfo))

                        ループ / シャッフル:
                        \(format(repeatInfo))
                        """
                } catch {
                    body = "❌ HTTP 経路: \(error.localizedDescription)"
                }
                alert.title = "疎通テスト"
                alert.message = body
                alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
                return
            }

            if !KotoneBridge.shared.isConnected {
                body = """
                    ❌ 拡張機能が接続していません

                    確認:
                    ・上の行から Kotone Bridge を入れましたか
                    ・music.youtube.com を開いていますか
                    """
            } else {
                do {
                    let pong = try await KotoneBridge.shared.request("ping")
                    let probe = try await KotoneBridge.shared.request("probe")
                    body = "✅ 往復成功\n\nping: \(pong ?? "nil")\n\nprobe:\n\(format(probe))"
                } catch {
                    body = "❌ \(error.localizedDescription)"
                }
            }
            alert.title = "疎通テスト"
            alert.message = body
            alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
        }
    }

    /// PlayerManager を実際に動かして、Views から使える状態かを確かめる。
    ///
    /// 読み取り（MediaSession 由来）と操作（HTTP ブリッジ経由）の
    /// 両方が噛み合っているかをここで見る。
    private func runPlayerManagerTest() {
        let alert = UIAlertController(
            title: "PlayerManager",
            message: "実行中…",
            preferredStyle: .alert
        )
        present(alert, animated: true)

        Task { @MainActor in
            let player = PlayerManager.shared

            // ネストした関数は外側の Task の actor 分離を継承しない。
            // 明示しないと MainActor 隔離のプロパティを読めない。
            @MainActor
            func snapshot(_ label: String) -> String {
                let song = player.currentSong
                return """
                    [\(label)]
                      currentSong = \(song?.title ?? "-") / \(song?.artist ?? "-")
                      album       = \(song?.album ?? "-")
                      isPlaying   = \(player.isPlaying)
                      time        = \(String(format: "%.1f", player.currentTime)) \
                    / \(String(format: "%.1f", player.duration))
                      error       = \(player.lastErrorMessage ?? "なし")
                    """
            }

            var lines = [snapshot("開始時")]

            player.pause()
            try? await Task.sleep(nanoseconds: 700_000_000)
            lines.append(snapshot("pause 後"))

            player.resume()
            try? await Task.sleep(nanoseconds: 700_000_000)
            lines.append(snapshot("play 後"))

            let target = max(0, player.currentTime + 10)
            player.seek(to: target)
            try? await Task.sleep(nanoseconds: 900_000_000)
            lines.append(snapshot("seek(+10) 後"))

            alert.message = lines.joined(separator: "\n\n")
            alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
        }
    }

    /// videoId を指定して PlayerManager.play を呼ぶ。
    /// 再生開始が GeckoSession.load() で成立するかの確認用。
    private func promptForVideoId() {
        let alert = UIAlertController(
            title: "URL 指定で再生",
            message: "videoId または YouTube の URL を入力してください。\n"
                + "youtu.be / watch?v= / shorts のいずれも受け付けます。",
            preferredStyle: .alert
        )
        alert.addTextField {
            $0.placeholder = "nIQko_MvspU または https://youtu.be/…"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "再生", style: .default) { _ in
            guard let text = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            Task { @MainActor in
                let song = Song(
                    id: text,
                    title: text,
                    artist: "",
                    album: nil,
                    albumID: nil,
                    durationSeconds: nil,
                    thumbnailURL: nil,
                    artistID: nil
                )
                await PlayerManager.shared.play(song: song)
                self.navigationController?.popViewController(animated: true)
            }
        })
        present(alert, animated: true)
    }

    private func format(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return String(describing: value) }
        return dict.keys.sorted().map { "  \($0) = \(dict[$0] ?? "nil")" }.joined(separator: "\n")
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, indexPath.row < addons.count else { return }
        let addon = addons[indexPath.row]
        Task { @MainActor in
            await AddonController.shared.uninstall(addon)
            reload()
        }
    }

    // MARK: - Actions

    @objc private func toggleChanged(_ sender: UISwitch) {
        guard sender.tag < addons.count else { return }
        let addon = addons[sender.tag]
        Task { @MainActor in
            await AddonController.shared.setEnabled(sender.isOn, for: addon)
            reload()
        }
    }

    private func promptForXPI() {
        let alert = UIAlertController(
            title: ".xpi をインストール",
            message: "署名済みアドオンの URL を入力してください。",
            preferredStyle: .alert
        )
        alert.addTextField {
            $0.placeholder = "https://…/addon.xpi"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "インストール", style: .default) { [weak self] _ in
            guard let text = alert.textFields?.first?.text,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            Task { @MainActor in
                await AddonController.shared.install(url: text)
                self?.reload()
            }
        })
        present(alert, animated: true)
    }
}
