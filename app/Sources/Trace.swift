import Foundation

// CI 判据通道：runner 上模拟器的日志抓取不可靠，但沙盒容器里的文件在宿主机上直接可读。
//
// 写入必须串行：主线程（load finished / overlay hidden / 角标 / 探针）、WebSync 的 detached
// task 和歌词回读会在同一秒内追写同一个文件，而 "打开 → seekToEndOfFile → write" 没有锁时
// 两个线程会拿到同一个末尾偏移，后写的那条直接盖掉前一条的字节。行被咬花以后，凡是依赖
// 行尾内容的判据（例如 'badge shown … | win …'、'rows":30'）都会随机飘红，所以这里必须加锁。
private let traceLock = NSLock()

func cardashTrace(_ s: String) {
  NSLog("%@", "CARDASH: " + s)
  traceLock.lock()
  defer { traceLock.unlock() }
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
