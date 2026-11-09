import UIKit

// 入口：手动编译没有 @main，用 UIApplicationMain 传类名字符串（AppDelegate 上有 @objc(AppDelegate) 才找得到）
_ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, "AppDelegate")
