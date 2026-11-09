import UIKit
import WebKit
import CoreLocation

// app 只是外壳，页面仍然从 GitHub Pages 取 —— dashboard-gps.html 改完 push 就生效，
// 不用为了更新界面重新构建 ipa。
let DASH_URL = "https://oliverrovesik.github.io/ipad-car-dashboard/dashboard-gps.html"

@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
  var window: UIWindow?
  var web: WKWebView?
  // CLLocationManager 必须被持有，释放掉就不会再弹定位授权
  let loc = CLLocationManager()
  let status = UILabel()

  func application(_ app: UIApplication, willFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    trace("willFinish entered")
    let w = UIWindow(frame: UIScreen.main.bounds)
    w.backgroundColor = UIColor(white: 0.06, alpha: 1)

    let cfg = WKWebViewConfiguration()
    cfg.allowsInlineMediaPlayback = true
    cfg.mediaTypesRequiringUserActionForPlayback = []
    let v = WKWebView(frame: w.bounds, configuration: cfg)
    v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    v.navigationDelegate = self
    v.uiDelegate = self
    v.allowsBackForwardNavigationGestures = false
    if #available(iOS 16.4, *) { v.isInspectable = true }
    v.underPageBackgroundColor = w.backgroundColor
    w.addSubview(v)
    web = v

    status.numberOfLines = 0
    status.textAlignment = .center
    status.font = UIFont.preferredFont(forTextStyle: .body)
    status.textColor = UIColor(white: 0.75, alpha: 1)
    status.autoresizingMask = [.flexibleWidth, .flexibleTopMargin, .flexibleBottomMargin]
    status.frame = CGRect(x: 24, y: 0, width: w.bounds.width - 48, height: 120)
    status.center.y = w.bounds.height / 2
    status.isHidden = true
    w.addSubview(status)

    let retry = UIButton(type: .system)
    retry.setTitle("Retry", for: .normal)
    retry.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
    retry.addTarget(self, action: #selector(load), for: .touchUpInside)
    retry.sizeToFit()
    retry.center = CGPoint(x: w.bounds.width / 2, y: status.frame.maxY + 24)
    retry.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
    w.addSubview(retry)

    window = w
    w.makeKeyAndVisible()
    load()
    return true
  }

  // CI 判据通道见 Trace.swift：runner 上模拟器的日志抓取不可靠，容器里的文件在宿主机直接可读
  func trace(_ s: String) { cardashTrace(s) }

  func applicationDidFinishLaunching(_ app: UIApplication) {
    // 这就是整个 app 存在的理由：Safari 里 navigator.wakeLock 被拒，原生只能自己关掉息屏计时
    UIApplication.shared.isIdleTimerDisabled = true
    trace("launched idleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled) url=\(DASH_URL)")
    loc.requestWhenInUseAuthorization()
  }

  @objc func load() {
    status.isHidden = true
    guard let u = URL(string: DASH_URL) else { show("Bad URL: " + DASH_URL); return }
    web?.load(URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
  }

  func show(_ msg: String) {
    let v = web
    DispatchQueue.main.async {
      self.status.text = msg
      self.status.isHidden = false
      v?.isHidden = true
    }
  }

  // 新窗口请求：页面里 target="_blank" 的收藏按钮和搜索栏提交都走到这里。
  // WKWebView 自己不会开新窗口，也不会触发 universal link，必须交回系统处理。
  func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
               for act: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let u = act.request.url { UIApplication.shared.open(u, options: [:], completionHandler: nil) }
    return nil
  }

  // 非本页链接（maps.app.goo.gl、itms-services、tel: 等）一律交出去，别在壳里加载
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

  func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
    trace("load failed \(e.localizedDescription)")
    show("Load failed: " + (e.localizedDescription))
  }
  func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
    trace("load failed \(e.localizedDescription)")
    show("Load failed: " + (e.localizedDescription))
  }
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    trace("load finished \(w.url?.absoluteString ?? "nil")")
    status.isHidden = true
    web?.isHidden = false
  }

  // 从谷歌地图切回来时，页面可能被系统回收过，重新拉一次比留一张黑屏好
  func applicationDidBecomeActive(_ app: UIApplication) {
    UIApplication.shared.isIdleTimerDisabled = true
    if let v = web, v.estimatedProgress < 0.99 { load() }
  }
}
