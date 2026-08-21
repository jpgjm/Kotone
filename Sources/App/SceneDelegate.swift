//
//  SceneDelegate.swift
//  Kotone
//
//  クラス名は project.yml の
//    UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).SceneDelegate
//  と対応している。リネーム時はモジュール名が変わるだけなので触らなくてよい。
//
//  ---------------------------------------------------------------------
//  ViviMusic の SwiftUI UI を前面に、Gecko を背面に置く。
//
//  Gecko はビュー階層から外さない。完全に外すとタイマーが絞られて
//  再生が止まる恐れがあるため、alpha を落として敷いたままにする。
//
//  測定用のブラウザ画面は捨てずに残してある。
//  **設定 → 診断 → ブラウザ画面を開く** で切り替わり、
//  🧩 からブリッジ診断と PlayerManager テストを続けられる。
//  戻るときはブラウザ画面のツールバー左端の家アイコン。
//  これまで何度もこの画面のログで原因を特定してきたため、
//  Views を載せた直後こそ切り分け手段が要る。
//  ---------------------------------------------------------------------
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)

        let browser = BrowserViewController()
        window.rootViewController = MusicHostViewController(browser: browser)

        window.makeKeyAndVisible()
        self.window = window
    }
}
