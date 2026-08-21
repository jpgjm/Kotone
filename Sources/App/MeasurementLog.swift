//
//  MeasurementLog.swift
//  Kotone — Phase 1 の測定記録
//
//  最大の目的は「65 秒を超えて再生できたか」を客観的に残すこと。
//  MediaSession の positionState はページ内の実再生位置なので、
//  その最大値（水位）を追えば、経過時間ではなく実際の再生到達点が分かる。
//
//  positionState は頻繁に飛んでくるためログが埋まる。
//  節目（10 秒ごと、および 60 / 65 / 70 秒）だけを記録する。
//

import Foundation
import UIKit

enum LogKind: String {
    case info  = "INFO"
    case nav   = "NAV "
    case media = "MEDIA"
    case addon  = "ADDON"
    case bridge = "BRIDGE"
    case player = "PLAYER"
    case error = "ERR "
    case mark  = "MARK"
}

/// 測定ログの 1 行。
/// ViviMusic の `EventLog` にも `LogEntry` があるため、
/// 名前の衝突を避けて `MeasurementEntry` にしてある。
struct MeasurementEntry {
    let time: Date
    let kind: LogKind
    let message: String
}

final class MeasurementLog {

    static let shared = MeasurementLog()

    private(set) var entries: [MeasurementEntry] = []
    private let lock = NSLock()

    /// 到達した最大再生位置（秒）。65 秒問題の判定に使う。
    private(set) var highWaterMark: Double = 0
    private var lastLoggedStep: Int = -1
    private var passedThresholds: Set<Int> = []

    /// 特に注視する秒数。65 秒前後を細かく見る。
    private static let thresholds = [30, 60, 63, 65, 70, 80, 100, 120, 180, 300]

    static let didChange = Notification.Name("MeasurementLog.didChange")

    private init() {}

    // MARK: - 記録

    func append(_ kind: LogKind, _ message: String) {
        lock.lock()
        entries.append(MeasurementEntry(time: Date(), kind: kind, message: message))
        if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func resetPlaybackWatch() {
        lock.lock()
        highWaterMark = 0
        lastLoggedStep = -1
        passedThresholds.removeAll()
        lock.unlock()
    }

    func notePlaybackPosition(_ position: Double, duration: Double, rate: Double) {
        guard position.isFinite, position >= 0 else { return }

        lock.lock()
        // 巻き戻しや曲の切り替えでは水位を下げない。
        // 大きく戻った場合だけ新しい曲とみなしてリセットする。
        if position + 5 < highWaterMark {
            lock.unlock()
            resetPlaybackWatch()
            append(.mark, "position reset (曲の切り替え or シーク)")
            lock.lock()
        }
        highWaterMark = max(highWaterMark, position)
        let mark = highWaterMark
        let step = Int(mark / 10)
        let shouldLogStep = step > lastLoggedStep
        if shouldLogStep { lastLoggedStep = step }

        var crossed: [Int] = []
        for t in Self.thresholds where Int(mark) >= t && !passedThresholds.contains(t) {
            passedThresholds.insert(t)
            crossed.append(t)
        }
        lock.unlock()

        for t in crossed {
            let note: String
            switch t {
            case 65:  note = "  ← ★ 65 秒を突破"
            case 63:  note = "  ← 65 秒の壁が近い"
            default:  note = ""
            }
            append(.mark, "再生位置 \(t) 秒に到達\(note)")
        }

        if shouldLogStep && crossed.isEmpty {
            append(
                .media,
                String(
                    format: "position %.1f / %.1f  rate %.2f",
                    position, duration, rate
                )
            )
        }
    }

    // MARK: - 出力

    func formatted() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"

        lock.lock()
        let snapshot = entries
        let mark = highWaterMark
        lock.unlock()

        var header = """
        Kotone — Phase 1 measurement log
        \(String(repeating: "─", count: 44))
        最大再生位置: \(String(format: "%.1f", mark)) 秒
        """
        if mark >= 65 {
            header += "  ★ 65 秒を超えました"
        } else if mark > 0 {
            header += "  （まだ 65 秒未満）"
        }
        header += "\nメモリ: \(Self.memoryFootprint())\n\n"

        return header + snapshot.map {
            "\(f.string(from: $0.time))  \($0.kind.rawValue)  \($0.message)"
        }.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        resetPlaybackWatch()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 測定項目 6（メモリ使用量）用。
    /// iPad 第 9 世代は 3 GB なので、Gecko との同居が成立するかを見る。
    static func memoryFootprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "取得不可" }
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f.string(fromByteCount: Int64(info.phys_footprint))
    }
}

// MARK: - 表示

final class MeasurementLogViewController: UIViewController {

    private let textView = UITextView()
    private var autoScroll = true

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "測定ログ"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share)),
            UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(clear)),
        ]

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 32, right: 10)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: MeasurementLog.didChange, object: nil
        )
        refresh()
    }

    @objc private func refresh() {
        DispatchQueue.main.async {
            let atBottom = self.textView.contentOffset.y
                >= self.textView.contentSize.height - self.textView.bounds.height - 40
            self.textView.text = MeasurementLog.shared.formatted()
            if self.autoScroll && atBottom {
                let end = NSRange(location: (self.textView.text as NSString).length, length: 0)
                self.textView.scrollRangeToVisible(end)
            }
        }
    }

    @objc private func share(_ sender: UIBarButtonItem) {
        let vc = UIActivityViewController(
            activityItems: [MeasurementLog.shared.formatted()],
            applicationActivities: nil
        )
        vc.popoverPresentationController?.barButtonItem = sender
        present(vc, animated: true)
    }

    @objc private func clear() {
        MeasurementLog.shared.clear()
        refresh()
    }
}
