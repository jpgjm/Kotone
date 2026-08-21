//
//  Kotone-Bridging-Header.h
//
//  Reynard の browser/Reynard/Bridging/Reynard-Bridging-Header.h と同等。
//  Phase 0-B2 で有効化する（project.yml の SWIFT_OBJC_BRIDGING_HEADER の
//  コメントを外す）。
//
//  ------------------------------------------------------------------------
//  注意: Reynard の browser/GeckoView/View/GeckoView.h は使わないこと。
//
//  あちらは #import "TSUtils.h" を含むが TSUtils.h はリポジトリに存在しない。
//  実体は TrollStore の TSUtil.m 由来のユーティリティで、
//  browser/Reynard/Shared/Utils.h にリネームされている。
//  GeckoView.h は Reynard 本家でも Headers ビルドフェーズに登録されておらず
//  （project.pbxproj の PBXHeadersBuildPhase は files = () で空）、
//  一度もコンパイルされないため誰も気づかないまま残っている。
//  project.yml 側で除外済み。
//  ------------------------------------------------------------------------
//
//  以下のうち <GeckoView/...> の 2 つは Gecko の EXPORTS.GeckoView ヘッダで、
//  scripts/fetch-headers.sh が $(GECKO_DIST)/include/GeckoView/ に生成する。
//

#ifndef Kotone_Bridging_Header_h
#define Kotone_Bridging_Header_h

// --- Reynard 由来（Sources/ に配置したもの）----------------------------------
#import "ExtensionBridge.h"        // Sources/Helper/
#import "GeckoRuntimeBridge.h"     // Sources/GeckoView/Runtime/
#import "UIKit+Private.h"          // Sources/Bridging/
#import "Utils.h"                  // Sources/Shared/   (旧 TSUtils.h)

// --- JIT（任意）---------------------------------------------------------------
//
// 0-B2 では JIT を含めない方針。理由:
//   Sources/JIT/ は libidevice_ffi.a を必要とするが、これは
//   tools/development/build-idevice.sh が Rust でビルドする成果物で、
//   Reynard のリポジトリにも配布 IPA にも含まれていない
//   （静的ライブラリはバイナリに埋め込まれるため抽出もできない）。
//
// 幸い JIT の結合は閉じている。Sources/{GeckoView,Helper,Shared} から
// JIT シンボルへの参照は 0 件で、唯一の接点がこの import だった。
// Gecko は JIT なしでも動作する（SpiderMonkey がインタプリタになり遅いだけ）。
//
// JIT を入れるときは KOTONE_ENABLE_JIT を定義する。
#if defined(KOTONE_ENABLE_JIT)
#import "JITEnabler.h"             // Sources/JIT/
#endif

// --- Gecko 由来（scripts/fetch-headers.sh が生成）------------------------------
#import <GeckoView/GeckoViewSwiftSupport.h>
#import <GeckoView/IOSBootstrap.h>
// IOSBootstrap.h が <GeckoView/GeckoViewRuntimeSupport.h> を推移的に読む

#endif /* Kotone_Bridging_Header_h */
