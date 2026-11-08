import Cocoa
import FlutterMacOS
import UserNotifications

@main
class AppDelegate: FlutterAppDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
  private var attention: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      registerClipboardChannel(controller.engine.binaryMessenger)
      registerAttentionChannel(controller.engine.binaryMessenger)
    }
    mainFlutterWindow?.delegate = self
    super.applicationDidFinishLaunching(notification)
  }

  /// Closing the only window quits the app, so it goes through the same termination request as ⌘Q: Flutter's
  /// `onExitRequested` can then cancel it when there are unsaved edits.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(sender)
    return false
  }

  /// Flutter's Clipboard only carries text: `claude_flow/clipboard` `image` returns the pasteboard image as PNG, or
  /// nil when there is none (a copied screenshot, an image from a browser, or an image file copied in Finder).
  private func registerClipboardChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "claude_flow/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "image" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let pasteboard = NSPasteboard.general
      if let png = pasteboard.data(forType: .png) {
        result(FlutterStandardTypedData(bytes: png))
        return
      }
      guard NSImage.canInit(with: pasteboard),
        let image = NSImage(pasteboard: pasteboard),
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
      else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: png))
    }
  }

  /// `claude_flow/attention`: `notify {id, title, body, route}` posts a system notification (a click comes back as
  /// `open {route}`), `badge {count}` sets the Dock badge, `isActive` says whether the app is frontmost.
  private func registerAttentionChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "claude_flow/attention", binaryMessenger: messenger)
    attention = channel
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "notify":
        let content = UNMutableNotificationContent()
        content.title = args["title"] as? String ?? ""
        content.body = args["body"] as? String ?? ""
        content.sound = .default
        content.userInfo = ["route": args["route"] as? String ?? "/"]
        let id = args["id"] as? String ?? UUID().uuidString
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
        result(nil)
      case "badge":
        let count = args["count"] as? Int ?? 0
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        result(nil)
      case "isActive":
        result(NSApp.isActive)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let route = response.notification.request.content.userInfo["route"] as? String ?? "/"
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    attention?.invokeMethod("open", arguments: ["route": route])
    completionHandler()
  }

  /// Frontmost the app shows its own badges; a banner would only repeat them.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }
}
