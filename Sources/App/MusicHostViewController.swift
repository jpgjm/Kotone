//
//  MusicHostViewController.swift
//  Kotone — ViviMusic の SwiftUI UI をホストする
//
//  ⚠️ 現在ビルド対象外。project.yml の Sources/App の excludes で除外している。
//
//     RootView / LibraryStore / DownloadManager / PlaylistStore /
//     GoogleAuthService / CookieAuthService / TogetherManager を参照するが、
//     これらは Sources/Vivi/{Views,Services} にあり、まだ組み込んでいない。
//     組み込みは Sources/Vivi/Core のみ（Song などのモデル定義）。
//
//     Views / Services を組み込む段階で除外を外す。
//     残っている未解決参照は docs/VIVIMUSIC.md を参照。
//
//  ---------------------------------------------------------------------
//  構成
//
//    [SwiftUI RootView]        ← ViviMusic の Views をそのまま使う
//    [InnerTube (Swift)]       ← 検索・ブラウズ。ViviMusic のまま
//         ↓ videoId
//    [PlayerManager]           ← Kotone の新規実装
//         ↓ KotoneHTTPBridge
//    [Gecko / music.youtube.com]  ← 背面に隠して再生だけさせる
//         ↓ MediaSession
//    [PlayerManager に反映]
//
//  GeckoView はビュー階層から外さない。完全に外すとタイマーが絞られ、
//  再生が止まる恐れがあるため、SwiftUI の背面に敷いたままにする
//  （WKWebView で同じ議論をしたときの結論と同じ）。
//  ---------------------------------------------------------------------
//

import SwiftUI
import UIKit

final class MusicHostViewController: UIViewController {

    /// 背面に置く Gecko の画面。再生を担当する。
    private let browser: BrowserViewController

    /// ブラウザ画面を包むナビゲーション。
    ///
    /// これが無いと `navigationController` が nil になり、
    /// 🧩 アドオン / 📋 測定ログ / ✓ 診断の各ボタンが
    /// `pushViewController` を呼んでも**何も起きない**。
    /// rev.43 で実機報告があった症状の原因。
    private let browserNav: UINavigationController
    private var hosting: UIHostingController<AnyView>?

    init(browser: BrowserViewController) {
        self.browser = browser
        self.browserNav = UINavigationController(rootViewController: browser)
        self.browserNav.navigationBar.prefersLargeTitles = false
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 1. Gecko を背面に敷く。見えないが階層には残す。
        addChild(browserNav)
        browserNav.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browserNav.view)
        NSLayoutConstraint.activate([
            browserNav.view.topAnchor.constraint(equalTo: view.topAnchor),
            browserNav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browserNav.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browserNav.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        browserNav.didMove(toParent: self)
        setBrowserVisible(false)

        // 2. SwiftUI をその上に重ねる
        let root = RootView()
            .environmentObject(PlayerManager.shared)
            .environmentObject(LibraryStore.shared)
            .environmentObject(DownloadManager.shared)
            .environmentObject(PlaylistStore.shared)
            .environmentObject(GoogleAuthService.shared)
            .environmentObject(CookieAuthService.shared)
            .environmentObject(TogetherManager.shared)

        let hosting = UIHostingController(rootView: AnyView(root))
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosting.didMove(toParent: self)
        self.hosting = hosting

        // 3. 設定画面からブラウザ画面へ切り替えられるようにする
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowBrowser),
            name: .kotoneShowBrowser,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(returnToMusicUI),
            name: .kotoneShowMusicUI,
            object: nil
        )

        // ロック画面 / コントロールセンター / AirPods を有効にする。
        // AVAudioSession を .playback にするのもここ。
        // これが無いと画面を消した時点で音が止まる。
        NowPlayingCenter.shared.attach(to: PlayerManager.shared)

        MeasurementLog.shared.append(.player, "[PM] SwiftUI UI を表示（Gecko は背面）")
    }

    // MARK: - 表示の切り替え

    /// 画面の切り替え。Gecko はどちらでも階層に残る。
    private func setBrowserVisible(_ visible: Bool) {
        browserNav.view.alpha = visible ? 1 : 0.02
        browserNav.view.isUserInteractionEnabled = visible
        hosting?.view.isHidden = visible

        // 音楽 UI に戻るときは、押していた画面（アドオンやログ）を畳んでおく。
        // 次に開いたときブラウザから始まる方が分かりやすい。
        if !visible {
            browserNav.popToRootViewController(animated: false)
        }
    }

    /// 設定画面の「ブラウザ画面を開く」から呼ばれる。
    ///
    /// 当初は 3 本指タップにしていたが、
    ///   * 存在に気づけない
    ///   * SwiftUI のスクロールと競合する
    ///   * 誤爆する
    /// ため、設定画面の明示的なボタンに変えた。
    private var showingBrowser = false

    @objc private func handleShowBrowser() {
        showingBrowser = true
        setBrowserVisible(true)
        MeasurementLog.shared.append(.player, "[PM] ブラウザ画面へ切り替え")
    }

    /// ブラウザ画面から SwiftUI へ戻る。
    /// ブラウザ側のツールバー左端のボタンから呼ばれる。
    @objc func returnToMusicUI() {
        showingBrowser = false
        setBrowserVisible(false)
        MeasurementLog.shared.append(.player, "[PM] SwiftUI UI へ戻る")
    }
}
