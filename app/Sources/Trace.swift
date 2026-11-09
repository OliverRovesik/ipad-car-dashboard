import Foundation

// CI 判据通道：runner 上模拟器的日志抓取不可靠，但沙盒容器里的文件在宿主机上直接可读。
func cardashTrace(_ s: String) {
  NSLog("%@", "CARDASH: " + s)
  guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
  let dir = base.appendingPathComponent("CarDash", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let f = dir.appendingPathComponent("ci-trace.log")
  let line = (s + "\n").data(using: .utf8) ?? Data()
  if let h = try? FileHandle(forWritingTo: f) {
    h.seekToEndOfFile(); h.write(line); try? h.close()
  } else {
    try? line.write(to: f)
  }
}
