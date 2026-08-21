//
//  UserAgentPolicy.swift
//  Kotone
//
//  URL ごとに UA を決める。Reynard の
//  browser/Reynard/Client/SessionManagement/Settings/WebsiteMode/UserAgentPolicy.swift
//  から、本プロジェクトに必要な部分だけを移植したもの。
//
//  ------------------------------------------------------------------------
//  なぜ URL ごとに切り替えるのか
//
//  addons.mozilla.org (AMO) は **デスクトップ UA だとインストールボタンを
//  出さない**。Firefox for Android 向けのページでのみ
//  「Add to Firefox」が現れるため、AMO では Android UA を強制する。
//
//  moz-extension:// （アドオンの設定ページ）も Android UA でないと
//  レイアウトが崩れる。
//
//  それ以外（music.youtube.com など）はデスクトップ UA を使う。
//  デスクトップ版の方がプレイヤーの機能が揃っているため。
//  ------------------------------------------------------------------------
//
//  Reynard のコメントにあるとおり、Gecko + iOS はサイト側が想定しない
//  組み合わせなので、素直に Linux / Android を名乗る。
//

import Foundation
import GeckoView

struct UserAgentConfiguration {
    let userAgent: String
    let platform: String
    let appVersion: String
    /// 0 = mobile, 1 = desktop。userAgentMode と viewportMode の両方に使う。
    let mode: Int
    /// ユーザーのデスクトップ設定より優先してモバイルを強制したか
    let forcedMobile: Bool
}

enum UserAgentPolicy {

    /// Gecko のメジャーバージョン（例: "153"）
    private static var majorVersion: String {
        GeckoRuntime.version
            .split(whereSeparator: { !$0.isNumber })
            .first
            .map(String.init) ?? "0"
    }

    static func configuration(for url: String, prefersDesktop: Bool) -> UserAgentConfiguration {
        // AMO はアドオンをインストールさせるために Android UA が必須。
        if host(of: url) == "addons.mozilla.org" {
            return make(desktop: false, forcedMobile: true)
        }
        // アドオンの設定ページも Android UA でないと正しく動かない。
        if url.hasPrefix("moz-extension://") {
            return make(desktop: false, forcedMobile: true)
        }
        return make(desktop: prefersDesktop, forcedMobile: false)
    }

    private static func make(desktop: Bool, forcedMobile: Bool) -> UserAgentConfiguration {
        let v = majorVersion
        return UserAgentConfiguration(
            userAgent: desktop
                ? "Mozilla/5.0 (X11; Linux x86_64; rv:\(v).0) Gecko/20100101 Firefox/\(v).0"
                : "Mozilla/5.0 (Android 15; Mobile; rv:\(v).0) Gecko/\(v).0 Firefox/\(v).0",
            platform: desktop ? "Linux x86_64" : "Linux armv81",
            appVersion: desktop ? "5.0 (X11)" : "5.0 (Android 15)",
            mode: desktop ? 1 : 0,
            forcedMobile: forcedMobile
        )
    }

    static func settings(for url: String, prefersDesktop: Bool) -> GeckoSessionSettings {
        let c = configuration(for: url, prefersDesktop: prefersDesktop)
        return GeckoSessionSettings(
            websiteMode: WebsiteModeSetting(
                userAgentOverride: c.userAgent,
                platformOverride: c.platform,
                appVersionOverride: c.appVersion,
                oscpuOverride: c.platform,
                buildIDOverride: nil,
                userAgentMode: c.mode,
                viewportMode: c.mode
            ),
            pageZoom: .default,
            language: LanguageSetting(codes: ["ja", "en-US", "en"])
        )
    }

    private static func host(of url: String) -> String? {
        URL(string: url)?.host
    }
}
