import UIKit
import Capacitor
import RealmSwift

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    lazy var window: UIWindow? = UIWindow(frame: UIScreen.main.bounds)
    var backgroundCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.

        let configuration = Realm.Configuration(
            schemaVersion: 20,
            migrationBlock: { [weak self] migration, oldSchemaVersion in
                if (oldSchemaVersion < 1) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)")
                    migration.enumerateObjects(ofType: DeviceSettings.className()) { oldObject, newObject in
                        newObject?["enableAltView"] = false
                    }
                }
                if (oldSchemaVersion < 4) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Reindexing server configs")
                    var indexCounter = 1
                    migration.enumerateObjects(ofType: ServerConnectionConfig.className()) { oldObject, newObject in
                        newObject?["index"] = indexCounter
                        indexCounter += 1
                    }
                }
                if (oldSchemaVersion < 5) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding lockOrientation setting")
                    migration.enumerateObjects(ofType: DeviceSettings.className()) { oldObject, newObject in
                        newObject?["lockOrientation"] = "NONE"
                    }
                }
                if (oldSchemaVersion < 6) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding hapticFeedback setting")
                    migration.enumerateObjects(ofType: DeviceSettings.className()) { oldObject, newObject in
                        newObject?["hapticFeedback"] = "LIGHT"
                    }
                }
                if (oldSchemaVersion < 15) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding languageCode setting")
                    migration.enumerateObjects(ofType: DeviceSettings.className()) { oldObject, newObject in
                        newObject?["languageCode"] = "en-us"
                    }
                }
                if (oldSchemaVersion < 16) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding chapterTrack setting")
                    migration.enumerateObjects(ofType: PlayerSettings.className()) { oldObject, newObject in
                        newObject?["chapterTrack"] = false
                    }
                }
                if (oldSchemaVersion < 17) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding downloadUsingCellular and streamingUsingCellular settings")
                    migration.enumerateObjects(ofType: PlayerSettings.className()) { oldObject, newObject in
                        newObject?["downloadUsingCellular"] = "ALWAYS"
                        newObject?["streamingUsingCellular"] = "ALWAYS"
                    }
                }
                if (oldSchemaVersion < 18) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding disableSleepTimerFadeOut settings")
                    migration.enumerateObjects(ofType: PlayerSettings.className()) { oldObject, newObject in
                        newObject?["disableSleepTimerFadeOut"] = false
                    }
                }
                if (oldSchemaVersion < 20) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding version to ServerConnectionConfigs")
                    migration.enumerateObjects(ofType: ServerConnectionConfig.className()) { oldObject, newObject in
                        newObject?["version"] = ""
                    }
                }
            }
        )
        Realm.Configuration.defaultConfiguration = configuration

        // Push current credentials to the App Group so the widget can fetch (no-op if not signed in).
        WidgetSync.sync()
        // Listen for transport commands from the widget's control buttons.
        WidgetCommandReceiver.shared.start()

        // A cold launch via a custom URL scheme (e.g. the widget's audiobookshelf://resume) delivers
        // the URL ONLY in launchOptions — iOS does not call application(_:open:) in that case — so
        // Capacitor never sees it (no appUrlOpen, no getLaunchUrl). Forward it to Capacitor's proxy so
        // it records lastURL and posts the open-URL notification, letting the web layer resume.
        if let url = launchOptions?[.url] as? URL {
            _ = ApplicationDelegateProxy.shared.application(application, open: url, options: [:])
        }

        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
        AbsLogger.info(message: "Audiobookself is now in the background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
        AbsLogger.info(message: "Audiobookself is now in the foreground")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
        AbsLogger.info(message: "Audiobookself is now active")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
        AbsLogger.info(message: "Audiobookself is terminating")
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Forward every URL (incl. the widget's audiobookshelf://resume deep link) to Capacitor so
        // the web layer receives it via appUrlOpen and resumes through the mature in-app play flow.
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // Stores the completion handler for background downloads
        // The identifier of this method can be ignored at this time as we only have one background url session
        backgroundCompletionHandler = completionHandler
    }

    // Adding UIApplicationSceneManifest switches the whole app from the legacy
    // (non-scene) AppDelegate.window + UIMainStoryboardFile launch path to scene-based
    // lifecycle. Two attempts black-screened the phone window (confirmed by screenshot +
    // by `evaluatedApplicationKeyWindow: 0x0` in the system log — no key window was ever set):
    //   1. A static UIWindowSceneSessionRoleApplication config in Info.plist with
    //      UISceneStoryboardFile = Main and no delegate class.
    //   2. Returning a plain UISceneConfiguration (no delegateClass) for the default role here.
    // Neither triggers UIKit's old "instantiate Main.storyboard into the window automatically"
    // magic once a scene manifest exists. DefaultSceneDelegate below reproduces that behavior
    // explicitly, and is only reachable via this dynamic configurationForConnecting hook — the
    // window role is intentionally NOT declared in Info.plist's UISceneConfigurations.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay Configuration", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = DefaultSceneDelegate.self
        return config
    }

}

// Backs the phone's default window-scene role. Scene-based apps normally get this behavior for
// free from a project-template SceneDelegate.swift; this app predates the scene manifest and has
// none, so this reproduces the same minimal setup (window sized to the scene, rootViewController
// from Main.storyboard's initial view controller, made key and visible) that
// application(_:didFinishLaunchingWithOptions:) + UIMainStoryboardFile used to provide implicitly.
class DefaultSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        window.rootViewController = storyboard.instantiateInitialViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

