//
//  SettingsView.swift
//  ViviMusic
//
//  設定と診断の入口。現状は診断まわりが中心。
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var cookieAuth: CookieAuthService

    @State private var showLogin = false
    @State private var showCookieLogin = false
    @State private var showTogether = false
    @State private var showEqualizer = false
    @ObservedObject private var equalizer = EqualizerSettings.shared
    @EnvironmentObject private var together: TogetherManager
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteAllConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showCookieLogin = true
                    } label: {
                        HStack {
                            Label("YouTube Music",
                                  systemImage: cookieAuth.isSignedIn
                                      ? "music.note.house.fill"
                                      : "music.note.house")
                            Spacer()
                            Text(cookieAuth.isSignedIn
                                 ? (cookieAuth.accountName ?? "ログイン済み")
                                 : "未ログイン")
                                .font(.footnote)
                                .foregroundStyle(cookieAuth.isSignedIn ? .green : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("アカウント (ホーム・検索用)")
                } footer: {
                    Text(cookieAuth.isSignedIn
                         ? "ホームや検索がアカウントに合わせた内容になります。"
                         : "未ログインだと、ホームは誰にでも同じ内容 "
                           + "(匿名フィード) になります。ログインすると "
                           + "「毎日のおすすめ」などが表示されます。")
                }

                Section {
                    Button {
                        showLogin = true
                    } label: {
                        HStack {
                            Label("Google アカウント",
                                  systemImage: auth.isSignedIn
                                      ? "person.crop.circle.badge.checkmark"
                                      : "person.crop.circle")
                            Spacer()
                            Text(auth.isSignedIn ? "ログイン済み" : "未ログイン")
                                .font(.footnote)
                                .foregroundStyle(auth.isSignedIn ? .green : .secondary)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("アカウント (再生用)")
                } footer: {
                    Text(auth.isSignedIn
                         ? "ログイン中です。再生 URL の取得に使われます。"
                         : "YouTube が bot 判定で再生を拒否する場合、"
                           + "ログインすると解消します。上のログインとは別枠です。")
                }

                Section {
                    Button {
                        showEqualizer = true
                    } label: {
                        HStack {
                            Label("イコライザー", systemImage: "slider.vertical.3")
                            Spacer()
                            Text(equalizer.isEnabled ? "オン" : "オフ")
                                .font(.footnote)
                                .foregroundStyle(equalizer.isEnabled ? Theme.accent : .secondary)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("音質")
                } footer: {
                    Text("10 バンドのグラフィックイコライザーです。"
                         + "再生中でもすぐに反映されます。")
                }

                Section {
                    Button {
                        showTogether = true
                    } label: {
                        HStack {
                            Label("Listen Together", systemImage: "person.2.fill")
                            Spacer()
                            Text(together.state.label)
                                .font(.footnote)
                                .foregroundStyle(together.state.isInRoom ? .green : .secondary)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text("一緒に聴く")
                } footer: {
                    Text("友達とリアルタイムで同じ曲を聴けます。"
                         + "Android 版の VIVI Music とも一緒に聴けます。")
                }

                Section("ストレージ") {
                    LabeledContent("ダウンロード済み",
                                   value: "\(downloads.downloadedSongs.count) 曲")
                    LabeledContent("使用容量", value: downloads.totalSizeText())

                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Label("ダウンロードをすべて削除", systemImage: "trash")
                    }
                    .disabled(downloads.downloadedSongs.isEmpty)
                }

                Section("ライブラリ") {
                    LabeledContent("プレイリスト", value: "\(playlists.playlists.count) 件")
                    LabeledContent("お気に入り", value: "\(library.favorites.count) 曲")
                    LabeledContent("再生履歴", value: "\(library.history.count) 曲")
                }

                Section {
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("診断ログ (\(EventLog.count()))", systemImage: "doc.text.magnifyingglass")
                    }
                    // Kotone: PoToken / StreamProbe は Gecko 構成では使わない。
                    // 署名デコードも BotGuard も公式プレイヤー側が担うため、
                    // 表示する状態が存在しない。

                    // Kotone: 測定用のブラウザ画面へ切り替える。
                    //
                    // 再生を担っている Gecko を直接見られる画面で、
                    // ブリッジの疎通確認・アドオン管理・PlayerManager の
                    // 単体テスト・詳細ログの書き出しができる。
                    //
                    // Kotone の型を Views から直接参照すると層が混ざるので、
                    // 通知で疎結合にしてある（Notification.Name.kotoneShowBrowser）。
                    // 戻るときはブラウザ画面のツールバー左端の家アイコン。
                    Button {
                        dismiss()
                        NotificationCenter.default.post(
                            name: Notification.Name("Kotone.showBrowser"),
                            object: nil
                        )
                    } label: {
                        Label("ブラウザ画面を開く", systemImage: "safari")
                    }
                } header: {
                    Text("診断")
                } footer: {
                    Text("再生やダウンロードの失敗はここに記録されます。"
                         + "不具合を報告するときは、ログを書き出して添付してください。\n\n"
                         + "「ブラウザ画面を開く」では、再生を担っている Gecko を"
                         + "直接操作できます。ブリッジの疎通確認やアドオンの管理、"
                         + "詳細ログの書き出しはそちらから行えます。"
                         + "戻るときは左上の家アイコンを押してください。")
                }

                Section("このアプリ") {
                    CopyableInfoRow(label: "バージョン", value: appVersion)
                    CopyableInfoRow(label: DeviceInfo.systemName,
                                    value: DeviceInfo.osVersion)
                    CopyableInfoRow(label: "機種",
                                    value: DeviceInfo.machineIdentifier)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
            }
            .sheet(isPresented: $showCookieLogin) {
                CookieLoginView()
            }
            .sheet(isPresented: $showTogether) {
                TogetherView()
            }
            .sheet(isPresented: $showEqualizer) {
                EqualizerView()
            }
            .confirmationDialog("ダウンロードをすべて削除しますか?",
                                isPresented: $showDeleteAllConfirm,
                                titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) {
                    for song in downloads.downloadedSongs {
                        downloads.delete(song.id)
                    }
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
