import Foundation
import MediaPlayer
import WebKit
import CryptoKit

// 歌词桥：只读 Music App 的当前曲目/进度（系统共享的 now-playing 状态），不碰音频流。
// 歌词从 LRCLIB 取同步 LRC，缓存到 Application Support，页面负责按时间轴滚动。
final class LyricsBridge {
  static let shared = LyricsBridge()

  private struct CachedLine: Codable {
    let t: Double
    let text: String
  }

  private struct CachedLyrics: Codable {
    let title: String
    let artist: String
    let duration: Double
    let status: String
    let lines: [CachedLine]
    let fetchedAt: Double
  }

  private struct LRCLibTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?
  }

  private weak var web: WKWebView?
  private var timer: Timer?
  private var authRequested = false
  private var authorized = false
  private var currentKey = ""
  private var status = "idle"
  private var lines: [CachedLine] = []
  private var title = ""
  private var artist = ""
  private var album = ""
  private var duration: Double = 0
  private var lastFullSignature = ""
  private var lyricsTask: URLSessionDataTask?

  private let player = MPMusicPlayerController.systemMusicPlayer

  private lazy var cacheDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("CarDash/lyrics", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  private init() {}

  // MARK: - 生命周期

  func start(_ view: WKWebView) {
    web = view
    lastFullSignature = ""

    #if targetEnvironment(simulator)
    pushDemo()
    return
    #endif

    if timer == nil {
      let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
      t.tolerance = 0.2
      RunLoop.main.add(t, forMode: .common)
      timer = t
    }
    ensureAuthorization()
    if authorized { tick() }
  }

  private func ensureAuthorization() {
    if authRequested { return }
    authRequested = true
    switch MPMediaLibrary.authorizationStatus() {
    case .authorized:
      authorized = true
    case .notDetermined:
      MPMediaLibrary.requestAuthorization { [weak self] st in
        DispatchQueue.main.async {
          self?.authorized = (st == .authorized)
          if self?.authorized == true {
            self?.tick()
          } else {
            self?.status = "denied"
            self?.pushFull(force: true)
          }
        }
      }
    default:
      authorized = false
      status = "denied"
      pushFull(force: true)
    }
  }

  // MARK: - 轮询

  private func tick() {
    guard authorized else { return }
    let state = player.playbackState
    let playing = (state == .playing)

    guard let item = player.nowPlayingItem else {
      resetTrack()
      return
    }

    let t = item.title ?? ""
    let a = item.artist ?? ""
    let al = item.albumTitle ?? ""
    let d = item.playbackDuration
    let key = "\(t)|\(a)|\(al)|\(Int(d.rounded()))"

    if key != currentKey {
      currentKey = key
      title = t
      artist = a
      album = al
      duration = d
      lines = []
      status = "loading"
      pushFull(force: true)
      loadLyrics()
    }

    let pos = max(0, player.currentPlaybackTime)
    pushSync(playing: playing, position: pos, rate: playing ? 1.0 : 0.0)
  }

  private func resetTrack() {
    guard !currentKey.isEmpty || status != "idle" else { return }
    currentKey = ""
    title = ""
    artist = ""
    album = ""
    duration = 0
    lines = []
    status = "idle"
    lyricsTask?.cancel()
    pushFull(force: true)
  }

  // MARK: - 歌词获取

  private func loadLyrics() {
    guard !currentKey.isEmpty else { return }
    title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    album = album.trimmingCharacters(in: .whitespacesAndNewlines)

    if let c = readCache(key: currentKey) {
      let age = Date().timeIntervalSince1970 - c.fetchedAt
      if c.status == "ok", !c.lines.isEmpty {
        lines = c.lines
        status = "ok"
        pushFull(force: true)
        return
      }
      if c.status == "none", age < 7 * 86400 {
        lines = []
        status = "none"
        pushFull(force: true)
        return
      }
    }
    fetchLyrics()
  }

  private func fetchLyrics() {
    lyricsTask?.cancel()
    var comps = URLComponents(string: "https://lrclib.net/api/search")!
    var items = [URLQueryItem(name: "track_name", value: title)]
    if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
    if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
    comps.queryItems = items
    guard let url = comps.url else {
      finish(key: currentKey, lines: [], status: "error")
      return
    }

    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue("CarDash/1.2 (personal iPad car dashboard)", forHTTPHeaderField: "User-Agent")
    let key = currentKey
    let wantTitle = title
    let wantArtist = artist
    let wantDuration = duration

    lyricsTask = URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
      guard let self = self else { return }
      if let e = err, (e as NSError).code == NSURLErrorCancelled { return }
      DispatchQueue.main.async {
        guard key == self.currentKey else { return }
        if err != nil || data == nil {
          self.finish(key: key, lines: [], status: "error")
          return
        }
        let tracks = (try? JSONDecoder().decode([LRCLibTrack].self, from: data!)) ?? []
        var bestLines: [CachedLine] = []
        var bestScore = Double.greatestFiniteMagnitude
        for t in tracks {
          guard let synced = t.syncedLyrics, !synced.isEmpty, t.instrumental != true else { continue }
          let parsed = LyricsBridge.parseLRC(synced)
          guard !parsed.isEmpty else { continue }
          var score = 1000.0
          if let d = t.duration, wantDuration > 0 { score = abs(d - wantDuration) }
          if let n = t.trackName, n.caseInsensitiveCompare(wantTitle) == .orderedSame { score -= 20 }
          if let n = t.artistName, n.caseInsensitiveCompare(wantArtist) == .orderedSame { score -= 20 }
          if score < bestScore {
            bestScore = score
            bestLines = parsed
          }
        }
        if bestLines.isEmpty {
          self.finish(key: key, lines: [], status: "none")
        } else {
          self.finish(key: key, lines: bestLines, status: "ok")
        }
      }
    }
    lyricsTask?.resume()
  }

  private func finish(key: String, lines: [CachedLine], status: String) {
    guard key == currentKey else { return }
    self.lines = lines
    self.status = status
    if status == "ok" || status == "none" {
      writeCache(key: key, status: status, lines: lines)
    }
    pushFull(force: true)
    cardashTrace("lyrics \(status) title=\(title) lines=\(lines.count)")
  }

  // MARK: - LRC

  private static let timeTag = try! NSRegularExpression(
    pattern: "\\[(\\d{1,3}):(\\d{1,2}(?:\\.\\d{1,3})?)\\]"
  )

  private static func parseLRC(_ raw: String) -> [CachedLine] {
    var offset = 0.0
    let all = raw.components(separatedBy: .newlines)
    for line in all {
      let s = line.trimmingCharacters(in: .whitespaces)
      if s.lowercased().hasPrefix("[offset:"), s.hasSuffix("]") {
        let v = s.dropFirst(8).dropLast()
        offset = (Double(v.trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
      }
    }

    var out: [CachedLine] = []
    for line in all {
      let ns = line as NSString
      let full = NSRange(location: 0, length: ns.length)
      let matches = timeTag.matches(in: line, range: full)
      guard !matches.isEmpty else { continue }
      let text = timeTag.stringByReplacingMatches(in: line, range: full, withTemplate: "")
        .trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      for m in matches {
        guard let mm = Int(ns.substring(with: m.range(at: 1))),
              let ss = Double(ns.substring(with: m.range(at: 2))) else { continue }
        let t = max(0, Double(mm) * 60 + ss - offset)
        out.append(CachedLine(t: t, text: text))
      }
    }
    out.sort { $0.t < $1.t }

    var seen = Set<String>()
    var uniq: [CachedLine] = []
    for l in out {
      let k = String(format: "%.2f", l.t) + "|" + l.text
      if seen.insert(k).inserted { uniq.append(l) }
    }
    return uniq
  }

  // MARK: - 缓存

  private func hash(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func cacheURL(_ key: String) -> URL {
    cacheDir.appendingPathComponent(hash(key) + ".json")
  }

  private func readCache(key: String) -> CachedLyrics? {
    guard let data = try? Data(contentsOf: cacheURL(key)) else { return nil }
    return try? JSONDecoder().decode(CachedLyrics.self, from: data)
  }

  private func writeCache(key: String, status: String, lines: [CachedLine]) {
    let c = CachedLyrics(title: title, artist: artist, duration: duration,
                         status: status, lines: lines,
                         fetchedAt: Date().timeIntervalSince1970)
    if let data = try? JSONEncoder().encode(c) {
      try? data.write(to: cacheURL(key), options: .atomic)
    }
  }

  // MARK: - 注入页面

  private func pushFull(force: Bool = false) {
    let sig = "\(currentKey)|\(status)|\(lines.count)"
    if !force && sig == lastFullSignature { return }
    lastFullSignature = sig

    let lineArr: [[Any]] = lines.map { [$0.t, $0.text] }
    let state = player.playbackState
    let obj: [String: Any] = [
      "key": currentKey,
      "status": status,
      "title": title,
      "artist": artist,
      "album": album,
      "duration": duration,
      "playing": state == .playing,
      "position": max(0, player.currentPlaybackTime),
      "rate": state == .playing ? 1.0 : 0.0,
      "lines": lineArr
    ]
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj),
          let json = String(data: data, encoding: .utf8) else { return }
    web?.evaluateJavaScript("window.CarDashLyrics&&CarDashLyrics.setTrack(\(json))") { [weak self] _, err in
      if let err = err {
        cardashTrace("lyrics js setTrack error \(err.localizedDescription)")
        self?.lastFullSignature = ""
      }
    }
  }

  private func pushSync(playing: Bool, position: Double, rate: Double) {
    let obj: [String: Any] = ["playing": playing, "position": position, "rate": rate]
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let json = String(data: data, encoding: .utf8) else { return }
    web?.evaluateJavaScript("window.CarDashLyrics&&CarDashLyrics.sync(\(json))", completionHandler: nil)
  }

  // 模拟器没有 Music 库：推一条假数据，验证注入链路和页面渲染不崩。
  // 真机不会走这里，读者别把它当成真实歌词。
  private func pushDemo() {
    title = "Demo Track"
    artist = "CarDash"
    album = ""
    duration = 120
    status = "ok"
    currentKey = "sim-demo"
    lines = (0..<30).map { CachedLine(t: Double($0) * 2.5 + 1, text: "Demo lyric line \($0 + 1)") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self = self else { return }
      self.pushFull(force: true)
      // 读回页面 DOM：注入链断了（比如页面没暴露 CarDashLyrics）会在这里显形，而不是只看到一张空卡
      self.web?.evaluateJavaScript(
        "JSON.stringify({api:typeof CarDashLyrics,rows:document.querySelectorAll('#lyrList li').length,title:document.getElementById('lyrTitle').textContent})"
      ) { r, e in
        cardashTrace("lyrics demo push result=\(r as? String ?? "nil") err=\(e?.localizedDescription ?? "nil")")
      }
    }
  }
}
