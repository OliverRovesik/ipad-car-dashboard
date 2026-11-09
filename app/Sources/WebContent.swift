import Foundation

// 页面内置：启动时把 bundle（或后台同步下来的副本）里的 4 个文件拼成一个自包含 HTML。
// 用 loadHTMLString + 真实 https baseURL，而不是 loadFileURL：file:// 是 opaque origin，
// GLB 的 blob: fetch 和定位的 secure context 都会出问题；baseURL 保持线上 origin，
// 定位权限、天气 CORS、导航白名单的行为与直接加载线上页面完全一致。
enum WebContent {
  static let baseURL = URL(string: "https://oliverrovesik.github.io/ipad-car-dashboard/")!
  static let page = "dashboard-gps.html"
  static let assets = ["vendor/three.min.js", "vendor/GLTFLoader.js", "model/fiesta.data.js"]
  static var paths: [String] { [page] + assets }

  static var syncedDir: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("CarDash/web", isDirectory: true)
  }
  static var bundleDir: URL {
    Bundle.main.bundleURL.appendingPathComponent("web", isDirectory: true)
  }

  // 逐文件回落，而不是整目录二选一：同步下来的新 HTML 要能配 bundle 里的旧资产。
  static func resolve(_ path: String) -> URL? {
    let s = syncedDir.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: s.path) { return s }
    let b = bundleDir.appendingPathComponent(path)
    return FileManager.default.fileExists(atPath: b.path) ? b : nil
  }

  static func sourceLabel(of url: URL) -> String {
    url.path.hasPrefix(syncedDir.path) ? "synced" : "bundle"
  }

  static func compose() -> String? {
    guard let htmlURL = resolve(page),
          let html = try? String(contentsOf: htmlURL, encoding: .utf8) else {
      cardashTrace("compose miss: no readable \(page)")
      return nil
    }
    let source = sourceLabel(of: htmlURL)
    let out = NSMutableString(string: html)
    var inlined = 0
    let re = try? NSRegularExpression(pattern: "<script src=\"([^\"]+)\"></script>")
    let matches = re?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
    // 逆序替换，前面 match 的 range 才不会因为长度变化而失效
    for m in matches.reversed() {
      guard let r = Range(m.range(at: 1), in: html) else { continue }
      let path = String(html[r])
      guard let jsURL = resolve(path),
            let js = try? String(contentsOf: jsURL, encoding: .utf8) else { continue }
      // 只逃这一处：内联脚本里出现 </script 会提前关掉标签。全面转义反斜杠反而会破坏 JS 字符串。
      let safe = js.replacingOccurrences(of: "</script", with: "<\\/script")
      out.replaceCharacters(in: m.range, with: "<script>" + safe + "</script>")
      inlined += 1
    }
    let result = out as String
    cardashTrace("compose ok source=\(source) bytes=\(result.utf8.count) inlined=\(inlined)/\(assets.count)")
    return result
  }
}