import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        appDelegate.handleDeepLink(context.url)
      }
    }
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts {
      if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
        appDelegate.handleDeepLink(context.url)
      }
    }
  }
}
