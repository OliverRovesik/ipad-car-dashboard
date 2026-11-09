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
  private var probed = false
  private var syncStarted = false

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options: UIScene.ConnectionOptions) {
    guard let ws = scene as? UIWindowScene else { cardashTrace("no UIWindowScene"); return }
    let w = UIWindow(windowScene: ws)
    w.backgroundColor = UIColor(white: 0.06, alpha: 1)
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
    if !probed { probed = true; probe(0) }
    if !syncStarted { syncStarted = true; WebSync.run() }
    if let v = web { LyricsBridge.shared.start(v) }
  }

  // 内置页面是否真的在 WebKit 里跑起来了，只有问页面自己才知道：
  // secure context 决定定位能不能用，__FIESTA_GLB/three/renderer 证明内联脚本执行了，
  // __car 是模型加载成功回调（dashboard-gps.html:857）留下的记号。模型是异步解析的，所以要重试。
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