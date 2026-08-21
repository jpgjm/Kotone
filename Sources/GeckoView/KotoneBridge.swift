//
//  KotoneBridge.swift
//  Kotone — WebExtension ↔ Swift ブリッジ
//
//  ⚠️ このファイルは Reynard 由来ではなく本プロジェクト独自のもの。
//     import-reynard.sh の PROTECTED に登録してあるので上書きされない。
//
//  ---------------------------------------------------------------------
//  なぜ GeckoView ターゲットの中に置くのか
//
//  イベントを受けるには GeckoEventDispatcherWrapper.addListener が要るが、
//  これも GeckoEventListenerInternal も public ではない。
//  アプリターゲットからは触れないので、AddonRuntime と同じ場所に置く。
//  ---------------------------------------------------------------------
//
//  ---------------------------------------------------------------------
//  ⚠️ この経路は使えない。KotoneHTTPBridge を使うこと。
//
//  接続とイベント配送そのものは成功する。しかし**ペイロードが必ず空になる**。
//  実測（rev.34）:
//
//    port 診断: how=waived(empty) dataSize=152 revivedType=object
//               names=[] text={}
//
//  `dataSize=152` — クローンバッファには 152 バイト入っている。
//  つまりデータは送られているのに `deserialize()` が空のオブジェクトを返す。
//  `globalThis` / `this` / `{}` のいずれを渡しても、
//  `ChromeUtils.waiveXrays()` を挟んでも変わらない。
//
//  同じメッセージに同梱される `sender` は入れ子まで完全に届くので、
//  オブジェクト → NSDictionary の変換自体は正常。
//  この Gecko iOS 移植に固有の不具合とみられる。
//
//  接続の検知（connected / disconnected）だけは有用なので残してある。
//  ---------------------------------------------------------------------
//
//  Gecko 側は既に完全実装されている（パッチ不要）。
//  modules/GeckoViewWebExtension.sys.mjs:
//
//    browser.runtime.sendNativeMessage(app, msg)
//        → dispatcher.sendRequestForResult("GeckoView:WebExtension:Message", …)
//
//    browser.runtime.connectNative(app)
//        → "GeckoView:WebExtension:Connect"
//        → "GeckoView:WebExtension:PortMessage"        (拡張 → Swift)
//        → "GeckoView:WebExtension:PortMessageFromApp" (Swift → 拡張)
//
//  配送先の dispatcher は送信元で変わる:
//    background script → EventDispatcher.instance （ランタイム）
//    content script    → getDispatcherForWindow   （セッション）
//
//  本ブリッジは background script のみを相手にするので
//  ランタイム側だけを見る。content script との中継は background が担う。
//

import Foundation

// MARK: - 受け口

public protocol KotoneBridgeDelegate: AnyObject {
    /// 拡張機能が接続した
    func bridgeDidConnect(_ bridge: KotoneBridge)
    /// 拡張機能が切断した
    func bridgeDidDisconnect(_ bridge: KotoneBridge)
    /// 拡張機能からの自発的な通知
    func bridge(_ bridge: KotoneBridge, didReceiveEvent payload: [String: Any])
    /// 記録用
    func bridge(_ bridge: KotoneBridge, log message: String)
}

public extension KotoneBridgeDelegate {
    func bridgeDidConnect(_ bridge: KotoneBridge) {}
    func bridgeDidDisconnect(_ bridge: KotoneBridge) {}
    func bridge(_ bridge: KotoneBridge, didReceiveEvent payload: [String: Any]) {}
    func bridge(_ bridge: KotoneBridge, log message: String) {}
}

public struct KotoneBridgeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - 本体

public final class KotoneBridge: NSObject, GeckoEventListenerInternal {

    public static let shared = KotoneBridge()

    public weak var delegate: KotoneBridgeDelegate?

    /// 拡張機能が connectNative で開いたポートの ID
    private var portId: Any?
    /// そのポート専用の dispatcher（`port:<portId>`）
    private var portDispatcher: GeckoEventDispatcherWrapper?
    /// 拡張機能の ID（Connect 時に判明する）
    private(set) public var extensionId: String?

    public var isConnected: Bool { portId != nil }

    private var nextRequestId: Int = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]

    /// manifest.json / background.js の NATIVE_APP と一致させること
    public static let nativeApp = "kotone"

    /// ランタイム dispatcher で受けるイベント。
    /// ポート確立の通知はこちらに来る。
    private enum RuntimeEvent: String, CaseIterable {
        case message = "GeckoView:WebExtension:Message"
        case connect = "GeckoView:WebExtension:Connect"
    }

    /// ポート専用 dispatcher で受けるイベント。
    ///
    /// Gecko 側の EmbedderPort は `EventDispatcher.byName("port:<portId>")`
    /// を作り、そこに対して送受信する。
    ///   onPortMessage    → "GeckoView:WebExtension:PortMessage"
    ///   onPortDisconnect → "GeckoView:WebExtension:Disconnect"
    /// 受け側も同名の dispatcher を lookup しないと何も届かない。
    /// ランタイム dispatcher に張っても無意味だった。
    private enum PortEvent: String, CaseIterable {
        case portMessage = "GeckoView:WebExtension:PortMessage"
        case disconnect  = "GeckoView:WebExtension:Disconnect"
    }

    private override init() {
        super.init()
    }

    /// 組み込みアドオンとしてインストールする。
    ///
    /// ------------------------------------------------------------------
    /// **これが唯一の経路。** `.xpi` を普通にインストールする道は塞がっている。
    ///
    ///   modules/AppConstants.sys.mjs:115  MOZ_REQUIRE_SIGNING: true
    ///   modules/addons/AddonSettings.sys.mjs:32
    ///     if (AppConstants.MOZ_REQUIRE_SIGNING && !Cu.isInAutomation) {
    ///       makeConstant("REQUIRE_SIGNING", true);   // pref は一切見ない
    ///     }
    ///
    /// つまり `xpinstall.signatures.required` を何に設定しても無意味で、
    /// 未署名の .xpi は必ず `installError = -5`
    /// (`ERROR_SIGNEDSTATE_REQUIRED`) になる。
    ///
    /// 一方 `AddonManager.installBuiltinAddon()` は署名検査を通らない。
    /// Gecko 側の `validateBuiltInLocation` が
    ///   scheme == "resource" && host == "android" && uri.fileName == ""
    /// を要求するため、`scripts/AddGecko.sh` が chrome.manifest に
    ///   resource android file:kotone-bridge/
    /// を追記し、`Extension/` をそこへ配置している。
    /// ------------------------------------------------------------------
    ///
    /// 候補を順に試し、それぞれの失敗理由を返す。
    /// どの形が通るかが未確定なため、切り分けを兼ねている。
    ///
    /// `scripts/relax-builtin-location.py` が Gecko 側の検証を緩めており、
    /// `file://` も受け付ける。本命はアプリバンドル内の実フォルダを直接指す形。
    public static let builtInExtensionId = "bridge@kotone.example.com"

    /// `AddGecko.sh` が拡張機能を置く場所（アプリバンドル内）
    public static var bundledExtensionURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Frameworks/GeckoView.framework/Frameworks/kotone-bridge",
                                    isDirectory: true)
        return FileManager.default
            .fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
    }

    public static func builtInCandidates() -> [String] {
        var list: [String] = []
        // 本命: 実フォルダを file:// で直接指す。末尾は必ず "/"。
        if let url = bundledExtensionURL {
            list.append(url.absoluteString.hasSuffix("/")
                        ? url.absoluteString
                        : url.absoluteString + "/")
        }
        // 予備: chrome.manifest で登録した substitution 経由
        list.append("resource://android/")
        return list
    }

    /// - Returns: 成功した URI と結果
    public static func installBuiltIn() async throws -> (uri: String, result: Any?) {
        let candidates = builtInCandidates()
        guard !candidates.isEmpty else {
            throw KotoneBridgeError("インストール元の候補がありません")
        }

        var failures: [String] = []
        for uri in candidates {
            do {
                let result = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
                    type: "GeckoView:WebExtension:EnsureBuiltIn",
                    message: [
                        "locationUri": uri,
                        "webExtensionId": builtInExtensionId,
                    ]
                )
                return (uri, result)
            } catch {
                let reason = (error as? GeckoHandlerError).map { "\($0.value ?? "nil")" }
                    ?? error.localizedDescription
                failures.append("\(uri)\n    → \(reason)")
            }
        }

        var message = "組み込みインストールに失敗しました\n\n"
            + failures.joined(separator: "\n")
        if bundledExtensionURL == nil {
            message += "\n\n※ バンドル内に kotone-bridge/manifest.json がありません。"
                + "AddGecko.sh の配置が効いていない可能性があります。"
        }
        throw KotoneBridgeError(message)
    }

    /// ランタイムの dispatcher に listener を張る。
    /// Gecko の起動後（最初のページ描画後）に呼ぶこと。
    public func activate() {
        for event in RuntimeEvent.allCases {
            GeckoEventDispatcherWrapper.runtimeInstance
                .addListener(type: event.rawValue, listener: self)
        }
        log("listening (runtime): "
            + RuntimeEvent.allCases.map(\.rawValue).joined(separator: ", "))

        // 一定時間 Connect が来なければ、原因の候補を出しておく。
        // 黙って繋がらないのが一番困るため。
        Task { [weak self] in
            // 起動時の ensureBuiltIn とページ読み込みを待つため長めに取る
            try? await Task.sleep(nanoseconds: 40_000_000_000)
            guard let self, !self.isConnected else { return }
            self.log("""
                15 秒経っても拡張機能から接続がありません。確認点:
                  * Kotone Bridge がインストール済みで有効か（🧩 画面）
                  * manifest.json に geckoViewAddons 権限があるか
                    無いと connectNative が Firefox 標準の NativeApp に流れ、
                    iOS では必ず失敗する（ExtensionParent.sys.mjs:259）
                  * 拡張機能を更新した場合、version を上げたか
                    ensureBuiltIn はバージョン比較で再インストールを決める
                """)
        }
    }

    // MARK: - 送信

    /// 拡張機能へ送って結果を待つ。
    /// background.js が requestId を見て "reply" を返してくる。
    @discardableResult
    public func request(_ type: String, payload: [String: Any]? = nil) async throws -> Any? {
        guard let portId else {
            throw KotoneBridgeError("拡張機能が接続していません")
        }

        let id = nextRequestId
        nextRequestId += 1

        var message: [String: Any] = ["type": type, "requestId": id]
        if let payload { message["payload"] = payload }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation

            // Swift → 拡張機能。
            // 受け手は EmbedderPort が作った port:<portId> dispatcher なので、
            // ランタイム dispatcher に投げても届かない。
            // Gecko 側は aData.message だけを見る（portId は不要）。
            //
            // 受信と同じ理由で、辞書ではなく JSON 文字列で渡す。
            let encoded: Any = Self.encodeJSON(message) ?? message
            self.portDispatcher?.dispatch(
                type: "GeckoView:WebExtension:PortMessageFromApp",
                message: ["message": encoded],
                callback: nil
            )

            // 応答が来ない場合に備えた保険
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                waiting.resume(throwing: KotoneBridgeError("タイムアウト: \(type)"))
            }
        }
    }

    /// 応答を待たずに送る
    public func notify(_ type: String, payload: [String: Any]? = nil) {
        guard let dispatcher = portDispatcher else { return }
        var message: [String: Any] = ["type": type]
        if let payload { message["payload"] = payload }
        let encoded: Any = Self.encodeJSON(message) ?? message
        dispatcher.dispatch(
            type: "GeckoView:WebExtension:PortMessageFromApp",
            message: ["message": encoded],
            callback: nil
        )
    }

    // MARK: - 受信

    @MainActor
    func handleMessage(type: String, message: [String: Any?]?) async throws -> Any? {
        let msg = message ?? [:]

        if let event = RuntimeEvent(rawValue: type) {
            switch event {
            case .connect:
                attachPort(msg)
            case .message:
                // sendNativeMessage（ポートを使わない一発送信）。
                // ポート経由が駄目でもこちらは通る可能性がある。
                if !didDumpRuntimeMessage {
                    didDumpRuntimeMessage = true
                    dumpShape(type: type, msg: msg)
                }
                let payload = extractPayload(from: msg)
                handlePayload(payload)

                // sendNativeMessage は戻り値が拡張機能側の
                // await の解決値になる。応答を返せることを確認するため、
                // 受け取った内容を要約して返す。
                var reply: [String: Any] = ["ok": true]
                if let dict = payload as? [String: Any] {
                    reply["receivedKeys"] = dict.keys.sorted()
                    if let t = dict["type"] as? String { reply["receivedType"] = t }
                } else if let text = payload as? String {
                    reply["receivedString"] = text
                } else {
                    reply["received"] = "nil"
                }
                // 応答も文字列で返す（辞書は潰れる可能性があるため）
                return Self.encodeJSON(reply) ?? "{\"ok\":true}"
            }
            return nil
        }

        if let event = PortEvent(rawValue: type) {
            switch event {
            case .portMessage:
                // Gecko 側パッチが入れた診断情報。どの復元方法で
                // 値が取れたか、holder の正体は何かが分かる。
                if !didDumpPortMessage, let debug = msg["kotoneDebug"] as? String {
                    log("port 診断: \(debug)")
                }
                // 最初の 1 通だけ生の形を出す。
                // Gecko → Swift のブリッジで辞書がどう写像されるかは
                // 実測しないと分からない（NSDictionary のネストが
                // 空になる例があるため）。
                if !didDumpPortMessage {
                    didDumpPortMessage = true
                    dumpShape(type: type, msg: msg)
                }
                handlePayload(extractPayload(from: msg))
            case .disconnect:
                log("disconnected")
                detachPort()
                delegate?.bridgeDidDisconnect(self)
            }
            return nil
        }

        return nil
    }

    /// Connect イベントからポートを取り出し、専用 dispatcher を購読する。
    private func attachPort(_ msg: [String: Any?]) {
        // 再インストール時に古いポートが残らないよう、先に外す。
        detachPort()

        extensionId = msg["extensionId"] as? String
        guard let id = msg["portId"] ?? nil else {
            log("Connect を受け取りましたが portId がありません: \(msg)")
            return
        }
        portId = id

        // Gecko: EventDispatcher.byName(`port:${portId}`)
        // portId は数値なので、文字列化の仕方で名前がずれないよう整数に寄せる。
        let name: String
        if let n = id as? NSNumber {
            name = "port:\(n.int64Value)"
        } else {
            name = "port:\(id)"
        }

        // Gecko 側の EmbedderPort が EventDispatcher.byName(name) を作ると、
        // GeckoRuntimeImpl.dispatcher(byName:) 経由で
        // この同名 wrapper に attach される（GeckoRuntime.swift:28）。
        let dispatcher = GeckoEventDispatcherWrapper.lookup(byName: name)
        for event in PortEvent.allCases {
            dispatcher.addListener(type: event.rawValue, listener: self)
        }

        // dispatch() は「listener が無く、queue が非 nil」のとき送信せず貯める。
        // Gecko 側の attach/activate が済んでいれば queue は nil になっている。
        // まだなら activate() を促して溜まった分を流す。
        dispatcher.activate()

        portDispatcher = dispatcher

        log("connected — extension=\(extensionId ?? "?") dispatcher=\(name)")
        delegate?.bridgeDidConnect(self)
    }

    private func detachPort() {
        portId = nil
        portDispatcher = nil
        failAllPending(KotoneBridgeError("ポートが切断されました"))
    }

    private var didDumpPortMessage = false
    private var didDumpRuntimeMessage = false
    private var didWarnEmptyPayload = false

    /// 受信メッセージの実際の形をログに出す（初回のみ）。
    private func dumpShape(type: String, msg: [String: Any?]) {
        var lines = ["受信の生データ (\(type))"]
        for key in msg.keys.sorted() {
            let value = msg[key] ?? nil
            let kind = value.map { String(describing: Swift.type(of: $0)) } ?? "nil"
            var preview = String(describing: value ?? "nil")
            if preview.count > 200 { preview = String(preview.prefix(200)) + "…" }
            lines.append("  \(key): \(kind) = \(preview)")
        }
        log(lines.joined(separator: "\n"))
    }

    /// ペイロードを取り出す。
    ///
    /// ------------------------------------------------------------------
    /// **JSON 文字列でやり取りする。**
    ///
    /// オブジェクトのまま送ると Swift 側には空の辞書として届く。実測:
    ///
    ///   受信の生データ (GeckoView:WebExtension:PortMessage)
    ///     data: __NSDictionaryM = { }
    ///
    /// Gecko 側は
    ///   onPortMessage(holder) {
    ///     dispatcher.sendRequest(..., { data: holder.deserialize({}) });
    ///   }
    /// と、構造化クローンを空オブジェクトをグローバルとして復元しており、
    /// できたオブジェクトが JS→ネイティブ変換で列挙できていないとみられる。
    /// 文字列なら単純な値なので変換を通る。
    /// ------------------------------------------------------------------
    private func extractPayload(from msg: [String: Any?]) -> Any? {
        // kotoneText は scripts/fix-port-message.py が足す保険用のキー。
        // JS オブジェクトの変換が不安定でも、文字列なら通ることが多い。
        for key in ["kotoneText", "data", "message", "payload"] {
            guard let value = msg[key] ?? nil else { continue }

            // 本命: JSON 文字列
            if let text = value as? String {
                if let parsed = Self.parseJSON(text) { return parsed }
                return text
            }
            // 念のため: 辞書のまま届いた場合
            if let dict = value as? [String: Any], !dict.isEmpty { return dict }
            if let dict = value as? NSDictionary, dict.count > 0 { return dict }
        }
        return nil
    }

    private static func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    private static func encodeJSON(_ value: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func handlePayload(_ raw: Any?) {
        var dict: [String: Any] = [:]
        if let d = raw as? [String: Any] {
            dict = d
        } else if let d = raw as? NSDictionary {
            for (k, v) in d {
                if let key = k as? String { dict[key] = v }
            }
        } else {
            log("受信: 解釈できない形式 \(String(describing: raw))")
            return
        }
        guard !dict.isEmpty else {
            // この経路は常に空になる（上記のとおり）。
            // 毎回出すとログが埋まるので一度だけにする。
            if !didWarnEmptyPayload {
                didWarnEmptyPayload = true
                log("この経路のペイロードは常に空になる。HTTP 経路を使うこと。")
            }
            return
        }

        switch dict["type"] as? String {
        case "reply":
            guard let id = dict["requestId"] as? Int,
                  let continuation = pending.removeValue(forKey: id) else { return }
            if let error = dict["error"] as? String, !error.isEmpty {
                continuation.resume(throwing: KotoneBridgeError(error))
            } else {
                continuation.resume(returning: dict["result"] ?? nil)
            }

        case "hello":
            // ネスト辞書・数値・真偽・配列がそのまま渡るかを確認する
            log("""
                extension hello
                  version = \(dict["version"] ?? "nil")
                  num     = \(dict["num"] ?? "nil")
                  flag    = \(dict["flag"] ?? "nil")
                  nested  = \(dict["nested"] ?? "nil")
                  list    = \(dict["list"] ?? "nil")
                """)

        case "echo":
            // Swift → 拡張機能 の到達確認。届いていなければ何も出ない。
            log("""
                echo（Swift からの送信が拡張機能に届いた）
                  rawType = \(dict["rawType"] ?? "nil")
                  raw     = \(dict["raw"] ?? "nil")
                """)

        case "event":
            delegate?.bridge(self, didReceiveEvent: dict["payload"] as? [String: Any] ?? [:])

        default:
            log("受信: \(dict)")
        }
    }

    private func failAllPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    private func log(_ message: String) {
        delegate?.bridge(self, log: message)
    }
}
