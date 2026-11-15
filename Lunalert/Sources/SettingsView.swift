import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window: same sky, tabs and cards as the panel, sized to its content.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(NotificationStore.shared))
            host.sizingOptions = .preferredContentSize
            let window = SkyMaskWindow(contentViewController: host)
            window.title = "Lunalert Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovable = false // SkyMaskWindow drags itself, in step with the sky
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            self.window = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { _ in
                Task { @MainActor in StatusItemController.shared.keepPanelOpen(false) }
            }
        }
        StatusItemController.shared.keepPanelOpen(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A window that drags itself by its top band. Moving the window and sliding its sky happen in one Core
/// Animation commit, so the window reads as a mask over a still sky instead of the sky catching up a frame late.
final class SkyMaskWindow: NSWindow {
    /// Height of the draggable band at the top (the header), and the close button's corner to leave alone.
    private let band: CGFloat = 74
    private let buttonCorner: CGFloat = 64

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, let content = contentView else { return super.sendEvent(event) }
        let p = event.locationInWindow
        let inBand = p.y > content.bounds.height - band && p.x > buttonCorner
        guard inBand else { return super.sendEvent(event) }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = frame.origin
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let mouse = NSEvent.mouseLocation
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setFrameOrigin(NSPoint(x: startOrigin.x + mouse.x - startMouse.x, y: startOrigin.y + mouse.y - startMouse.y))
            CATransaction.commit()
            CATransaction.flush()
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case account, alerts, inbox, sky, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .account: return "Account"
        case .alerts: return "Alerts"
        case .inbox: return "Inbox"
        case .sky: return "Sky"
        case .about: return "About"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: NotificationStore
    @ObservedObject private var location = SkyLocation.shared
    @ObservedObject private var stargaze = SkyModel.shared
    @State private var tab: SettingsTab
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var confirmDisconnect = false
    @AppStorage("animatedSky") private var animatedSky = true
    @AppStorage("constellationLines") private var constellationLines = true
    @AppStorage("panelAppearance") private var panelAppearance: PanelAppearance = .night
    @Namespace private var tabs

    init(tab: SettingsTab = .account) {
        _tab = State(initialValue: tab)
    }

    private let intervals: [Double] = [60, 120, 300, 600, 900]
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            // Every pane is laid out at once, so the window keeps the tallest one's size and never jumps.
            ZStack(alignment: .top) {
                ForEach(SettingsTab.allCases) { item in
                    pane(item)
                        .opacity(item == tab ? 1 : 0)
                        .allowsHitTesting(item == tab)
                        .accessibilityHidden(item != tab)
                }
            }
            .padding(Spacing.gutter)
            .padding(.bottom, 6)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(SpaceBackground())
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.18), value: tab)
        .onAppear { store.refreshBannerPermission() }
        .confirmationDialog("Disconnect from GitHub?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { store.disconnect() }
        } message: {
            Text("Lunalert removes the token from your Keychain and stops checking. The token itself stays valid on GitHub.")
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            LunalertMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Settings").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.starlight)
                Text("Lunalert \(version)").font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.top, 34) // clears the window's close button
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { item in
                let selected = tab == item
                Button { tab = item } label: {
                    Text(item.label)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule().fill(Theme.accent).frame(height: 2).glow(Theme.accent, radius: 4)
                                    .matchedGeometryEffect(id: "settings-tab", in: tabs)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.leading, Spacing.gutter - 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // MARK: Panes

    @ViewBuilder
    private func pane(_ item: SettingsTab) -> some View {
        switch item {
        case .account: account
        case .alerts: alerts
        case .inbox: inbox
        case .sky: skyPane
        case .about: about
        }
    }

    @ViewBuilder
    private var account: some View {
        SettingsCard {
            if store.hasToken {
                SettingsRow("Connected as", detail: "The token is kept in your login Keychain.") {
                    HStack(spacing: 8) {
                        if let login = store.login { Identicon(login: login, size: 18) }
                        Text(store.login.map { "@\($0)" } ?? "checking…")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                }
                SettingsRow("Use a different token", detail: "Disconnect, then paste the new one in the panel.") {
                    Button("Disconnect…") { confirmDisconnect = true }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                SettingsRow("Not connected", detail: "Paste a GitHub token in the panel to start.") {
                    Button("Open Lunalert") { StatusItemController.shared.openPanel() }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var alerts: some View {
        SettingsCard {
            SettingsRow("macOS permission", detail: permissionDetail) {
                Button("Notification Settings…") { store.openNotificationSettings() }.buttonStyle(SecondaryButtonStyle())
            }
            SettingsRow("Stargaze (alerts off)", detail: "No banners while it's on. Leave it from the sky or the menu-bar item's right-click menu.") {
                Toggle("", isOn: $stargaze.stargazing).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Play a sound") {
                Toggle("", isOn: $store.soundEnabled).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Try it") {
                Button("Send Test Banner") { store.sendTestBanner() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var permissionDetail: String {
        switch store.bannersAllowed {
        case true?: return "Allowed"
        case false?: return "Off: macOS is blocking Lunalert's banners"
        case nil: return "Not asked yet"
        }
    }

    @ViewBuilder
    private var inbox: some View {
        SettingsCard {
            SettingsRow("Check GitHub every", detail: "GitHub may ask for longer; Lunalert waits at least that long.") {
                Picker("", selection: $store.pollIntervalSeconds) {
                    ForEach(intervals, id: \.self) { seconds in
                        Text(seconds < 120 ? "minute" : "\(Int(seconds / 60)) minutes").tag(seconds)
                    }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow("CI runs", detail: "Applies to the list, the count and banners.") {
                Picker("", selection: $store.ciFilter) {
                    ForEach(CIFilter.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow("Group CI runs by branch") {
                Toggle("", isOn: $store.groupCI).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Mark done when opened") {
                Toggle("", isOn: $store.doneOnOpen).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder
    private var skyPane: some View {
        SettingsCard {
            SettingsRow("Panel") {
                Picker("", selection: $panelAppearance) {
                    ForEach(PanelAppearance.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow("Twinkling stars") {
                Toggle("", isOn: $animatedSky).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Constellation lines") {
                Toggle("", isOn: $constellationLines).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Precise location", detail: "Sky over \(location.source). Never leaves your Mac.") {
                Toggle("", isOn: $location.precise).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder
    private var about: some View {
        SettingsCard {
            SettingsRow("Open Lunalert at login", detail: loginItemError) {
                Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }
            SettingsRow("Privacy", detail: "No analytics. Talks only to api.github.com.") { EmptyView() }
            SettingsRow("Star data", detail: "d3-celestial (BSD-3) from the Yale Bright Star Catalog") { EmptyView() }
            SettingsRow("Source") {
                Link("github.com/bar-amir/lunalert", destination: URL(string: "https://github.com/bar-amir/lunalert")!)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// A card of rows, separated by hairlines.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(DividedRows()) { content }
        }
        .card()
    }
}

private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        ForEach(children) { child in
            child
            if child.id != children.last?.id {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, Spacing.cardInset)
            }
        }
    }
}

/// A label (and optional detail) on the left, its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, Spacing.cardInset)
        .padding(.vertical, 11)
        .frame(minHeight: 46)
    }
}
