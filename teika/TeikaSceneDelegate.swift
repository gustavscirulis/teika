import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = TeikaSceneDelegate.self
        return configuration
    }
}

final class TeikaSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        _ = handle(connectionOptions.shortcutItem)
    }

    func windowScene(
        _: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        completionHandler(handle(shortcutItem))
    }

    private func handle(_ shortcutItem: UIApplicationShortcutItem?) -> Bool {
        guard shortcutItem?.type == "com.gustavscirulis.teika.record" else { return false }
        RecordingLauncher.shared.request()
        return true
    }
}
