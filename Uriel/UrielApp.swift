import AppKit
import SwiftUI
import UrielCore

@main
struct UrielApp: App {
  // Off at launch: nothing uses the audio yet, and the owner switches it on.
  @State private var microphone = Microphone()

  private static let microphoneSettings = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

  // shortcut: says only what the mic switch is doing; the turn loop (Phase 1 step 5) adds
  // listening, thinking and speaking.
  private var status: String {
    switch microphone.state {
    case .off: "Mic off"
    case .starting: "Turning the mic on…"
    case .on: "Mic on — not listening for commands yet"
    case .denied: "No permission to use the mic"
    case .failed: "Mic stopped"
    }
  }

  var body: some Scene {
    // The title is the item's accessibility label; the menu bar shows only the image, a
    // template that macOS tints for light and dark bars.
    MenuBarExtra("Uriel, \(status)", image: "Halo") {
      Text("Uriel · \(status)")
      if case .failed(let reason) = microphone.state {
        Text(reason)
      }
      Divider()
      // A checkmark item, the native pattern for an on/off setting in a menu. No key equivalent:
      // a menu-bar menu handles one only while it is open, where a click is just as quick.
      Toggle(
        "Microphone",
        isOn: Binding(
          get: { microphone.state == .starting || microphone.state == .on },
          set: { isOn in
            if isOn { Task { await microphone.turnOn() } } else { microphone.turnOff() }
          }))
      if microphone.state == .denied {
        Button("Open Microphone Settings…") {
          // AppKit: certain to work from a menu-bar menu, where SwiftUI's Link is unchecked.
          NSWorkspace.shared.open(Self.microphoneSettings)
        }
      }
      Divider()
      Button("About Uriel") {
        // AppKit: a menu-bar-only app must come to the front, or the panel opens behind other
        // windows.
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
      }
      Divider()
      Button("Quit Uriel") {
        // AppKit: SwiftUI has no action that quits a menu-bar-only app.
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }
}
