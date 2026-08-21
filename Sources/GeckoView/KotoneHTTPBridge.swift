//
//  KotoneHTTPBridge.swift
//  Kotone — 構造化クローンを迂回する代替経路
//
//  ⚠️ 本プロジェクト独自のファイル。import-reynard.sh の PROTECTED 対象。
//
//  ---------------------------------------------------------------------
//  なぜ必要か
//
//  WebExtension ↔ Swift の正規経路（connectNative / sendNativeMessage）は、
//  Gecko 側で構造化クローンを復元した結果が空のオブジェクトになり、
//  ペイロードが一切届かない。実測:
//
//    port 診断: how=globalThis(empty) ctor=StructuredCloneHolder
//               own=[] proto=[deserialize,dataSize,constructor]
//    data: __NSDictionaryM = { }
//    kotoneText: NSTaggedPointerString = {}
//
//  同じメッセージに同梱される `sender` は入れ子の中身まで正しく届いており、
//  オブジェクト → NSDictionary の変換自体は正常。
//  つまり構造化クローンの復元だけが壊れている。
//
//  こちらは Gecko のメッセージング機構を一切使わず、
//  ローカルの HTTP サーバで JSON をやり取りする。
//  拡張機能からは fetch("http://127.0.0.1:<port>/…") で届く。
//
//  * 通信は 127.0.0.1 のみ。外部からは接続できない
//  * 起動ごとにポートを変え、共有トークンで照合する
//  * Swift → 拡張機能はロングポーリング（/poll）で渡す
//  ---------------------------------------------------------------------
//

import Foundation
import Network

public protocol KotoneHTTPBridgeDelegate: AnyObject {
    /// 拡張機能からの通知
    func httpBridge(_ bridge: KotoneHTTPBridge, didReceiveEvent payload: [String: Any])
    func httpBridge(_ bridge: KotoneHTTPBridge, log message: String)
}

public extension KotoneHTTPBridgeDelegate {
    func httpBridge(_ bridge: KotoneHTTPBridge, didReceiveEvent payload: [String: Any]) {}
    func httpBridge(_ bridge: KotoneHTTPBridge, log message: String) {}
}

public final class KotoneHTTPBridge {

    public static let shared = KotoneHTTPBridge()

    public weak var delegate: KotoneHTTPBridgeDelegate?

    /// `scripts/AddGecko.sh` が生成した設定。拡張機能と同じ値を使う。
    public private(set) var port: UInt16 = 0
    public private(set) var token: String = ""

    public var isRunning: Bool { listener != nil }
    /// 拡張機能が /poll に来ていれば true
    public private(set) var isExtensionConnected = false

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "kotone.httpbridge")

    /// Swift → 拡張機能 の送信待ち
    private var outbox: [[String: Any]] = []
    /// 最後に /poll が来た時刻。生存確認に使う。
    private(set) var lastPollAt: Date?

    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]

    private init() {}

    // MARK: - 起動

    /// 拡張機能と共有している設定ファイルを読む。
    ///
    /// 実行時にポートやトークンを受け渡す経路が無いため、
    /// ビルド時に生成した 1 つのファイルを両者が読む形にしている。
    /// アプリバンドル内なので読み取り専用で構わない。
    private func loadConfig() -> Bool {
        guard let dir = KotoneBridge.bundledExtensionURL else {
            log("拡張機能フォルダが見つかりません")
            return false
        }
        let url = dir.appendingPathComponent("kotone-config.js")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            log("kotone-config.js を読めません")
            return false
        }

        func value(of name: String) -> String? {
            guard let range = text.range(of: "\(name) = ") else { return nil }
            let rest = text[range.upperBound...]
            guard let end = rest.firstIndex(of: ";") else { return nil }
            return rest[..<end]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\t"))
        }

        guard let portText = value(of: "KOTONE_BRIDGE_PORT"),
              let parsed = UInt16(portText), parsed > 0,
              let tokenText = value(of: "KOTONE_BRIDGE_TOKEN"), !tokenText.isEmpty else {
            log("kotone-config.js の内容を解釈できません")
            return false
        }
        port = parsed
        token = tokenText
        return true
    }

    /// 設定ファイルのポートで待ち受ける。
    /// 失敗しても致命的ではない（正規経路の予備なので）。
    @discardableResult
    public func start() -> Bool {
        guard listener == nil else { return true }
        guard loadConfig() else { return false }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
            let listener = try NWListener(using: params, on: endpointPort)

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.log("listening on 127.0.0.1:\(self.port)")
                case .failed(let error):
                    self.log("listener failed: \(error)")
                    self.stop()
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            return true
        } catch {
            log("listener を作れませんでした: \(error)")
            return false
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isExtensionConnected = false
    }

    // MARK: - 送信

    // ------------------------------------------------------------------
    // 待ち方
    //
    // Swift にも await はあるが、相手が必ず返す保証は無い。
    // 拡張機能が死ぬと continuation を resume する者がいなくなり、
    // 永久に待ち続ける。rev.47 以前で実際にその状態を踏んだ。
    //
    // ただし固定秒数で諦めるのは筋が悪い。
    // resolveAudio に 25 秒と決め打ちしていたが、根拠のない数字だった。
    //
    // 拡張機能は 400ms ごとにポーリングしてくるので、
    // **生きているかどうかは分かる**。それを判定に使う。
    //
    //   ポーリングが来ている & 応答が無い  → 処理中。待ち続けてよい
    //   ポーリングが 3 秒来ていない        → 死んだ。即座に諦める
    //
    // これで「重い処理を待てる」と「死んだら即失敗」を両立できる。
    // 上限は暴走を止めるためだけの保険。
    // ------------------------------------------------------------------

    /// この時間ポーリングが来なければ、拡張機能が死んだとみなす。
    private static let livenessGrace: TimeInterval = 3

    /// どれだけ生きていても、これを超えたら諦める。
    private static let hardLimit: TimeInterval = 60

    /// 応答を待つ。拡張機能が /poll → /reply で返す。
    @discardableResult
    public func request(_ type: String, payload: [String: Any]? = nil) async throws -> Any? {
        guard isRunning else { throw KotoneBridgeError("HTTP ブリッジが起動していません") }

        let id = nextRequestId
        nextRequestId += 1
        var message: [String: Any] = ["type": type, "requestId": id]
        if let payload { message["payload"] = payload }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.pending[id] = continuation
                self.outbox.append(message)
            }
            // 拡張機能の生存を見ながら待つ。固定秒数では判断しない。
            Task { [weak self] in
                let started = Date()
                while true {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self else { return }

                    var reason: String?
                    var alreadyDone = false
                    self.queue.sync {
                        guard self.pending[id] != nil else { alreadyDone = true; return }

                        let waited = Date().timeIntervalSince(started)
                        if waited > Self.hardLimit {
                            reason = "\(Int(waited)) 秒待っても応答がありません"
                            return
                        }
                        guard let last = self.lastPollAt else {
                            reason = "拡張機能がまだ一度も接続していません"
                            return
                        }
                        let idle = Date().timeIntervalSince(last)
                        if idle > Self.livenessGrace {
                            reason = "拡張機能からのポーリングが \(Int(idle)) 秒途絶えています"
                        }
                    }
                    if alreadyDone { return }
                    guard let reason else { continue }   // 生きている。待ち続ける

                    self.queue.async {
                        guard let waiting = self.pending.removeValue(forKey: id) else { return }
                        waiting.resume(
                            throwing: KotoneBridgeError("\(type) を実行できません（\(reason)）")
                        )
                    }
                    return
                }
            }
        }
    }

    // MARK: - 再生制御
    //
    // ここが PlayerManager（ViviMusic の Views が使う契約）の土台になる。
    // content.js の commands と 1 対 1 で対応する。

    @discardableResult
    public func play() async throws -> Any? { try await request("play") }

    @discardableResult
    public func pause() async throws -> Any? { try await request("pause") }

    @discardableResult
    public func togglePlayPause() async throws -> Any? { try await request("toggle") }

    @discardableResult
    public func next() async throws -> Any? { try await request("next") }

    @discardableResult
    public func previous() async throws -> Any? { try await request("previous") }

    @discardableResult
    public func seek(to position: TimeInterval) async throws -> Any? {
        try await request("seek", payload: ["position": position])
    }

    @discardableResult
    public func setVolume(_ volume: Double) async throws -> Any? {
        try await request("setVolume", payload: ["volume": volume])
    }

    /// ページのループボタンを 1 回押す。off → all → one → off と巡回する。
    @discardableResult
    public func cycleRepeat() async throws -> Any? { try await request("cycleRepeat") }

    /// ループ状態を指定の値にする。必要な回数だけボタンを押す。
    @discardableResult
    public func setRepeat(_ mode: String) async throws -> Any? {
        try await request("setRepeat", payload: ["mode": mode])
    }

    /// ページのシャッフルボタンを押す。
    ///
    /// キューを持っているのはページ側なので、
    /// Kotone 側で並べ替えても実際には効かない。
    @discardableResult
    public func toggleShuffle() async throws -> Any? { try await request("toggleShuffle") }

    /// 音声 URL を取る。ページのコンテキストで fetch するので、
    /// Cookie と署名済み URL がそのまま使える。
    @discardableResult
    public func resolveAudio(videoId: String) async throws -> Any? {
        try await request("resolveAudio", payload: ["videoId": videoId])
    }

    /// URL をページに渡して再生させる。
    ///
    /// 受け取った URL をそのまま開く。組み立て直さない。
    /// ページ内遷移で済むので、ページ全体の読み直しが起きない。
    @discardableResult
    public func openURL(_ url: String) async throws -> Any? {
        try await request("openURL", payload: ["url": url])
    }

    /// ページ自身が持っている再生情報を調べる。ダウンロード経路の切り分け用。
    @discardableResult
    public func playerResponseInfo() async throws -> Any? {
        try await request("playerResponseInfo")
    }

    /// ページの現在状態を取る
    @discardableResult
    public func probe() async throws -> Any? { try await request("probe") }

    // MARK: - 接続処理

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(buffer) {
                self.handle(request, on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        // 起動ごとのトークンで照合する。外部からの接続は届かないが念のため。
        guard request.headers["x-kotone-token"] == token else {
            respond(connection, status: "403 Forbidden", body: ["error": "bad token"])
            return
        }

        switch request.path {
        case "/hello":
            isExtensionConnected = true
            log("拡張機能が接続しました: \(request.json?["version"] ?? "?")")
            respond(connection, status: "200 OK", body: ["ok": true])

        case "/event":
            if let payload = request.json {
                DispatchQueue.main.async {
                    self.delegate?.httpBridge(self, didReceiveEvent: payload)
                }
            }
            respond(connection, status: "200 OK", body: ["ok": true])

        case "/reply":
            if let json = request.json,
               let id = json["requestId"] as? Int,
               let continuation = pending.removeValue(forKey: id) {
                if let error = json["error"] as? String, !error.isEmpty {
                    continuation.resume(throwing: KotoneBridgeError(error))
                } else {
                    continuation.resume(returning: json["result"] ?? nil)
                }
            }
            respond(connection, status: "200 OK", body: ["ok": true])

        case "/poll":
            isExtensionConnected = true
            lastPollAt = Date()

            // 拡張機能からのイベントを同じ往復に相乗りさせる。
            // 接続数を半分にできる。
            if let events = request.json?["events"] as? [[String: Any]] {
                for event in events {
                    DispatchQueue.main.async {
                        self.delegate?.httpBridge(self, didReceiveEvent: event)
                    }
                }
            }

            // ------------------------------------------------------------
            // 即座に返す。溜まっていなければ空で返す。
            //
            // 以前は接続を保留して「来るまで待たせる」長時間ポーリングに
            // していたが、実測でブリッジが数分で死んだ。
            //
            //   19:14:05  拡張機能が接続しました
            //   19:18:36  最後の HTTP event
            //   19:23:05  以降すべてタイムアウト
            //
            // 保留した接続が回収されないまま溜まり、
            // /event も含めて一切通らなくなっていた。
            // 保留をやめれば、この失敗の仕方はしなくなる。
            // ------------------------------------------------------------
            let batch = outbox
            outbox.removeAll()
            respond(connection, status: "200 OK", body: ["messages": batch])

        default:
            respond(connection, status: "404 Not Found", body: ["error": "unknown path"])
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(json.count)\r\n"
        // 拡張機能の fetch は moz-extension:// 由来なので CORS が要る
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: *\r\n"
        head += "Connection: close\r\n\r\n"

        var data = Data(head.utf8)
        data.append(json)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.delegate?.httpBridge(self, log: message)
        }
    }
}

// MARK: - 最小の HTTP パーサ

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var json: [String: Any]? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return object as? [String: Any]
    }

    /// ヘッダと Content-Length ぶんの本文が揃っていれば組み立てる。
    init?(_ buffer: Data) {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        method = requestLine[0]
        path = requestLine[1].components(separatedBy: "?").first ?? requestLine[1]

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        self.headers = headers

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let available = buffer[separator.upperBound...]
        guard available.count >= expected else { return nil }
        body = Data(available.prefix(expected))
    }
}
