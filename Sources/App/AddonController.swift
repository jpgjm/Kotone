//
//  AddonController.swift
//  Kotone — WebExtension（Firefox アドオン）の管理
//
//  用語について:
//    App Extension (.appex) … Reynard Helper.appex = Gecko の子プロセス。
//                             こちらは必須で、無いとブラウザ自体が動かない。
//    WebExtension (.xpi)    … uBlock Origin などのアドオン。ここで扱うのはこちら。
//
//  AddonRuntime.shared に delegate を設定しないとインストール時の
//  権限プロンプトに応答できず、アドオンを入れられない。
//

import Foundation
import GeckoView
import UIKit

/// よく使うアドオンの導入先。AMO の「最新版」に解決される URL。
enum AddonCatalog {
    struct Entry {
        let name: String
        let detail: String
        let url: String
    }

    /// AMO の listing ページ。ここを開いて「Firefox へ追加」を押す。
    /// 直接 .xpi を叩く方法もあるが、AMO 側の署名済み最新版に
    /// 追従させたいので listing 経由にしている。
    static let recommended: [Entry] = [
        Entry(
            name: "uBlock Origin",
            detail: "広告とトラッカーの除去。まずこれを入れる",
            url: "https://addons.mozilla.org/firefox/addon/ublock-origin/"
        ),
        Entry(
            name: "SponsorBlock",
            detail: "動画内スポンサー区間のスキップ",
            url: "https://addons.mozilla.org/firefox/addon/sponsorblock/"
        ),
        Entry(
            name: "AMO を開く",
            detail: "アドオン全体を検索する",
            url: "https://addons.mozilla.org/firefox/"
        ),
    ]
}

@MainActor
final class AddonController: NSObject {

    static let shared = AddonController()

    /// 権限プロンプトを出すための画面。ブラウザ側から設定する。
    weak var presenter: UIViewController?

    private let log = MeasurementLog.shared
    private var isActivated = false

    private override init() {
        super.init()
    }

    /// AddonRuntime に delegate を接続する。
    ///
    /// ------------------------------------------------------------------
    /// 起動時クラッシュ（rev.17 / rev.18）の真因は
    /// **呼び出しタイミングではなく実行スレッド**だった。
    ///
    /// `GeckoEventDispatcherWrapper` はスレッド安全でもアクター分離でもなく、
    /// `dispatch()` から `gecko?.dispatch(toGecko:)` で直接 XUL に入る。
    /// Gecko の `AutoJSAPI::Init` はメインスレッド前提なので、
    /// 協調スレッドプールから呼ばれると null 参照で死ぬ。
    ///
    /// `AddonRuntime.list()` は nonisolated async なので、
    /// `Task { @MainActor }` から `await` してもプールへ逃げてしまう。
    ///
    /// 対策は project.yml の
    ///     SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    /// で、Reynard も同じ設定を使っている（詳細は project.yml のコメント）。
    ///
    /// 以下の遅延接続はそれとは独立した保険。
    /// 最初のページが描画されてから接続するので、
    /// ランタイムの準備状態に依存しない。
    /// ------------------------------------------------------------------
    @MainActor
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        AddonRuntime.shared.delegate = self
        log.append(.addon, "addon runtime delegate attached")
    }

    @discardableResult
    func refresh() async -> [Addon] {
        guard isActivated else {
            log.append(.addon, "refresh skipped — まだ接続していません")
            return []
        }
        do {
            let list = try await AddonRuntime.shared.list()
            if list.isEmpty {
                log.append(.addon, "installed addons: (なし)")
            } else {
                let names = list.map {
                    "\($0.metaData.name ?? $0.id)\($0.metaData.enabled ? "" : " [無効]")"
                }
                log.append(.addon, "installed addons: \(names.joined(separator: ", "))")
            }
            return list
        } catch {
            log.append(.error, "addon list failed: \(error)")
            return []
        }
    }

    func install(url: String) async {
        log.append(.addon, "install requested: \(url)")
        do {
            let addon = try await AddonRuntime.shared.install(url: url, installMethod: .manager)
            log.append(.addon, "installed: \(addon.metaData.name ?? addon.id) \(addon.metaData.version)")
        } catch {
            log.append(.error, "install failed: \(error)")
        }
    }

    /// ブリッジのインストール。
    ///
    /// ------------------------------------------------------------------
    /// **組み込み経路しか使えない。**
    ///
    /// このビルドは `AppConstants.MOZ_REQUIRE_SIGNING = true` でコンパイル
    /// されており、`AddonSettings` は pref を一切見ずに
    /// `REQUIRE_SIGNING = true` を定数化する。
    /// したがって `xpinstall.signatures.required` をどう設定しても
    /// 未署名の .xpi は必ず `installError = -5` で失敗する。
    ///
    /// rev.24 は greprefs.js の `false` を根拠に .xpi 経路を主軸に置いたが、
    /// 見るべきは `AppConstants.sys.mjs:115` だった。
    ///
    /// `AddonManager.installBuiltinAddon()` は署名検査を通らないので、
    /// そちらに一本化する。
    /// ------------------------------------------------------------------
    func installBridge() async -> String {
        do {
            let (uri, result) = try await KotoneBridge.installBuiltIn()
            log.append(.addon, "installed as built-in from \(uri): \(String(describing: result))")
            await refresh()
            return "✅ インストール成功\n\n経路: \(uri)"
        } catch {
            let detail = (error as? KotoneBridgeError)?.message ?? error.localizedDescription
            log.append(.error, "built-in install failed:\n\(detail)")
            return """
                ❌ インストールに失敗しました

                \(detail)

                詳細は 📋 の ADDON / ERR ログを確認してください。
                """
        }
    }

    func setEnabled(_ enabled: Bool, for addon: Addon) async {
        do {
            let updated = enabled
                ? try await AddonRuntime.shared.enable(addon)
                : try await AddonRuntime.shared.disable(addon)
            log.append(.addon, "\(updated.metaData.name ?? updated.id) -> \(enabled ? "有効" : "無効")")
        } catch {
            log.append(.error, "enable/disable failed: \(error)")
        }
    }

    func uninstall(_ addon: Addon) async {
        let name = addon.metaData.name ?? addon.id
        do {
            try await AddonRuntime.shared.uninstall(addon)
            log.append(.addon, "uninstalled: \(name)")
        } catch {
            log.append(.error, "uninstall failed: \(error)")
        }
    }
}

// MARK: - AddonEmbedderDelegate

extension AddonController: AddonEmbedderDelegate {

    func addonController(_ controller: AddonRuntime, didUpdate addon: Addon) {
        MeasurementLog.shared.append(
            .addon,
            "updated: \(addon.metaData.name ?? addon.id) enabled=\(addon.metaData.enabled)"
        )
    }

    func addonController(
        _ controller: AddonRuntime,
        didFailInstall failure: AddonInstallFailure
    ) {
        MeasurementLog.shared.append(
            .error,
            """
            install failed
              code    = \(failure.code ?? "-")
              id      = \(failure.extensionID ?? "-")
              name    = \(failure.extensionName ?? "-")
              version = \(failure.extensionVersion ?? "-")
            """
        )
    }

    /// インストール時の権限確認。これが無いと install は必ず失敗する。
    @MainActor
    func addonController(
        _ controller: AddonRuntime,
        promptFor prompt: AddonPermissionPrompt
    ) async -> AddonPermissionPromptResponse {

        let name = prompt.addon.metaData.name ?? prompt.addon.id
        let title: String
        switch prompt.kind {
        case .install:  title = "\(name) を追加しますか？"
        case .optional: title = "\(name) が追加の権限を要求しています"
        case .update:   title = "\(name) の更新に伴う権限変更"
        }

        var lines: [String] = []
        if !prompt.permissions.isEmpty {
            lines.append("権限:\n  " + prompt.permissions.joined(separator: "\n  "))
        }
        if !prompt.origins.isEmpty {
            // uBlock Origin は <all_urls> を要求するので長くなりがち。
            let shown = prompt.origins.prefix(8).joined(separator: "\n  ")
            let more = prompt.origins.count > 8 ? "\n  … 他 \(prompt.origins.count - 8) 件" : ""
            lines.append("アクセス先:\n  " + shown + more)
        }
        if !prompt.dataCollectionPermissions.isEmpty {
            lines.append("データ収集:\n  " + prompt.dataCollectionPermissions.joined(separator: "\n  "))
        }

        MeasurementLog.shared.append(
            .addon,
            "permission prompt (\(prompt.kind)) for \(name)"
        )

        guard let presenter = presenter ?? Self.topViewController() else {
            MeasurementLog.shared.append(.error, "プロンプトを表示できる画面がありません")
            return .deny
        }

        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: title,
                message: lines.isEmpty ? "追加の権限は要求されていません。" : lines.joined(separator: "\n\n"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in
                MeasurementLog.shared.append(.addon, "permission denied by user")
                continuation.resume(returning: .deny)
            })
            alert.addAction(UIAlertAction(title: "追加", style: .default) { _ in
                MeasurementLog.shared.append(.addon, "permission granted")
                continuation.resume(
                    returning: AddonPermissionPromptResponse(
                        allow: true,
                        privateBrowsingAllowed: false,
                        technicalAndInteractionDataGranted: false
                    )
                )
            })
            presenter.present(alert, animated: true)
        }
    }

    func addonController(
        _ controller: AddonRuntime,
        didRequestOpenOptionsPageFor addon: Addon
    ) {
        guard let url = addon.metaData.optionsPageURL else { return }
        MeasurementLog.shared.append(.addon, "options page: \(url)")
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .kotoneOpenURL, object: nil, userInfo: ["url": url]
            )
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.keyWindow?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

extension Notification.Name {
    static let kotoneOpenURL = Notification.Name("Kotone.openURL")

    /// 設定画面から測定用ブラウザ画面へ切り替える。
    /// ViviMusic の Views は Kotone の型を直接は知らないので、
    /// 通知で疎結合にしている。
    static let kotoneShowBrowser = Notification.Name("Kotone.showBrowser")

    /// 測定用ブラウザ画面から音楽 UI に戻る。
    static let kotoneShowMusicUI = Notification.Name("Kotone.showMusicUI")
}
