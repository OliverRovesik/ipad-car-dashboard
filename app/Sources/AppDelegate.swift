import UIKit
import CoreLocation

// app 只是外壳，页面仍然从 GitHub Pages 取 —— dashboard-gps.html 改完 push 就生效，
// 不用为了更新界面重新构建 ipa。
let DASH_URL = "https://oliverrovesik.github.io/ipad-car-dashboard/dashboard-gps.html"

@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  // CLLocationManager 必须被持有，释放掉就不会再弹定位授权
  let loc = CLLocationManager()

  func applicationDidFinishLaunching(_ app: UIApplication) {
    // 这就是整个 app 存在的理由：Safari 里 navigator.wakeLock 被拒，原生只能自己关掉息屏计时
    UIApplication.shared.isIdleTimerDisabled = true
    cardashTrace("launched idleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled) url=\(DASH_URL)")
    loc.requestWhenInUseAuthorization()
  }
}
