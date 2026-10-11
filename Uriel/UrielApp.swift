import AppKit
import SwiftUI

@main
struct UrielApp: App {
  var body: some Scene {
    // The title is the item's accessibility label; the menu bar shows only the symbol.
    MenuBarExtra("Uriel, idle", systemImage: "waveform.circle") {
      Button("Quit Uriel") {
        // AppKit: SwiftUI has no action that quits a menu-bar-only app.
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }
}
