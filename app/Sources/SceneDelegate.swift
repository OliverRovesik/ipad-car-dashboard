import UIKit
import WebKit

// iOS 26 不再接受"没有 UIApplicationSceneManifest、直接在 app delegate 里建窗口"的写法：
// 上一版 CI 崩溃栈是 -[UIApplication _runWithMainScene:transitionContext:completion:] 抛 ObjC 异常。
// 窗口和 WebView 的装配因此挪到这里，由 session 建立时创建。
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate, WKNavigationDelegate, WKUIDelegate {
  var window: UIWindow?
  var web: WKWebView?
  let status = UILabel()

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options: UIScene.ConnectionOptions) {
    guard let ws = scene as? UIWindowScene else { cardashTrace("no UIWindowScene"); return }
    let w = UIWindow(windowScene: ws)
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
    cardashTrace("scene connected")
    load()
  }

  @objc func load() {
    status.isHidden = true
    guard let u = URL(string: DASH_URL) else { show("Bad URL: " + DASH_URL); return }
    web?.load(URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
  }

  func show(_ msg: String) {
    DispatchQueue.main.async {
      self.status.text = msg
      self.status.isHidden = false
      self.web?.isHidden = true
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
    cardashTrace("load failed \(e.localizedDescription)")
    show("Load failed: " + e.localizedDescription)
  }
  func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
    cardashTrace("load failed \(e.localizedDescription)")
    show("Load failed: " + e.localizedDescription)
  }
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    cardashTrace("load finished \(w.url?.absoluteString ?? "nil")")
    status.isHidden = true
    web?.isHidden = false
  }

  // 从谷歌地图切回来时，页面可能被系统回收过，重新拉一次比留一张黑屏好
  func sceneDidBecomeActive(_ scene: UIScene) {
    UIApplication.shared.isIdleTimerDisabled = true
    if let v = web, v.estimatedProgress < 0.99 { load() }
  }
}
