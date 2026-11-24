import SwiftUI
import UIKit

/// 旋转锁控制：全屏播放时允许横屏，其他时候锁竖屏（同时尊重系统旋转锁——
/// 系统锁开时 supportedInterfaceOrientations 里的方向也不会生效）
class OrientationLock {
    static var isLandscapeOnly = false
}

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.isLandscapeOnly ? .landscape : .portrait
    }
}

@main
struct svideo_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { RootView() }
    }
}
