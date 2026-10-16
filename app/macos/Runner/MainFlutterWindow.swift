import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    styleMask.insert(.fullSizeContentView)
    isMovableByWindowBackground = true
    minSize = NSSize(width: 1100, height: 700)
    // Opens filling the screen (menu bar and Dock stay visible), not in a separate full-screen Space.
    if let visible = NSScreen.main?.visibleFrame {
      setFrame(visible, display: true)
    } else {
      setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
      center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
