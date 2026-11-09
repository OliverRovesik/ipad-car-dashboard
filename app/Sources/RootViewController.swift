import UIKit

// 之前 window 没有 rootViewController，状态栏外观因此无从控制，系统状态栏直接压在页面顶栏上。
final class RootViewController: UIViewController {
  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

  private var lastLayout = ""

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let now = "bounds=\(view.bounds) safe=\(view.safeAreaInsets)"
    if now != lastLayout {
      lastLayout = now
      cardashTrace("rootvc layout \(now)")
    }
  }
}