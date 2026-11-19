import UIKit
import WebKit

// iOS 26 不再接受"没有 UIApplicationSceneManifest、直接在 app delegate 里建窗口"的写法：
// 上一版 CI 崩溃栈是 -[UIApplication _runWithMainScene:transitionContext:completion:] 抛 ObjC 异常。
// 窗口和 WebView 的装配因此挪到这里，由 session 建立时创建。
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate, WKNavigationDelegate, WKUIDelegate {
  var window: UIWindow?
  var web: WKWebView?
  let root = RootViewController()
  let overlay = UIView()
  let status = UILabel()
  let retry = UIButton(type: .system)
  // 版本角标：装完包唯一能在设备上自查「哪一版 / 哪一页 / 页面来自哪里」的入口。
  let badge = UILabel()
  private var badgeSeq = 0
  private var probed = false
  private var syncStarted = false

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options: UIScene.ConnectionOptions) {
    guard let ws = scene as? UIWindowScene else { cardashTrace("no UIWindowScene"); return }
    let w = UIWindow(windowScene: ws)
    // 底色必须跟"页面实际用的那套"对齐，不是跟系统外观：FLOW 页在 CSS 末尾把 --bg 无条件
    // 钉成夜间一套（HUD 永远深底），系统浅色模式下页面仍然是 #0e1216。
    // v1.2.7 那次跟着系统给动态色，等于在浅色模式下把缝里刷成 #eef1f5 —— 比原来写死 0.06
    // 的黑边更刺眼，这正是他这次还看到一条带的原因。GPS 页的 --bg 才真的跟系统走。
    let pageBG = Self.pageBackground(for: WebContent.page)
    w.backgroundColor = pageBG
    w.rootViewController = root
    root.view.backgroundColor = w.backgroundColor

    let cfg = WKWebViewConfiguration()
    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []
    let v = WKWebView(frame: .zero, configuration: cfg)
    v.translatesAutoresizingMaskIntoConstraints = false
    v.navigationDelegate = self
    v.uiDelegate = self
    v.allowsBackForwardNavigationGestures = false
    if #available(iOS 16.4, *) { v.isInspectable = true }
    v.underPageBackgroundColor = w.backgroundColor
    root.view.addSubview(v)
    // 顶边贴安全区避免系统状态栏压住页面；底边铺到窗口边缘，
    // 否则 Home Indicator 那条安全区会露出 root 的黑色背景（页面已用 env(safe-area-inset-bottom) 让位）。
    NSLayoutConstraint.activate([
      v.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor),
      v.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
      v.leadingAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.leadingAnchor),
      v.trailingAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.trailingAnchor)
    ])
    web = v

    status.numberOfLines = 0
    status.textAlignment = .center
    status.font = UIFont.preferredFont(forTextStyle: .body)
    status.textColor = UIColor(white: 0.75, alpha: 1)
    status.translatesAutoresizingMaskIntoConstraints = false

    retry.setTitle("Retry", for: .normal)
    retry.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
    retry.addTarget(self, action: #selector(load), for: .touchUpInside)
    retry.translatesAutoresizingMaskIntoConstraints = false

    // 错误提示和 Retry 共用一个开关：上一版 Retry 建出来就没人隐藏它，页面加载完还杵在屏幕中间。
    overlay.isHidden = true
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.addSubview(status)
    overlay.addSubview(retry)
    root.view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 24),
      overlay.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -24),
      overlay.centerYAnchor.constraint(equalTo: root.view.centerYAnchor),
      status.topAnchor.constraint(equalTo: overlay.topAnchor),
      status.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
      retry.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 16),
      retry.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
      retry.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
    ])

    // 版本角标贴在安全区右下角。isUserInteractionEnabled=false 是关键：它盖在页面上，
    // 但绝不能吃掉底下任何一个点击（收藏条、歌词卡拉手都在这一带）。
    badge.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    badge.textColor = UIColor(white: 0.93, alpha: 1)
    badge.backgroundColor = UIColor(white: 0, alpha: 0.45)
    badge.numberOfLines = 4
    badge.textAlignment = .center
    badge.layer.cornerRadius = 5
    badge.clipsToBounds = true
    badge.alpha = 0
    badge.isUserInteractionEnabled = false
    badge.translatesAutoresizingMaskIntoConstraints = false
    root.view.addSubview(badge)
    NSLayoutConstraint.activate([
      badge.trailingAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
      badge.bottomAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.bottomAnchor, constant: -6)
    ])

    window = w
    w.makeKeyAndVisible()
    cardashTrace("scene connected")
    if #available(iOS 16.0, *) {
      let sr = ws.sizeRestrictions
      cardashTrace("scene geometry bounds=\(ws.coordinateSpace.bounds) orientation=\(ws.interfaceOrientation.rawValue) restrictions=\(sr.map { "min=\($0.minimumSize) max=\($0.maximumSize)" } ?? "nil")")
    }
    load()
  }

  @objc func load() {
    setOverlay(hidden: true)
    if let html = WebContent.compose() {
      web?.loadHTMLString(html, baseURL: WebContent.baseURL)
      return
    }
    cardashTrace("compose miss, network fallback")
    WebContent.servedFrom = "online"
    guard let u = URL(string: DASH_URL) else { show("Bad URL: " + DASH_URL); return }
    web?.load(URLRequest(url: u, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
  }

  private func setOverlay(hidden: Bool) {
    overlay.isHidden = hidden
    web?.isHidden = !hidden
  }

  func show(_ msg: String) {
    status.text = msg
    setOverlay(hidden: false)
    cardashTrace("overlay shown: \(msg)")
  }

  private static func pageBackground(for page: String) -> UIColor {
    let dark = UIColor(red: 0x0e/255.0, green: 0x12/255.0, blue: 0x16/255.0, alpha: 1)
    let light = UIColor(red: 0xee/255.0, green: 0xf1/255.0, blue: 0xf5/255.0, alpha: 1)
    if page.hasPrefix("dashboard-flow") { return dark }
    return UIColor { tc in tc.userInterfaceStyle == .dark ? dark : light }
  }

  private var buildStamp: String {
    let i = Bundle.main.infoDictionary
    let v = i?["CFBundleShortVersionString"] as? String ?? "?"
    let b = i?["CFBundleVersion"] as? String ?? "?"
    // 页面名去掉 dashboard- 前缀和 .html 后缀，只留 gps / flow 这种一眼能认的字样。
    let page = WebContent.page
      .replacingOccurrences(of: "dashboard-", with: "")
      .replacingOccurrences(of: ".html", with: "")
    return "\(v) (\(b)) · \(page) · \(WebContent.servedFrom)"
  }

  // 几何读数：这条带到底是"页面没铺到"还是"颜色对不上"，只有这几个数能分开。
  // 本机没有 UIKit 环境（只有 CLT，跑不了模拟器），所以把数打在屏幕上让他拍一张回来。
  // 拆两行：合一行是 54 字符 ≈324pt，在 470pt 宽的车窗口里会横贯大半屏。
  private var geomLines: [String] {
    let sv = web?.scrollView
    func n(_ x: CGFloat) -> Int { x.isFinite ? Int(x.rounded()) : -1 }
    let sa = root.view.safeAreaInsets
    return ["win \(n(root.view.bounds.height)) web \(n(web?.frame.height ?? -.infinity))"
              + " safe \(n(sa.top))/\(n(sa.bottom))",
            "inset \(n(sv?.contentInset.bottom ?? -.infinity))"
              + " adj \(n(sv?.adjustedContentInset.bottom ?? -.infinity))"
              + " csize \(n(sv?.contentSize.height ?? -.infinity))"]
  }

  // 页面自己报的视口高度和 body 实际底色：web 高 == ih 说明页面铺满了；
  // bg 拿去和 pageBG 对照，就能分清那条带是颜色不匹配还是几何错位。
  private static let geomJS = "JSON.stringify({ih:innerHeight,ch:document.documentElement.clientHeight,bg:getComputedStyle(document.body).backgroundColor})"

  private func badgeText(_ page: String) -> String {
    ([buildStamp] + geomLines + [page]).map { "  \($0)  " }.joined(separator: "\n")
  }

  // 每次页面真正加载完亮 15 秒，然后淡出。行车中不打扰，但装完包、换完页面一开就能看到。
  // 用序号丢弃过期的淡出：连续两次加载（比如从谷歌地图切回来重拼）时，
  // 前一次的计时不能把刚亮出来的这一张关掉；页面读数同理，晚到的那份不能盖掉新的一张。
  private func showBadge() {
    badgeSeq += 1
    let seq = badgeSeq
    badge.text = badgeText("reading…")
    badge.alpha = 1
    cardashTrace("badge shown \(buildStamp) | " + geomLines.joined(separator: " "))
    readPageGeom(seq, 0)
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
      guard let s = self, s.badgeSeq == seq else { return }
      UIView.animate(withDuration: 0.6) { s.badge.alpha = 0 }
    }
  }

  // 读不到就每秒重试：慢 runner 上 evaluateJavaScript 会排在页面自己的长任务后面
  // （歌词回读当年就是这么误判的），一次扑空不能把这条诊断行整个丢掉。
  private func readPageGeom(_ seq: Int, _ attempt: Int) {
    web?.evaluateJavaScript(Self.geomJS) { [weak self] r, e in
      guard let s = self, s.badgeSeq == seq else { return }
      if let p = r as? String {
        s.badge.text = s.badgeText(p)
        cardashTrace("badge page \(p)")
        return
      }
      cardashTrace("badge page retry \(attempt) \(e?.localizedDescription ?? "nil result")")
      if attempt < 4 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { s.readPageGeom(seq, attempt + 1) }
      }
    }
  }

  // 新窗口请求：页面里 target="_blank" 的收藏按钮和搜索栏提交都走到这里。
  // WKWebView 自己不会开新窗口，也不会触发 universal link，必须交回系统处理。
  func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
               for act: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let u = act.request.url { UIApplication.shared.open(u, options: [:], completionHandler: nil) }
    return nil
  }

  // 非本页链接（maps.app.goo.gl、itms-services、tel: 等）一律交出去，别在壳里加载。
  // loadHTMLString 的 baseURL 仍是这个 https origin，所以白名单照旧命中。
  func webView(_ w: WKWebView, decidePolicyFor act: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let u = act.request.url else { decisionHandler(.cancel); return }
    let host = u.host ?? ""
    if u.scheme == "https" || u.scheme == "http",
       host.hasSuffix("oliverrovesik.github.io") || host.hasSuffix("localhost") {
      decisionHandler(.allow); return
    }
    UIApplication.shared.open(u, options: [:], completionHandler: nil)
    decisionHandler(.cancel)
  }

  // 长按不弹系统上下文菜单（全选/拷贝/打开链接）；文本选择本身由页面 CSS 的 user-select:none 关掉。
  @available(iOS 13.0, *)
  func webView(_ w: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
               completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
    completionHandler(nil)
  }

  func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
    cardashTrace("load failed \(e.localizedDescription)")
    show("Load failed: " + e.localizedDescription)
  }
  func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
    cardashTrace("load failed \(e.localizedDescription)")
    show("Load failed: " + e.localizedDescription)
  }
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    cardashTrace("load finished \(w.url?.absoluteString ?? "nil")")
    setOverlay(hidden: true)
    cardashTrace("overlay hidden")
    showBadge()
    if !probed { probed = true; probe(0) }
    if !syncStarted { syncStarted = true; WebSync.run() }
    if let v = web { LyricsBridge.shared.start(v) }
  }

  // 内置页面是否真的在 WebKit 里跑起来了，只有问页面自己才知道：
  // secure context 决定定位能不能用，__FIESTA_GLB/three/renderer 证明内联脚本执行了，
  // __car 是模型加载成功回调留下的记号（GPS/FLOW 两页共用同一套探针记号）。模型是异步解析的，所以要重试。
  private static let probeJS = "JSON.stringify({secure:window.isSecureContext,geo:typeof navigator.geolocation,three:typeof THREE,glb:(window.__FIESTA_GLB||'').length,renderer:typeof renderer,car:window.__car?window.__car.size:null,canvas:!!document.querySelector('#scene canvas')})"

  private func probe(_ n: Int) {
    guard let v = web else { return }
    v.evaluateJavaScript(Self.probeJS) { r, e in
      let s = (r as? String) ?? "error: \(e?.localizedDescription ?? "nil")"
      cardashTrace("probe \(n): \(s)")
      if s.contains("\"car\":{") { cardashTrace("probe ok"); return }
      if n < 6 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.probe(n + 1) } }
    }
  }

  // 从谷歌地图切回来时，页面可能被系统回收过，重新拼一次比留一张黑屏好（现在不花流量）
  func sceneDidBecomeActive(_ scene: UIScene) {
    UIApplication.shared.isIdleTimerDisabled = true
    if let v = web, v.estimatedProgress < 0.99 { load() }
  }

  @available(iOS 16.0, *)
  func windowScene(_ ws: UIWindowScene, didUpdateEffectiveGeometry prev: UIWindowScene.Geometry) {
    cardashTrace("scene resize bounds=\(ws.coordinateSpace.bounds) orientation=\(ws.effectiveGeometry.interfaceOrientation.rawValue)")
  }
}