import Foundation

// 后台同步：启动永远先用本地副本（秒开、飞行模式可用），之后悄悄探测线上有没有更新。
// 他推送的 dashboard 改动在下次启动生效，不用为改界面重新签名装 ipa。
// 三条硬规矩：失败静默、绝不阻塞启动、绝不在行驶中 reload。
enum WebSync {
  // ephemeral：不落盘缓存，也不去污染 WKWebView 自己的缓存
  private static let session = URLSession(configuration: .ephemeral)

  // validator 放在同步目录外面，这样整体换目录时不用跟着搬，也不会被半路失败带进不一致状态
  private static var metaURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("CarDash/web-meta.json")
  }

  static func run() {
    Task.detached(priority: .utility) { await sync() }
  }

  private static func sync() async {
    var meta = readMeta()
    var updates: [String: Data] = [:]
    var downloaded = 0
    let html = WebContent.page

    do {
      // 1. 他日常改的就是这个 HTML，直接条件 GET（60 KB 级）
      let (code, body, v) = try await fetch(WebContent.baseURL.appendingPathComponent(html),
                                           method: "GET", validators: meta[html])
      if code == 304 {
        cardashTrace("sync current (304)")
        writeMeta(meta)
        return
      }
      guard code == 200 else { cardashTrace("sync error \(html) status=\(code)"); return }
      meta[html] = (meta[html] ?? [:]).merging(v) { _, new in new }

      let held = WebContent.resolve(html).flatMap { try? Data(contentsOf: $0) }
      if held == body {
        // 首次启动走这条：bundle 里的副本就是线上这一版，只记 validator，一个资产都不下
        cardashTrace("sync same-content bytes=\(body.count)")
        writeMeta(meta)
        return
      }
      updates[html] = body
      downloaded += body.count

      // 2. 只有 HTML 真变了才探测 3 个大资产：HEAD 不带 body，对得上就跳过
      for path in WebContent.assets {
        let url = WebContent.baseURL.appendingPathComponent(path)
        let old = meta[path]
        let (hc, _, hv) = try await fetch(url, method: "HEAD", validators: nil)
        guard hc == 200 else { cardashTrace("sync error head \(path) status=\(hc)"); continue }
        let merged = (old ?? [:]).merging(hv) { _, new in new }
        meta[path] = merged

        let remoteSize = Int(hv["length"] ?? "")
        let localSize = WebContent.resolve(path)
          .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
        let same: Bool
        if let o = old, o["etag"] != nil || o["lastModified"] != nil {
          same = (o["etag"] == nil || o["etag"] == merged["etag"])
              && (o["lastModified"] == nil || o["lastModified"] == merged["lastModified"])
        } else {
          // 首次运行没有 validator：长度和 bundle 里的一致就不下那 3.96 MB
          same = remoteSize != nil && remoteSize == localSize
        }
        if same { continue }

        let (gc, gb, gv) = try await fetch(url, method: "GET", validators: nil)
        guard gc == 200 else { cardashTrace("sync error get \(path) status=\(gc)"); continue }
        meta[path] = merged.merging(gv) { _, new in new }
        updates[path] = gb
        downloaded += gb.count
      }

      // 3. 原子换目录：先把当前持有的 4 个文件全量拷进 web.tmp、覆盖变更项，再整体换名。
      //    逐文件写入会让新 HTML 配上旧模型，整目录换名才不会。
      try stage(updates)
      writeMeta(meta)
      cardashTrace("sync updated paths=\(updates.keys.sorted().joined(separator: ",")) bytes=\(downloaded)")
    } catch {
      // 半途失败不写 meta：validator 记了新值而文件没换，下次就再也不会重试了
      cardashTrace("sync error \(error.localizedDescription)")
    }
  }

  private static func stage(_ updates: [String: Data]) throws {
    let fm = FileManager.default
    let dir = WebContent.syncedDir
    let parent = dir.deletingLastPathComponent()
    let tmp = parent.appendingPathComponent("web.tmp", isDirectory: true)
    let old = parent.appendingPathComponent("web.old", isDirectory: true)
    try? fm.removeItem(at: tmp)
    try? fm.removeItem(at: old)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

    for path in WebContent.paths {
      let dst = tmp.appendingPathComponent(path)
      try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let data = updates[path] {
        try data.write(to: dst)
      } else if let src = WebContent.resolve(path) {
        try fm.copyItem(at: src, to: dst)
      } else {
        throw NSError(domain: "cardash.websync", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "no local copy of \(path)"])
      }
    }
    if fm.fileExists(atPath: dir.path) { try fm.moveItem(at: dir, to: old) }
    try fm.moveItem(at: tmp, to: dir)
    try? fm.removeItem(at: old)
  }

  private static func fetch(_ url: URL, method: String,
                            validators: [String: String]?) async throws -> (Int, Data, [String: String]) {
    var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    r.httpMethod = method
    if let e = validators?["etag"] { r.setValue(e, forHTTPHeaderField: "If-None-Match") }
    if let m = validators?["lastModified"] { r.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
    let (data, resp) = try await session.data(for: r)
    guard let h = resp as? HTTPURLResponse else { return (-1, data, [:]) }
    var v: [String: String] = [:]
    // 304 不一定回显 validator，缺的就沿用旧值（调用方负责 merge）
    if let e = h.value(forHTTPHeaderField: "ETag") { v["etag"] = e }
    if let m = h.value(forHTTPHeaderField: "Last-Modified") { v["lastModified"] = m }
    if let l = h.value(forHTTPHeaderField: "Content-Length") { v["length"] = l }
    return (h.statusCode, data, v)
  }

  private static func readMeta() -> [String: [String: String]] {
    guard let d = try? Data(contentsOf: metaURL),
          let m = try? JSONDecoder().decode([String: [String: String]].self, from: d) else { return [:] }
    return m
  }

  private static func writeMeta(_ m: [String: [String: String]]) {
    guard let d = try? JSONEncoder().encode(m) else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? d.write(to: metaURL, options: .atomic)
  }
}