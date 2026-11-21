import AVFoundation
import Flutter
import ImageIO
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundChannel: FlutterMethodChannel?
  private var pendingDeepLink: String?

  // 定时守夜/抢座期间用于防止 iOS 锁屏与后台冻结进程的静音保活播放器
  private var keepAliveActive = false
  private var silentPlayer: AVAudioPlayer?
  private var audioSessionObservers: [NSObjectProtocol] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    stopBackgroundKeepAlive()
    super.applicationWillTerminate(application)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "com.xunrana.lnulibseat/background",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    backgroundChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "startIosBackgroundKeepAlive":
        result(self.startBackgroundKeepAlive())
      case "stopIosBackgroundKeepAlive":
        self.stopBackgroundKeepAlive()
        result(nil)
      case "decodeImageRgba":
        guard
          let args = call.arguments as? [String: Any],
          let typed = args["bytes"] as? FlutterStandardTypedData,
          !typed.data.isEmpty
        else {
          result(nil)
          return
        }
        let rawData = typed.data
        DispatchQueue.global(qos: .userInitiated).async {
          let decoded = Self.decodeImageRgbaCpu(rawData)
          DispatchQueue.main.async {
            result(decoded)
          }
        }
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

    if let urlString = pendingDeepLink {
      pendingDeepLink = nil
      DispatchQueue.main.async {
        channel.invokeMethod("onDeepLink", arguments: urlString)
      }
    }
  }

  // MARK: - iOS 锁屏/后台静音保活（不打断其他 App 音乐，抢座结束自动关闭）

  private func startBackgroundKeepAlive() -> Bool {
    keepAliveActive = true
    installAudioSessionObserversIfNeeded()
    return activateAndPlaySilence()
  }

  private func stopBackgroundKeepAlive() {
    keepAliveActive = false
    removeAudioSessionObservers()
    silentPlayer?.stop()
    silentPlayer = nil
    do {
      try AVAudioSession.sharedInstance().setActive(
        false,
        options: [.notifyOthersOnDeactivation]
      )
    } catch {
      // 忽略释放阶段的音频会话状态异常
    }
  }

  private func activateAndPlaySilence() -> Bool {
    guard keepAliveActive else { return false }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      return false
    }

    if let existing = silentPlayer {
      if existing.isPlaying {
        return true
      }
      return existing.play()
    }

    let wavData = Self.makeSilentWavData(sampleRate: 8000, durationSeconds: 1)
    do {
      let player = try AVAudioPlayer(data: wavData, fileTypeHint: AVFileType.wav.rawValue)
      player.numberOfLoops = -1
      // PCM 采样全为 0（绝对无声）；保持非零增益避免系统将 0.0 音量播放器视作静默可挂起状态
      player.volume = 0.01
      player.prepareToPlay()
      let ok = player.play()
      if ok {
        silentPlayer = player
      }
      return ok
    } catch {
      return false
    }
  }

  private func installAudioSessionObserversIfNeeded() {
    guard audioSessionObservers.isEmpty else { return }
    let nc = NotificationCenter.default

    let interruptionObserver = nc.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard let self = self, self.keepAliveActive else { return }
      guard
        let info = notification.userInfo,
        let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
      else {
        return
      }
      if type == .ended {
        _ = self.activateAndPlaySilence()
      }
    }

    let routeObserver = nc.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      guard let self = self, self.keepAliveActive else { return }
      if self.silentPlayer?.isPlaying != true {
        _ = self.activateAndPlaySilence()
      }
    }

    let resetObserver = nc.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      guard let self = self, self.keepAliveActive else { return }
      self.silentPlayer = nil
      _ = self.activateAndPlaySilence()
    }

    audioSessionObservers = [interruptionObserver, routeObserver, resetObserver]
  }

  private func removeAudioSessionObservers() {
    let nc = NotificationCenter.default
    for obs in audioSessionObservers {
      nc.removeObserver(obs)
    }
    audioSessionObservers.removeAll()
  }

  /// 生成标准 16-bit Mono PCM 全零静音 WAV（约 16 KB，纯内存零磁盘 IO）。
  private static func makeSilentWavData(sampleRate: UInt32, durationSeconds: UInt32) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign: UInt16 = channels * (bitsPerSample / 8)
    let dataSize: UInt32 = byteRate * durationSeconds
    let riffChunkSize: UInt32 = 36 + dataSize

    var data = Data(capacity: Int(44 + dataSize))
    func appendLE<T: FixedWidthInteger>(_ value: T) {
      var le = value.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    data.append(contentsOf: "RIFF".utf8)
    appendLE(riffChunkSize)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    appendLE(UInt32(16))
    appendLE(UInt16(1))
    appendLE(channels)
    appendLE(sampleRate)
    appendLE(byteRate)
    appendLE(blockAlign)
    appendLE(bitsPerSample)
    data.append(contentsOf: "data".utf8)
    appendLE(dataSize)
    data.append(Data(count: Int(dataSize)))
    return data
  }

  // MARK: - 纯 CPU ImageIO / CoreGraphics 图像解码（锁屏后台零 Metal GPU 依赖）

  private static func decodeImageRgbaCpu(_ rawData: Data) -> [String: Any]? {
    let sourceOpts: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
      kCGImageSourceShouldAllowFloat: false,
    ]
    guard
      let source = CGImageSourceCreateWithData(rawData as CFData, sourceOpts as CFDictionary),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, sourceOpts as CFDictionary)
    else {
      return nil
    }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }

    let alphaInfo = cgImage.alphaInfo
    let hasAlpha: Bool
    switch alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
      hasAlpha = false
    default:
      hasAlpha = true
    }

    let bytesPerRow = width * 4
    let totalBytes = bytesPerRow * height
    var buffer = Data(count: totalBytes)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      return nil
    }
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    let rendered: Bool = buffer.withUnsafeMutableBytes { rawBuf in
      guard let baseAddress = rawBuf.baseAddress else { return false }
      guard
        let ctx = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        )
      else {
        return false
      }
      ctx.interpolationQuality = .none
      ctx.setBlendMode(.copy)
      ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }

    guard rendered else { return nil }
    return [
      "width": width,
      "height": height,
      "rgba": FlutterStandardTypedData(bytes: buffer),
      "premultiplied": hasAlpha,
    ]
  }

  // MARK: - Deep Link & 本地签到提醒

  @discardableResult
  func handleDeepLink(_ url: URL) -> Bool {
    guard url.scheme == "lnulibseat" else {
      return false
    }
    if let channel = backgroundChannel {
      channel.invokeMethod("onDeepLink", arguments: url.absoluteString)
    } else {
      pendingDeepLink = url.absoluteString
    }
    return true
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
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if handleDeepLink(url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }
}
