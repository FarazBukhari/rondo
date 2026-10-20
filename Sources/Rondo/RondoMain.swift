import AppKit

@main
@MainActor
enum RondoMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()   // NSApplication.delegate is weak; run() keeps this frame alive
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
