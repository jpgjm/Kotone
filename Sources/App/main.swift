//
//  main.swift
//  Kotone
//
//  @main は使わない。Gecko は UIApplicationMain ではなく
//  GeckoRuntime.main() から起動する必要がある。
//  XPCOM の初期化を経てから UIKit のイベントループに入るため。
//
//  Reynard の browser/Reynard/main.swift と同じ構造。
//  ただし以下は移植していない:
//    * UserDataMigration        … Reynard のブラウザ設定移行
//    * ApplicationMenuBuilder   … ブラウザメニュー
//    * JITController.start()    … JIT は 0-B2 では無効（docs/PLACEMENT.md）
//    * configureUnsandboxedAppDataDirectories() … iOS 13 + TrollStore 用
//
//  JIT を有効にするときは KOTONE_ENABLE_JIT を定義し、
//  GeckoRuntime.main の直前で JITController.shared.start() を呼ぶ。
//

import Foundation
import GeckoView
import UIKit

#if KOTONE_ENABLE_JIT
JITController.shared.start()
#endif

// この呼び出しは戻らない。内部で UIApplicationMain 相当に入る。
GeckoRuntime.main(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
