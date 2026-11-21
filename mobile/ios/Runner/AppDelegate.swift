import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var backgroundChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.xunrana.lnulibseat/background",
        binaryMessenger: controller.binaryMessenger
      )
      backgroundChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(false)
          return
        }
        switch call.method {
        case "scheduleCheckinReminder":
          let args = call.arguments as? [String: Any]
          let alarmId = (args?["alarmId"] as? NSNumber)?.intValue ?? 0
          let triggerAtEpochMs = (args?["triggerAtEpochMs"] as? NSNumber)?.doubleValue ?? 0
          let title = (args?["title"] as? String) ?? "图书馆签到提醒"
          let body = (args?["body"] as? String) ?? "请按时前往图书馆刷卡签到，避免违约。"
          let urgent = (args?["urgent"] as? Bool) ?? false
          self.scheduleCheckinReminder(
            alarmId: alarmId,
            triggerAtEpochMs: triggerAtEpochMs,
            title: title,
            body: body,
            urgent: urgent,
            result: result
          )
        case "cancelCheckinReminder":
          let args = call.arguments as? [String: Any]
          let alarmId = (args?["alarmId"] as? NSNumber)?.intValue ?? 0
          self.cancelCheckinReminder(alarmId: alarmId)
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func reminderIdentifier(for alarmId: Int) -> String {
    return "lnu_checkin_\(alarmId)"
  }

  private func scheduleCheckinReminder(
    alarmId: Int,
    triggerAtEpochMs: Double,
    title: String,
    body: String,
    urgent: Bool,
    result: @escaping FlutterResult
  ) {
    let delay = (triggerAtEpochMs / 1000.0) - Date().timeIntervalSince1970
    guard alarmId > 0, delay > 1.0 else {
      result(false)
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    if #available(iOS 15.0, *) {
      content.interruptionLevel = urgent ? .timeSensitive : .active
    }
    let trigger = UNTimeIntervalNotificationTrigger(
      timeInterval: delay,
      repeats: false
    )
    let id = reminderIdentifier(for: alarmId)
    let request = UNNotificationRequest(
      identifier: id,
      content: content,
      trigger: trigger
    )
    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async {
        result(error == nil)
      }
    }
  }

  private func cancelCheckinReminder(alarmId: Int) {
    guard alarmId > 0 else { return }
    let id = reminderIdentifier(for: alarmId)
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [id])
    center.removeDeliveredNotifications(withIdentifiers: [id])
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    if url.scheme == "lnulibseat" {
      backgroundChannel?.invokeMethod("onDeepLink", arguments: url.absoluteString)
      return true
    }
    return super.application(app, open: url, options: options)
  }
}
