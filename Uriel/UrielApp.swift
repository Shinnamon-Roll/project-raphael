import AppKit
import SwiftUI

@main
struct UrielApp: App {
  // shortcut: fixed until the turn loop (Phase 1 step 5) reports Uriel's real state; Uriel cannot
  // listen yet, so the menu says so instead of claiming to wait for the wake word.
  private let status = "ยังไม่ได้เริ่มฟัง"

  var body: some Scene {
    // The title is the item's accessibility label; the menu bar shows only the image, a
    // template that macOS tints for light and dark bars.
    MenuBarExtra("Uriel, \(status)", image: "Halo") {
      Text("Uriel · \(status)")
      Divider()
      Button("เกี่ยวกับ Uriel") {
        // AppKit: a menu-bar-only app must come to the front, or the panel opens behind other
        // windows.
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
      }
      Divider()
      Button("ออกจาก Uriel") {
        // AppKit: SwiftUI has no action that quits a menu-bar-only app.
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }
}
