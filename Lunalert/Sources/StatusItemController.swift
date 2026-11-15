import AppKit
import Combine
import SwiftUI

/// The menu-bar item. Left-click opens the panel; right-click (or Control-click) shows a small menu,
/// including the way out of Stargaze. AppKit is used because SwiftUI's MenuBarExtra has no right-click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    static let shared = StatusItemController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var label: PassthroughHostingView<StatusLabel>?

    func install() {
        guard let button = statusItem.button else { return }
        let label = PassthroughHostingView(rootView: StatusLabel { [weak self] size in
            self?.statusItem.length = size.width
        })
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        self.label = label
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Lunalert")

        let host = NSHostingController(rootView: MenuContentView().environmentObject(NotificationStore.shared))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // A panel hanging from the menu bar, without the popover's pointer.
        if popover.responds(to: Selector(("setShouldHideAnchor:"))) {
            popover.setValue(true, forKey: "shouldHideAnchor")
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    func togglePanel() {
        if popover.isShown { closePanel() } else { openPanel() }
    }

    func openPanel() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        SettingsWindowController.shared.stayAbovePanel()
    }

    /// The panel's window level while it's open (pop-ups sit above normal windows); nil when closed.
    var openPanelLevel: NSWindow.Level? {
        guard popover.isShown, let window = popover.contentViewController?.view.window else { return nil }
        return window.level
    }

    func popoverDidClose(_ notification: Notification) {
        SettingsWindowController.shared.stayAbovePanel()
    }

    func closePanel() {
        popover.performClose(nil)
    }

    /// While Settings is open the panel stays up beside it, so changes show as they're made.
    func keepPanelOpen(_ keep: Bool) {
        popover.behavior = keep ? .applicationDefined : .transient
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open Lunalert") { [weak self] in self?.openPanel() })
        menu.addItem(.separator())
        let sky = SkyModel.shared
        if sky.stargazing {
            menu.addItem(ClosureMenuItem(title: "Leave Stargaze (alerts back on)") { sky.leave() })
        } else {
            menu.addItem(ClosureMenuItem(title: "Stargaze (alerts off)") { sky.stargazing = true })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { SettingsWindowController.shared.show() })
        menu.addItem(ClosureMenuItem(title: "Quit Lunalert", key: "q") { NSApp.terminate(nil) })
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// A hosting view that lets clicks fall through to the status-bar button beneath it.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What the menu bar shows: the count with a bell that bounces on new activity, a sleeping moon while
/// Stargaze has alerts off, or a muted bell when Lunalert is not connected.
struct StatusLabel: View {
    @ObservedObject private var store = NotificationStore.shared
    @ObservedObject private var sky = SkyModel.shared
    let onSize: (CGSize) -> Void

    var body: some View {
        HStack(spacing: 3) {
            if sky.stargazing {
                Image(systemName: "moon.zzz.fill")
            } else if !store.hasToken || store.problem == .badToken {
                Image(systemName: "bell.slash")
            } else if store.unreadCount > 0 {
                Image(systemName: "bell.badge.fill")
                    .symbolEffect(.bounce, value: store.unreadCount)
                Text(verbatim: "\(store.unreadCount)")
                    .monospacedDigit()
            } else {
                Image(systemName: "bell")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 7)
        .frame(height: 22)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }
}
