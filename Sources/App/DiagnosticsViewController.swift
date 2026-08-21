//
//  DiagnosticsViewController.swift
//  Kotone — Phase 0 の確認項目を実機上で検証する画面
//
//  Gecko を起動せずに、バンドルが正しく組み上がっているかだけを見ます。
//  README の「Phase 0 の完了条件」のうち、以下をここで判定します。
//
//    * 独自 Bundle ID でインストールできたか
//    * Frameworks/XUL が同梱されているか
//    * Gecko のリソースが同梱されているか
//    * PlugIns/"Reynard Helper.appex" が正しい名前で存在するか  ← 最重要
//
//  Gecko の起動可否そのものは Phase 0-B2 で確認します。
//

import UIKit

// MARK: - 判定結果

private enum CheckState {
    case pass
    case fail
    case info

    var symbol: String {
        switch self {
        case .pass: return "✅"
        case .fail: return "❌"
        case .info: return "•"
        }
    }
}

private struct Check {
    let state: CheckState
    let title: String
    let detail: String
}

// MARK: - 検査

private enum BundleInspector {

    /// Gecko(XUL) が子プロセス起動時に PlugIns/ から探すファイル名。
    /// reynard-browser patches/ipc/glue/NSExtensionUtils.mm.patch:143
    /// で lastPathComponent の完全一致で検索されるため、変更してはいけない。
    static let requiredHelperName = "Reynard Helper.appex"

    static func run() -> [Check] {
        var checks: [Check] = []
        let bundle = Bundle.main
        let root = bundle.bundleURL
        let fm = FileManager.default

        // --- 基本情報 -------------------------------------------------------
        checks.append(Check(
            state: .info,
            title: "Bundle Identifier",
            detail: bundle.bundleIdentifier ?? "(unknown)"
        ))
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        checks.append(Check(state: .info, title: "Version", detail: "\(short) (\(build))"))
        checks.append(Check(
            state: .info,
            title: "System",
            detail: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        ))

        // --- XUL ------------------------------------------------------------
        let xul = root.appendingPathComponent("Frameworks/XUL")
        if let size = fileSize(at: xul) {
            checks.append(Check(
                state: .pass,
                title: "Frameworks/XUL",
                detail: byteString(size)
            ))
        } else {
            checks.append(Check(
                state: .fail,
                title: "Frameworks/XUL",
                detail: "見つかりません（Gecko 未統合）"
            ))
        }

        // --- Gecko の dylib 群 -----------------------------------------------
        let frameworksDir = root.appendingPathComponent("Frameworks")
        let dylibs = (try? fm.contentsOfDirectory(atPath: frameworksDir.path))?
            .filter { $0.hasSuffix(".dylib") }
            .sorted() ?? []
        checks.append(Check(
            state: dylibs.isEmpty ? .fail : .pass,
            title: "Gecko dylibs",
            detail: dylibs.isEmpty ? "0 個" : "\(dylibs.count) 個: " + dylibs.joined(separator: ", ")
        ))

        // --- Gecko のリソース -------------------------------------------------
        let geckoRes = root.appendingPathComponent(
            "Frameworks/GeckoView.framework/Frameworks"
        )
        var resDetail = "見つかりません"
        var resState = CheckState.fail
        if fm.fileExists(atPath: geckoRes.appendingPathComponent("greprefs.js").path) {
            let expected = ["chrome", "modules", "components", "actors", "res", "defaults", "default-theme"]
            let missing = expected.filter {
                !fm.fileExists(atPath: geckoRes.appendingPathComponent($0).path)
            }
            if missing.isEmpty {
                resState = .pass
                resDetail = "greprefs.js + \(expected.count) ディレクトリすべて存在"
            } else {
                resState = .fail
                resDetail = "不足: " + missing.joined(separator: ", ")
            }
        }
        checks.append(Check(state: resState, title: "Gecko resources", detail: resDetail))

        // --- Helper appex（最重要）--------------------------------------------
        let plugIns = root.appendingPathComponent("PlugIns")
        let appexNames = (try? fm.contentsOfDirectory(atPath: plugIns.path))?
            .filter { $0.hasSuffix(".appex") }
            .sorted() ?? []

        if appexNames.contains(requiredHelperName) {
            checks.append(Check(
                state: .pass,
                title: "PlugIns/\(requiredHelperName)",
                detail: "名前が一致。XUL が子プロセスを起動できます"
            ))
        } else if appexNames.isEmpty {
            checks.append(Check(
                state: .fail,
                title: "PlugIns/\(requiredHelperName)",
                detail: "app extension が 1 つもありません。SideStore の "
                      + "\"Keep App Extensions\" を有効にしましたか？"
            ))
        } else {
            checks.append(Check(
                state: .fail,
                title: "PlugIns/\(requiredHelperName)",
                detail: "名前が一致しません。存在するのは: "
                      + appexNames.joined(separator: ", ")
                      + " — project.yml の Helper の PRODUCT_NAME を確認してください"
            ))
        }

        // --- WebExtension ----------------------------------------------------
        let ext = root.appendingPathComponent("Extension/manifest.json")
        checks.append(Check(
            state: fm.fileExists(atPath: ext.path) ? .pass : .info,
            title: "Extension/manifest.json",
            detail: fm.fileExists(atPath: ext.path) ? "同梱済み" : "未作成（Phase 2）"
        ))

        // --- バンドル総サイズ --------------------------------------------------
        if let total = directorySize(at: root) {
            checks.append(Check(state: .info, title: "Bundle size", detail: byteString(total)))
        }

        return checks
    }

    // MARK: ヘルパ

    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private static func directorySize(at url: URL) -> Int64? {
        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return nil }
        var total: Int64 = 0
        for case let item as URL in e {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - 画面

final class DiagnosticsViewController: UIViewController {

    private let textView = UITextView()
    private var report: String = ""

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "バンドル診断"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                barButtonSystemItem: .action,
                target: self,
                action: #selector(share)
            ),
            UIBarButtonItem(
                barButtonSystemItem: .refresh,
                target: self,
                action: #selector(reload)
            ),
        ]

        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        reload()
    }

    @objc private func reload() {
        var lines: [String] = []
        var failures = 0

        for check in BundleInspector.run() {
            if check.state == .fail { failures += 1 }
            lines.append("\(check.state.symbol) \(check.title)")
            lines.append("    \(check.detail)")
            lines.append("")
        }

        let header: String
        if failures == 0 {
            header = "Phase 0 checks: すべて通過\n"
                   + String(repeating: "─", count: 40) + "\n"
        } else {
            header = "Phase 0 checks: \(failures) 件の失敗\n"
                   + String(repeating: "─", count: 40) + "\n"
        }

        report = header + "\n" + lines.joined(separator: "\n")
        textView.text = report
    }

    @objc private func share(_ sender: UIBarButtonItem) {
        let vc = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = sender
        present(vc, animated: true)
    }
}
