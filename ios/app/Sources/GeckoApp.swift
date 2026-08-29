import SwiftUI
import UIKit
import PhotosUI

enum ChatLayout {
    static let horizontalPadding: CGFloat = 16
}

extension View {
    /// Use the platform's standard form size for sheets on the Mac.
    /// No-op elsewhere.
    func macDialogSizing() -> some View {
#if targetEnvironment(macCatalyst)
        presentationSizing(.form)
#else
        self
#endif
    }
}

#if targetEnvironment(macCatalyst)
private struct CatalystToolbarButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(
                        Color.primary.opacity(
                            configuration.isPressed ? 0.14 : (isHovered ? 0.08 : 0)
                        )
                    )
            }
            .onHover { isHovered = $0 }
    }
}

@MainActor
private enum CatalystWindowSize {
    private static let widthKey = "macWindowContentWidth"
    private static let heightKey = "macWindowContentHeight"
    private static let fallback = CGSize(width: 1_100, height: 760)
    static let minimum = CGSize(width: 820, height: 600)
    static let maximum = CGSize(width: 4_096, height: 4_096)

    private static var runningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1"
    }

    static var current = restored

    static var restored: CGSize {
        guard !runningInPreview else { return fallback }
        let defaults = UserDefaults.standard
        let size = CGSize(
            width: defaults.double(forKey: widthKey),
            height: defaults.double(forKey: heightKey)
        )
        guard size.width.isFinite,
              size.height.isFinite,
              size.width >= minimum.width,
              size.height >= minimum.height,
              size.width <= maximum.width,
              size.height <= maximum.height
        else {
            return fallback
        }
        return size
    }

    static func update(_ size: CGSize) {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width >= minimum.width,
              size.height >= minimum.height
        else {
            return
        }
        current = size
    }

    static func save() {
        guard !runningInPreview else { return }
        let defaults = UserDefaults.standard
        defaults.set(current.width, forKey: widthKey)
        defaults.set(current.height, forKey: heightKey)
    }
}

@objc
@MainActor
private final class CatalystWindowDelegateProxy: NSObject {
    private let originalDelegate: NSObject?

    init(originalDelegate: NSObject?) {
        self.originalDelegate = originalDelegate
    }

    @objc(windowShouldClose:)
    private func windowShouldClose(_ sender: NSObject) -> Bool {
        CatalystWindowLifecycle.hideInsteadOfClosing(sender)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        aSelector == #selector(windowShouldClose(_:))
            || super.responds(to: aSelector)
            || originalDelegate?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalDelegate?.responds(to: aSelector) == true {
            return originalDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}

@objc
@MainActor
private final class CatalystApplicationDelegateProxy: NSObject {
    private let originalDelegate: NSObject?

    init(originalDelegate: NSObject?) {
        self.originalDelegate = originalDelegate
    }

    @objc(applicationShouldHandleReopen:hasVisibleWindows:)
    private func applicationShouldHandleReopen(
        _: NSObject,
        hasVisibleWindows _: Bool
    ) -> Bool {
        CatalystWindowLifecycle.reopenIfNeeded()
        return true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        aSelector == #selector(applicationShouldHandleReopen(_:hasVisibleWindows:))
            || super.responds(to: aSelector)
            || originalDelegate?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if originalDelegate?.responds(to: aSelector) == true {
            return originalDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}

@MainActor
enum CatalystWindowLifecycle {
    private static var proxies: [ObjectIdentifier: CatalystWindowDelegateProxy] = [:]
    private static var applicationProxy: CatalystApplicationDelegateProxy?
    private static var hiddenWindow: NSObject?
    private static var visibilityHandler: ((Bool) -> Void)?

    static var isVisible: Bool { hiddenWindow == nil }

    static func setVisibilityHandler(_ handler: @escaping (Bool) -> Void) {
        visibilityHandler = handler
        handler(isVisible)
    }

    static func install() {
        guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let application = applicationClass
                .perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? NSObject
        else {
            return
        }

        if applicationProxy == nil {
            let proxy = CatalystApplicationDelegateProxy(
                originalDelegate: application.value(forKey: "delegate") as? NSObject
            )
            applicationProxy = proxy
            application.setValue(proxy, forKey: "delegate")
        }

        // Only the primary chat window should hide instead of closing. Media
        // windows are real secondary scenes and must be allowed to close and
        // deallocate normally; proxying every AppKit window leaks hidden media
        // scenes and eventually destabilizes repeated viewer opens.
        guard proxies.isEmpty,
              let window = application.value(forKey: "keyWindow") as? NSObject
        else {
            return
        }
        let id = ObjectIdentifier(window)
        let proxy = CatalystWindowDelegateProxy(
            originalDelegate: window.value(forKey: "delegate") as? NSObject
        )
        proxies[id] = proxy
        window.setValue(proxy, forKey: "delegate")
    }

    static func hideInsteadOfClosing(_ window: NSObject) {
        CatalystWindowSize.save()
        hiddenWindow = window
        visibilityHandler?(false)
        window.perform(NSSelectorFromString("orderOut:"), with: nil)
    }

    static func reopenIfNeeded() {
        guard let window = hiddenWindow else { return }
        hiddenWindow = nil
        PushRegistration.clearDelivered()
        window.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
        visibilityHandler?(true)
    }
}

private struct CatalystMediaWindowConfigurator: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async {
            configure(view)
        }
        return view
    }

    func updateUIView(_ view: UIView, context _: Context) {
        DispatchQueue.main.async {
            configure(view)
        }
    }

    private func configure(_ view: UIView) {
        guard let scene = view.window?.windowScene else { return }
        scene.titlebar?.titleVisibility = .hidden
        guard let restrictions = scene.sizeRestrictions else { return }
        restrictions.minimumSize = CGSize(width: 480, height: 320)
        restrictions.maximumSize = CatalystWindowSize.maximum
        restrictions.allowsFullScreen = true
    }
}

#endif

@main
struct GeckoApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
#if targetEnvironment(macCatalyst)
        desktopScene
        mediaViewerScene
#else
        mobileScene
#endif
    }

    private var appContent: some View {
        RootView()
            .environmentObject(model)
            .onAppear {
                model.boot()
                model.setApplicationActive(scenePhase == .active)
                AppDelegate.setOpenHandler { jid in model.openChat(with: jid) }
#if targetEnvironment(macCatalyst)
                configureDesktopWindow()
                // Fires immediately with the current visibility, which is also
                // the only place the initial desktop activity is published.
                CatalystWindowLifecycle.setVisibilityHandler { visible in
                    setDesktopActive(
                        visible && UIApplication.shared.applicationState == .active
                    )
                }
#endif
            }
    }

#if targetEnvironment(macCatalyst)
    /// "The user can actually see this chat window": frontmost AND not hidden
    /// by a window close, which on the Mac only orders the window out. Both the
    /// unread bookkeeping and notification suppression key off this.
    private func setDesktopActive(_ active: Bool) {
        model.setApplicationActive(active)
        MacLocalNotifications.setAppIsActive(active)
    }

    private func configureDesktopWindow() {
        // SwiftUI's contentMinSize currently gives Catalyst identical minimum
        // and maximum sizes. Override only the maximum after scene creation so
        // the native Mac window keeps the content minimum but can grow freely.
        DispatchQueue.main.async {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                guard let restrictions = scene.sizeRestrictions else { continue }
                restrictions.minimumSize = CatalystWindowSize.minimum
                restrictions.maximumSize = CatalystWindowSize.maximum
                restrictions.allowsFullScreen = true
            }
            CatalystWindowLifecycle.install()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                CatalystWindowLifecycle.install()
            }
        }
    }

    private var mediaViewerScene: some Scene {
        WindowGroup(id: MediaViewerItem.windowGroupID, for: MediaViewerItem.self) { $item in
            Group {
                if let item {
                    switch item {
                    case .image(let path):
                        ImageViewer(path: path)
                    case .video(let path):
                        VideoViewer(path: path)
                    }
                } else {
                    Color.black
                }
            }
            .focusedSceneValue(\.mediaViewerItem, item)
            .background {
                CatalystMediaWindowConfigurator()
                    .frame(width: 0, height: 0)
            }
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)
    }

    private var desktopScene: some Scene {
        let restoredSize = CatalystWindowSize.restored
        return WindowGroup {
            appContent
                .frame(
                    minWidth: CatalystWindowSize.minimum.width,
                    minHeight: CatalystWindowSize.minimum.height
                )
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    CatalystWindowSize.update(size)
                }
                .onDisappear {
                    CatalystWindowSize.save()
                }
        }
        .defaultSize(width: restoredSize.width, height: restoredSize.height)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") {
                    model.presentNewMessage()
                }
                .keyboardShortcut("n")
                .disabled(!model.ready || !model.hasAccount)

                Button("Refresh") {
                    model.requestState()
                }
                .keyboardShortcut("r")
                .disabled(!model.ready || !model.hasAccount)

                Button("Close Conversation") {
                    if let id = model.navigation.last {
                        model.closeConversation(id)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.navigation.isEmpty)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.accountSettingsPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!model.ready || !model.hasAccount)
            }

            MediaViewerCommands()

        }
        .onChange(of: scenePhase) { _, phase in
            setDesktopActive(phase == .active && CatalystWindowLifecycle.isVisible)
            if phase != .active {
                CatalystWindowSize.save()
            }
            guard phase == .active else { return }
            PushRegistration.clearDelivered()
            if model.ready && model.hasAccount {
                model.refreshAfterForeground()
            }
        }
    }
#else
    private var mobileScene: some Scene {
        WindowGroup {
            appContent
        }
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActive(phase == .active)
            switch phase {
            case .active:
                // Cancel any pending background-disconnect (quick toggle) and
                // keep the live connection rather than churning it.
                appDelegate.cancelBackgroundDisconnect()
                PushRegistration.clearDelivered()
                if model.ready && model.hasAccount {
                    GeckoCore.shared.appForegrounded()
                    // The notification-service extension may have stored new
                    // messages in the shared DB while we were suspended; reload
                    // so the open chat doesn't miss them.
                    model.refreshAfterForeground()
                }
            case .background:
                // Cleanly disconnect before iOS suspends the process.
                if model.ready && model.hasAccount {
                    appDelegate.scheduleBackgroundDisconnect()
                }
            default:
                break
            }
        }
    }
#endif
}

#if DEBUG
@MainActor
private enum GeckoPreviewFixtures {
    static let account = XmppAccount(id: "rachel@example.org", state: "CONNECTED")

    static let conversations: [XmppConversation] = [
        XmppConversation(
            id: 1,
            jid: "anemone@xmpp.is",
            name: "Anemone",
            encryption: "OMEMO",
            encryptionAvailable: true,
            kind: "chat",
            unread: 3,
            preview: "Sent a few image-heavy test messages",
            previewDirection: "in",
            time: Date().addingTimeInterval(-180),
            notifyEffective: "on"
        ),
        XmppConversation(
            id: 2,
            jid: "gecko@conference.example.org",
            name: "Gecko Dev",
            encryption: "",
            encryptionAvailable: false,
            kind: "groupchat",
            unread: 0,
            preview: "I will test the new composer layout",
            previewDirection: "out",
            time: Date().addingTimeInterval(-3600),
            notifyEffective: "highlight"
        ),
        XmppConversation(
            id: 3,
            jid: "offline@example.org",
            name: "Offline Contact",
            encryption: "",
            encryptionAvailable: false,
            kind: "chat",
            unread: 0,
            preview: "See you later",
            previewDirection: "in",
            time: Date().addingTimeInterval(-86400),
            notifyEffective: "off"
        ),
    ]

    /// A real on-disk image so the "downloaded image" fixtures render an actual
    /// picture (the bubble loads from `msg.path`). Rendered once to a temp file.
    static let sampleImagePath: String = {
        let size = CGSize(width: 1200, height: 800)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient, start: .zero,
                    end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let text = "Sample image" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 72),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                  y: (size.height - textSize.height) / 2),
                      withAttributes: attrs)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gecko-preview-sample.jpg")
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: url)
        }
        return url.path
    }()

    static let messages: [ChatMessage] = [
        ChatMessage(
            id: 88,
            content: "text",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "Morning! Did the new build land on your phone yet?",
            time: Date().addingTimeInterval(-3600),
            encryption: "OMEMO",
            marked: "read"
        ),
        ChatMessage(
            id: 89,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "Just installed it. Pulling up a chat now to look at the bubbles.",
            time: Date().addingTimeInterval(-3540),
            encryption: "OMEMO",
            editable: true,
            marked: "read"
        ),
        ChatMessage(
            id: 90,
            content: "text",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "The corners look much cleaner now. Padding feels right too.",
            time: Date().addingTimeInterval(-3480),
            encryption: "OMEMO",
            marked: "read"
        ),
        ChatMessage(
            id: 91,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "Yeah, I tightened the inset and fixed the timestamp baseline.",
            time: Date().addingTimeInterval(-3420),
            encryption: "OMEMO",
            editable: true,
            marked: "read"
        ),
        ChatMessage(
            id: 92,
            content: "text",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "Here's the screenshot from my device so you can compare side by side.",
            time: Date().addingTimeInterval(-3000),
            encryption: "OMEMO",
            marked: "read"
        ),
        ChatMessage(
            id: 93,
            content: "file",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "",
            time: Date().addingTimeInterval(-2940),
            encryption: "OMEMO",
            fileName: "sunset.jpg",
            mime: "image/jpeg",
            size: 1_280_000,
            fileState: "complete",
            path: sampleImagePath,
            marked: "read"
        ),
        ChatMessage(
            id: 94,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "That gradient renders crisp — thumbnail downsampling is working nicely.",
            time: Date().addingTimeInterval(-2880),
            encryption: "OMEMO",
            editable: true,
            reactions: [
                Reaction(emoji: "🔥", count: 1, me: false),
            ],
            marked: "read"
        ),
        ChatMessage(
            id: 95,
            content: "text",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "Let's also check a really long paragraph so we can see how the bubble wraps across "
                + "several lines and whether the timestamp still sits where it should at the very bottom.",
            time: Date().addingTimeInterval(-2400),
            encryption: "OMEMO",
            marked: "read"
        ),
        ChatMessage(
            id: 96,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "Wrapping looks good even at four or five lines.",
            time: Date().addingTimeInterval(-2340),
            encryption: "OMEMO",
            editable: true,
            marked: "read"
        ),
        ChatMessage(
            id: 97,
            content: "text",
            direction: "in",
            from: "offline@example.org",
            fromDisplay: "Sam",
            body: "Jumping in from the group to test the sender header.",
            time: Date().addingTimeInterval(-1800),
            encryption: "OMEMO",
            marked: "read"
        ),
        ChatMessage(
            id: 98,
            content: "text",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "And another one right after to verify consecutive grouping.",
            time: Date().addingTimeInterval(-1500),
            encryption: "OMEMO",
            marked: "read"
        ),
        ChatMessage(
            id: 99,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "Looks great. Scrolling through more than a page now.",
            time: Date().addingTimeInterval(-1200),
            encryption: "OMEMO",
            editable: true,
            marked: "read"
        ),
        ChatMessage(
            id: 100,
            content: "text",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "Can you check how this wraps in the new bubble layout?",
            time: Date().addingTimeInterval(-600),
            encryption: "OMEMO",
            marked: "read"
        ),
        ChatMessage(
            id: 101,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "Yes. This gives us enough text to verify line wrapping, timestamps, and the outgoing bubble.",
            time: Date().addingTimeInterval(-540),
            encryption: "OMEMO",
            editable: true,
            reactions: [
                Reaction(emoji: "👍", count: 2, me: true),
                Reaction(emoji: "✨", count: 1, me: false),
            ],
            marked: "read",
            quote: QuoteRef(item: 100, from: "Anemone", body: "Can you check how this wraps?")
        ),
        ChatMessage(
            id: 102,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "This one is queued while reconnecting.",
            time: Date().addingTimeInterval(-60),
            encryption: "OMEMO",
            marked: "unsent"
        ),
        ChatMessage(
            id: 103,
            content: "file",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "",
            time: Date().addingTimeInterval(-30),
            encryption: "OMEMO",
            fileName: "photo.jpg",
            mime: "image/jpeg",
            size: 2_400_000,
            fileState: "not_started"
        ),
    ]

    static func model() -> AppModel {
        let model = AppModel()
        model.ready = true
        model.accounts = [account]
        model.accountAlias = "Rachel"
        model.conversations = conversations
        model.messages = [1: messages]
        model.roster = [
            RosterContact(
                id: "anemone@xmpp.is",
                name: "Anemone",
                subscription: "both",
                show: "online"
            ),
            RosterContact(
                id: "offline@example.org",
                name: "Offline Contact",
                subscription: "both",
                show: "offline"
            ),
        ]
        model.subscriptionRequests = ["newfriend@example.org"]
        model.chatStates = [1: "composing"]
        model.typingNames = [1: ["Anemone"]]
        return model
    }
}

#Preview("Conversation List") {
    NavigationStack {
        ConversationListView()
            .environmentObject(GeckoPreviewFixtures.model())
    }
}

#Preview("Conversation Rows") {
    List {
        ForEach(GeckoPreviewFixtures.conversations) { conv in
            ConversationRow(
                conv: conv,
                presence: conv.isGroupchat ? nil : (conv.jid == "offline@example.org" ? "offline" : "online"),
                avatarPath: nil,
                requestAvatar: {}
            )
        }
    }
}

#Preview("Chat") {
    NavigationStack {
        ChatView(conversationId: 1, talksToCore: false)
            .environmentObject(GeckoPreviewFixtures.model())
    }
}

#Preview("Message Bubbles") {
    ScrollView {
        VStack(spacing: 10) {
            ForEach(GeckoPreviewFixtures.messages) { msg in
                MessageBubble(
                    msg: msg,
                    inGroupchat: true,
                    showSender: msg.direction == "in",
                    onEdit: { _ in },
                    onReply: { _ in },
                    onActions: { _ in },
                    onReaction: { _, _ in },
                    onDownloadFile: { _ in }
                )
            }
        }
        .padding()
    }
}
#endif

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Group {
#if targetEnvironment(macCatalyst)
                if !model.ready {
                    ProgressView("Starting Dino core…")
                } else if !model.hasAccount {
                    NavigationStack {
                        AccountSetupView()
                    }
                } else {
                    NavigationSplitView {
                        ConversationListView()
                                .toolbar(removing: .sidebarToggle)
                            .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 420)
                    } detail: {
                        if let id = model.navigation.last,
                           model.conversations.contains(where: { $0.id == id }) {
                            ChatView(conversationId: id)
                                .id(id)
                        } else {
                            ContentUnavailableView(
                                "Select a Conversation",
                                systemImage: "message",
                                description: Text("Choose a conversation from the sidebar.")
                            )
                        }
                    }
                    .navigationSplitViewStyle(.balanced)
                }
#else
                NavigationStack(path: $model.navigation) {
                    Group {
                        if !model.ready {
                            ProgressView("Starting Dino core…")
                        } else if !model.hasAccount {
                            AccountSetupView()
                        } else {
                            ConversationListView()
                        }
                    }
                }
#endif
            }

#if !targetEnvironment(macCatalyst)
            if let item = model.mediaViewerItem {
                switch item {
                case .image(let path):
                    ImageViewer(path: path) {
                        model.mediaViewerItem = nil
                    }
                case .video(let path):
                    VideoViewer(path: path) {
                        model.mediaViewerItem = nil
                    }
                }
            }
#endif
        }
        .alert("Error", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct AccountSetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var jid = ""
    @State private var password = ""
    @State private var submitting = false

    var body: some View {
        Form {
            Section("XMPP Account") {
                TextField("user@example.org", text: $jid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                SecureField("Password", text: $password)
                Button {
                    submitting = true
                    model.addAccount(jid: jid, password: password)
                } label: {
                    if submitting {
                        HStack {
                            ProgressView()
                            Text("Signing in…").padding(.leading, 8)
                        }
                    } else {
                        Text("Sign in")
                    }
                }
                .disabled(submitting || jid.isEmpty || password.isEmpty)
            }
        }
        .navigationTitle("Log In")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.lastError) { _, error in
            if error != nil { submitting = false }
        }
    }
}

struct ConversationListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showJoinMuc = false
    @State private var mucJid = ""
    @State private var mucNick = ""

    private struct ChannelSheetCancelButton: View {
        let action: () -> Void

        var body: some View {
#if targetEnvironment(macCatalyst)
            Button(action: action) {
                Image(systemName: "xmark")
                    .padding(4)
            }
            .accessibilityLabel("Close")
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
#else
            Button("Cancel", role: .cancel, action: action)
                .keyboardShortcut(.cancelAction)
#endif
        }
    }
    private struct ChannelSheetActionButton: View {
        let title: String
        let action: () -> Void

        var body: some View {
#if targetEnvironment(macCatalyst)
            Button(action: action) {
                Text(title)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(.interaction, Capsule())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
#else
            Button(title, action: action)
#endif
        }
    }

    private struct JoinChannelSheet: View {
        @Binding var jid: String
        @Binding var nick: String
        let onJoin: () -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    TextField("room@conference.example.org", text: $jid)
                        .textInputAutocapitalization(.never)
                    TextField("Nickname (optional)", text: $nick)
                        .textInputAutocapitalization(.never)
                }
                .navigationTitle("Join Channel")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ChannelSheetCancelButton {
                            dismiss()
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .confirmationAction) {
                        ChannelSheetActionButton(title: "Join") {
                            onJoin()
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
        }
    }

    private struct CreateChannelSheet: View {
        let request: PendingMucCreate
        let onCreate: () -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    Text("\(request.jid) doesn't exist yet. Create it as a new channel?")
                }
                .navigationTitle("Create Channel?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        ChannelSheetCancelButton {
                            dismiss()
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .confirmationAction) {
                        ChannelSheetActionButton(title: "Create") {
                            onCreate()
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
        }
    }

    private struct ListContents: View {
        @EnvironmentObject var model: AppModel

        var body: some View {
            if !model.subscriptionRequests.isEmpty {
                Section("Contact requests") {
                    ForEach(model.subscriptionRequests, id: \.self) { jid in
                        SubscriptionRequestRow(jid: jid)
                    }
                }
            }
            Section("Conversations") {
                ForEach(model.conversations) { conv in
                    let presence = conv.isGroupchat ? nil : model.presence(for: conv.jid)
                    let row = ConversationRow(
                        conv: conv,
                        presence: presence,
                        avatarPath: model.avatars[conv.jid],
                        requestAvatar: { model.ensureAvatar(for: conv.jid) })
#if targetEnvironment(macCatalyst)
                    Button {
                        model.selectConversation(conv.id)
                    } label: {
                        row
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                model.navigation.last == conv.id
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear
                            )
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            model.closeConversation(conv.id)
                        } label: {
                            Label(conv.isGroupchat ? "Leave Channel" : "Close Conversation",
                                  systemImage: conv.isGroupchat
                                      ? "rectangle.portrait.and.arrow.right"
                                      : "xmark")
                        }
                    }
#else
                    NavigationLink(value: conv.id) {
                        row
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.closeConversation(conv.id)
                        } label: {
                            Label(conv.isGroupchat ? "Leave" : "Close",
                                  systemImage: conv.isGroupchat ? "rectangle.portrait.and.arrow.right" : "xmark")
                        }
                    }
#endif
                }
            }
        }
    }

    private func accountButton(for account: XmppAccount) -> some View {
        Button {
            model.accountSettingsPresented = true
        } label: {
#if targetEnvironment(macCatalyst)
            AvatarView(
                jid: account.id, name: model.accountAlias, isGroup: false, size: 24,
                avatarPath: model.avatars[account.id],
                requestAvatar: { model.ensureAvatar(for: account.id) })
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(accountStatusColor(account.state))
                        .frame(width: 7, height: 7)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
#else
            AvatarView(
                jid: account.id, name: model.accountAlias, isGroup: false, size: 34,
                avatarPath: model.avatars[account.id],
                requestAvatar: { model.ensureAvatar(for: account.id) })
                .padding(3)
                .glassEffect(.regular.tint(accountStatusColor(account.state)).interactive(), in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .contentShape(Circle())
#endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
    }

    /// The Join channel / Account entries behind the toolbar's "More" menu.
    @ViewBuilder
    private var moreMenuContent: some View {
        Button {
            showJoinMuc = true
        } label: {
            Label("Join channel", systemImage: "person.2")
        }
        Button {
            model.accountSettingsPresented = true
        } label: {
            Label("Account", systemImage: "person.crop.circle")
        }
    }

    private var list: some View {
        List {
            ListContents()
        }
        .contentMargins(.horizontal, ChatLayout.horizontalPadding, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Int32.self) { id in
            ChatView(conversationId: id)
                .environmentObject(model)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let account = model.accounts.first {
                    accountButton(for: account)
                }
            }
#if !targetEnvironment(macCatalyst)
            .sharedBackgroundVisibility(.hidden)
#endif
#if targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
                    Button {
                        model.presentNewMessage()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CatalystToolbarButtonStyle())
                    .frame(width: 32, height: 32)
                    .contentShape(.interaction, Rectangle())
                    .accessibilityLabel("New Message")

                    Menu {
                        moreMenuContent
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .contentShape(.interaction, Rectangle())
                    .accessibilityLabel("More")
                }
            }
            .sharedBackgroundVisibility(.visible)
#else
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("New Message", systemImage: "square.and.pencil", action: model.presentNewMessage)
                    .labelStyle(.iconOnly)
                Menu {
                    moreMenuContent
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
            }
#endif
        }
    }

    var body: some View {
        list
        .sheet(isPresented: $model.newMessagePresented) {
            ContactsView(isPresented: $model.newMessagePresented)
                .environmentObject(model)
                .macDialogSizing()
        }
        .sheet(isPresented: $model.accountSettingsPresented) {
            AccountSettingsView(isPresented: $model.accountSettingsPresented)
                .environmentObject(model)
                .macDialogSizing()
        }
        .sheet(isPresented: $showJoinMuc) {
            JoinChannelSheet(jid: $mucJid, nick: $mucNick) {
                model.joinMuc(jid: mucJid, nick: mucNick.isEmpty ? nil : mucNick)
                mucJid = ""
                mucNick = ""
            }
            .macDialogSizing()
        }
        .sheet(item: $model.pendingMucCreate) { pending in
            CreateChannelSheet(request: pending) {
                model.createMuc(jid: pending.jid, nick: pending.nick)
            }
            .macDialogSizing()
        }
    }
}

/// Ring colour for the account avatar, reflecting the connection state.
func accountStatusColor(_ state: String) -> Color {
    switch state.uppercased() {
    case "CONNECTED": return .green
    case "CONNECTING": return .orange
    default: return .red
    }
}

func jidColor(_ jid: String) -> Color {
    let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .red]
    var hash = 5381
    for b in jid.utf8 { hash = ((hash << 5) &+ hash) &+ Int(b) }
    return palette[abs(hash) % palette.count]
}

/// Maps an XMPP presence "show" to a status-dot colour.
func presenceColor(_ show: String) -> Color {
    switch show {
    case "online", "chat": return .green
    case "away", "xa": return .yellow
    case "dnd": return .red
    default: return Color(.systemGray4)  // offline / unknown
    }
}

struct CachedDiskImage<Placeholder: View>: View {
    let path: String?
    let maxPixel: Int
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var loadedKey = ""

    private var cacheKey: String {
        "\(path ?? "")@\(maxPixel)"
    }

    init(
        path: String?,
        maxPixel: Int,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.path = path
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        if let path, let cached = ThumbnailLoader.cachedThumbnail(path: path, maxPixel: maxPixel) {
            _image = State(initialValue: cached)
            _loadedKey = State(initialValue: "\(path)@\(maxPixel)")
        }
    }

    var body: some View {
        let currentKey = cacheKey
        Group {
            if let image, loadedKey == currentKey {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: currentKey) {
            guard let path, !path.isEmpty else {
                image = nil
                loadedKey = currentKey
                return
            }
            if let cached = ThumbnailLoader.cachedThumbnail(path: path, maxPixel: maxPixel) {
                image = cached
                loadedKey = currentKey
                return
            }
            let p = path, mp = maxPixel
            let decoded = await ThumbnailLoader.loadThumbnailAsync(path: p, maxPixel: mp)
            if !Task.isCancelled {
                image = decoded
                loadedKey = currentKey
            }
        }
    }
}

struct AvatarView: View {
    @Environment(\.displayScale) private var displayScale
    let jid: String
    let name: String
    let isGroup: Bool
    var size: CGFloat = 44
    /// XMPP "show" for a status dot, or nil to draw no dot (groups, occupants…).
    var presence: String?
    var avatarPath: String?
    var requestAvatar: (() -> Void)?

    private var initial: String {
        String((name.isEmpty ? jid : name).prefix(1)).uppercased()
    }

    private var fallbackColor: Color {
        jidColor(jid)
    }

    private var maxPixel: Int {
        max(96, Int((size * displayScale * 2).rounded()))
    }

    var body: some View {
        CachedDiskImage(path: avatarPath, maxPixel: maxPixel, contentMode: .fill) {
            fallback
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if let presence {
                Circle()
                    .fill(presenceColor(presence))
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: max(1.5, size * 0.045)))
            }
        }
        .onAppear { requestAvatar?() }
    }

    private var fallback: some View {
        ZStack {
            fallbackColor.opacity(0.85)
            if isGroup {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct ConversationRow: View {
    let conv: XmppConversation
    let presence: String?
    let avatarPath: String?
    let requestAvatar: () -> Void

    private var timeLabel: String {
        GeckoDisplayFormatters.conversationTime(conv.time)
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(jid: conv.jid, name: conv.name, isGroup: conv.isGroupchat,
                       presence: presence, avatarPath: avatarPath, requestAvatar: requestAvatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conv.name)
                        .fontWeight(conv.unread > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    if conv.encryption == "OMEMO" {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
                    }
                    if conv.notifyEffective == "off" {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(timeLabel).font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Text((conv.previewDirection == "out" && !conv.preview.isEmpty ? "You: " : "") + conv.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if conv.unread > 0 {
                        Text("\(conv.unread)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
            }
        }
    }
}

struct SubscriptionRequestRow: View {
    @EnvironmentObject var model: AppModel
    let jid: String

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(jid)
                Text("wants to add you").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.respondSubscription(jid: jid, approve: true)
            } label: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
            }
            .buttonStyle(.plain)
            Button {
                model.respondSubscription(jid: jid, approve: false)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title2)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ContactsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var showAdd = false
    @State private var newJid = ""
    @State private var newAlias = ""
    @State private var search = ""

    private var filtered: [RosterContact] {
        if search.isEmpty { return model.roster }
        return model.roster.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) ||
            $0.id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.roster.isEmpty {
                    Text("No contacts yet. Add one with the + button.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { contact in
                    Button {
                        isPresented = false
                        model.openChat(with: contact.id)
                    } label: {
                        HStack {
                            AvatarView(jid: contact.id, name: contact.displayName, isGroup: false, size: 36,
                                       presence: contact.show, avatarPath: model.avatars[contact.id],
                                       requestAvatar: { model.ensureAvatar(for: contact.id) })
                            VStack(alignment: .leading) {
                                Text(contact.displayName)
                                HStack(spacing: 4) {
                                    Text(contact.id)
                                    if contact.subscription == "both" {
                                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 8))
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    // No full-swipe: reveal the buttons and require a tap, so a
                    // quick swipe can't accidentally block or remove someone.
                    .swipeActions(allowsFullSwipe: false) {
                        if model.isBlocked(contact.id) {
                            Button { model.unblockContact(contact.id) } label: {
                                Label("Unblock", systemImage: "hand.raised.slash")
                            }
                            .tint(.orange)
                        } else {
                            Button { model.blockContact(contact.id) } label: {
                                Label("Block", systemImage: "nosign")
                            }
                            .tint(.red)
                        }
                        Button(role: .destructive) {
                            model.removeContact(jid: contact.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search contacts")
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.requestBlocklist() }
            .toolbar {
#if targetEnvironment(macCatalyst)
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .padding(4)
                    }
                    .accessibilityLabel("Close")
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .padding(4)
                    }
                    .accessibilityLabel("Add Contact")
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
                .sharedBackgroundVisibility(.hidden)
#else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Contact", systemImage: "plus") {
                        showAdd = true
                    }
                    .labelStyle(.iconOnly)
                }
#endif
            }
            .alert("Add contact", isPresented: $showAdd) {
                TextField("user@example.org", text: $newJid)
                    .textInputAutocapitalization(.never)
                TextField("Name (optional)", text: $newAlias)
                Button("Add") {
                    model.addContact(jid: newJid, alias: newAlias.isEmpty ? nil : newAlias)
                    newJid = ""
                    newAlias = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A presence subscription request will be sent.")
            }
        }
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PendingFileSend {
    let url: URL
    let name: String
    let isImage: Bool
    let isVideo: Bool
    let sizeLabel: String

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent.isEmpty ? "File" : url.lastPathComponent
        let byteCount = AttachmentStaging.byteCount(at: url)
        if let byteCount, byteCount > 0 {
            self.sizeLabel = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        } else {
            self.sizeLabel = ""
        }
        self.isImage = ThumbnailLoader.pixelSize(path: url.path) != nil
        self.isVideo = MediaFileKind.isVideo(fileName: self.name)
    }
}

struct ChatView: View {
    @EnvironmentObject var model: AppModel
#if targetEnvironment(macCatalyst)
    @Environment(\.openWindow) private var openWindow
#endif
    let conversationId: Int32
    var talksToCore: Bool = true
    @Namespace private var composerGlass
    @State private var draft = ""
    @State private var showSend = false
    /// Whether the Photo/File attach options are expanded out of the plus
    /// button. A custom expander (not a system Menu) so the options can morph
    /// out of the button's glass rather than popping over it.
    @State private var showAttach = false
    /// Shared height for the composer's buttons and text field so they align.
    private let composerControlHeight: CGFloat = 44
#if targetEnvironment(macCatalyst)
    private let floatingButtonSize: CGFloat = 36
#else
    private let floatingButtonSize: CGFloat = 44
#endif
    private let floatingOverlaySpacing: CGFloat = 8
    /// Match the standard iOS navigation bar side inset so the custom bottom
    /// chrome lines up with the system toolbar above it.
    private let composerHorizontalPadding: CGFloat = ChatLayout.horizontalPadding
    private let composerInputVerticalPadding: CGFloat = 8
    /// Extra visible space between the newest message and the floating composer.
    /// Rows already have 3pt bottom padding, so another 3pt matches the 6pt
    /// row-to-row rhythm instead of leaving a visibly larger composer gap.
    private let composerMessageClearance: CGFloat = 3
    private let topToolbarMessageClearance: CGFloat = 8
    private let topToolbarVerticalPadding: CGFloat = 6
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showOccupants = false
    @State private var occupantDMNick: String?
    @State private var showEncryptionHelp = false
    @State private var editing: ChatMessage?
    @State private var replyingTo: ChatMessage?

    @State private var actionMsg: ChatMessage?
    @State private var showFullTitle = false
    /// Whether the SwiftUI list is pinned to the newest message; gates the
    /// scroll-down button.
    @State private var isAtBottom = true
    /// Bumped to ask the message list to glide to the newest message — the
    /// scroll-down button, and after sending.
    @State private var scrollToBottomToken = 0
    /// A composer send reaches the model asynchronously through the GLib
    /// bridge. Keep its scroll request pending until that new outgoing item is
    /// present, instead of scrolling immediately to the previous last row.
    @State private var outgoingMessageFollowTrigger = OutgoingMessageFollowTrigger()
    @State private var composerHeight: CGFloat = 0
    @State private var keyboardOverlap: CGFloat = 0
    @State private var pendingFileSend: PendingFileSend?

    private func openMediaViewer(_ item: MediaViewerItem) {
#if targetEnvironment(macCatalyst)
        openWindow(id: MediaViewerItem.windowGroupID, value: item)
#else
        model.mediaViewerItem = item
#endif
    }

    private var conversation: XmppConversation? {
        model.conversations.first { $0.id == conversationId }
    }

    private var chatMessages: [ChatMessage] {
        model.messages[conversationId] ?? []
    }

    private var latestMessageItemID: Int32? {
        chatMessages.lazy.map(\.id).max()
    }

    private var latestOutgoingMessageItemID: Int32? {
        chatMessages.lazy
            .filter { $0.direction == "out" }
            .map(\.id)
            .max()
    }

    private var isGroupChat: Bool {
        conversation?.isGroupchat == true
    }

    private var hasComposerAccessory: Bool {
        editing != nil || replyingTo != nil || pendingFileSend != nil
    }

    private var shouldShowSendButton: Bool {
        !draft.isEmpty
    }

    @ViewBuilder
    private var composerArea: some View {
        // Explicit VStack so the banners stack above the input bar in order;
        // without it the banners (a bare ViewBuilder tuple) laid out wrong and
        // the reply preview ended up under the input.
        VStack(spacing: 0) {
            if editing != nil {
                composerBanner(icon: "pencil", cancelLabel: "Cancel edit") {
                    editing = nil
                    draft = ""
                } label: {
                    Text("Editing message").font(.caption)
                }
            }
            if let replyingTo {
                composerBanner(icon: "arrowshape.turn.up.left", cancelLabel: "Cancel reply") {
                    self.replyingTo = nil
                } label: {
                    VStack(alignment: .leading) {
                        Text("Replying to \(replyingTo.fromDisplay.isEmpty ? replyingTo.from : replyingTo.fromDisplay)")
                            .font(.caption.bold())
                        Text(replyingTo.isFile ? replyingTo.fileName : replyingTo.body)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let pendingFileSend {
                pendingFileSendPanel(pendingFileSend)
            }
            inputBar
        }
    }

    private var composerToolbar: some View {
        composerArea
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
                }
            }
    }

    @ViewBuilder
    private var typingIndicatorOverlay: some View {
        if let typingText = model.typingIndicatorText(for: conversationId) {
            HStack {
                Spacer(minLength: 0)
                Text(typingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            .padding(.leading, composerHorizontalPadding)
            .padding(
                .trailing,
                composerHorizontalPadding
                    + (isAtBottom ? 0 : floatingButtonSize + floatingOverlaySpacing))
            .padding(.bottom, typingIndicatorBottomPadding)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func pendingFileSendPanel(_ file: PendingFileSend) -> some View {
        HStack(spacing: 10) {
            if file.isImage {
                CachedDiskImage(path: file.url.path, maxPixel: 360, contentMode: .fill) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemBackground))
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if file.isVideo {
                CachedVideoThumbnail(path: file.url.path,
                                     box: CGSize(width: 76, height: 76),
                                     maxPixel: 360,
                                     playSize: 34)
                    .frame(width: 76, height: 76)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, height: 76)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !file.sizeLabel.isEmpty {
                    Text(file.sizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                cancelPendingFileSend()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel \(file.name)")

            pendingFileSendButton(file)
        }
        .padding(.horizontal, composerHorizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
    @ViewBuilder
    private func pendingFileSendButton(_ file: PendingFileSend) -> some View {
#if targetEnvironment(macCatalyst)
        let action: () -> Void = submitComposer
#else
        let action: () -> Void = confirmPendingFileSend
#endif
        let button = Button(action: action) {
            Image(systemName: "paperplane.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(.blue).interactive(), in: Circle())
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send \(file.name)")
#if targetEnvironment(macCatalyst)
        button.keyboardShortcut(.return, modifiers: [])
#else
        button
#endif
    }

    /// A dismissable banner (typing reply/edit context) shown above the input.
    private func composerBanner<Label: View>(
        icon: String,
        cancelLabel: String,
        onCancel: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption)
            label()
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(cancelLabel)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, composerHorizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var composerTextView: some View {
#if targetEnvironment(macCatalyst)
        PasteAwareComposerTextView(
            text: $draft,
            maxLines: 6,
            canPasteImages: editing == nil,
            onImagePaste: stagePastedImage,
            onSubmit: submitComposer
        )
#else
        PasteAwareComposerTextView(
            text: $draft,
            maxLines: 6,
            canPasteImages: editing == nil,
            onImagePaste: stagePastedImage
        )
#endif
    }

    private var inputBar: some View {
        GlassEffectContainer(spacing: 6) {
            // Bottom-align so the +/send buttons stay pinned to the bottom as the
            // text field grows upward over multiple lines.
            HStack(alignment: .bottom, spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                        showAttach.toggle()
                    }
                } label: {
                    Image(systemName: showAttach ? "xmark" : "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: composerControlHeight, height: composerControlHeight)
                        .glassEffect(.regular.interactive(), in: Circle())
                        // Make the whole circle tappable, not just the glyph.
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showAttach ? "Close attachments" : "Attach")
                .disabled(editing != nil)
                .opacity(editing == nil ? 1 : 0.45)
                // The Photo/File options grow upward out of the plus button —
                // same GlassEffectContainer, so the glass blends as they emerge
                // — instead of a system menu popping over it. Anchored to the
                // button's bottom-leading corner and scaled from there so they
                // visually originate at the plus.
                .overlay(alignment: .bottomLeading) {
                    if showAttach {
                        attachOptions
                            .offset(y: -(composerControlHeight + 8))
                            .transition(.scale(scale: 0.2, anchor: .bottomLeading)
                                .combined(with: .opacity))
                    }
                }

                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Message")
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                    composerTextView
                }
                // Vertical inset too (not just horizontal) so multi-line text
                // stays inside the capsule instead of spilling past its
                // rounded top/bottom edges.
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: composerControlHeight)
                // RoundedRectangle, not Capsule: a wide multi-line field made
                // a Capsule rounds its left/right ends into big semicircles
                // (radius = half the height) that clip the text. Fixed 22pt
                // corners keep a full-width text area; at one line (44pt tall)
                // it still reads as a pill.
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .glassEffectID("composerField", in: composerGlass)
                .onChange(of: draft) { _, value in
                    if editing == nil {
                        model.setTyping(conversationId, !value.isEmpty)
                    }
                    // Drive the send button's presence explicitly so it
                    // morphs in/out (split from / merge into the field) on
                    // BOTH first keystroke and delete-to-empty — relying on
                    // an implicit .animation(value:) didn't animate the
                    // structural removal on delete.
                    // Snappy so the button reaches its tappable position
                    // fast — a slow morph leaves it briefly unresponsive
                    // right after a send (while it animates back in).
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                        showSend = shouldShowSendButton
                    }
                }

                if showSend {
                    // Blue send button that fluidly splits out of the text
                    // field's glass (and merges back when the draft clears),
                    // via the shared GlassEffectContainer + matched id.
                    Button {
                        sendCurrentDraft()
                    } label: {
                        Image(systemName: editing != nil ? "checkmark" : "paperplane.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: composerControlHeight, height: composerControlHeight)
                            .glassEffect(.regular.tint(.blue).interactive(), in: Circle())
                            .glassEffectID("composerSend", in: composerGlass)
                            // Without this the hit area is just the glyph, not
                            // the full circle — taps off the icon did nothing.
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(editing != nil ? "Save edit" : "Send")
                }
            }
            .padding(.horizontal, composerHorizontalPadding)
            .padding(.vertical, composerInputVerticalPadding)
        }
    }

    private var attachOptions: some View {
        // .fixedSize so the pills size to their content rather than being
        // squeezed to the plus button's width by the overlay's proposal.
        VStack(alignment: .leading, spacing: 8) {
            attachOption(icon: "photo", title: "Photo") { showPhotoPicker = true }
            attachOption(icon: "doc", title: "File") { showFileImporter = true }
        }
        .fixedSize()
    }

    private func attachOption(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showAttach = false }
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .frame(height: composerControlHeight)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func setPendingFileSend(_ url: URL) {
        guard acceptAttachmentForStaging(url) else { return }
        let old = pendingFileSend
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            pendingFileSend = PendingFileSend(url: url)
        }
        if old?.url != url {
            cleanupTemporaryAttachment(old)
        }
    }

    private func cancelPendingFileSend() {
        let old = pendingFileSend
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            pendingFileSend = nil
        }
        cleanupTemporaryAttachment(old)
    }

    private func confirmPendingFileSend() {
        guard let pendingFileSend else { return }
        outgoingMessageFollowTrigger.begin(latestItemID: latestMessageItemID)
        model.sendFile(conversationId, path: pendingFileSend.url.path)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            self.pendingFileSend = nil
        }
    }

    private func stagePastedImage(_ image: ComposerPastedImage) {
        guard editing == nil else { return }
        let byteCount = Int64(image.data.count)
        guard AttachmentStaging.canStageFile(byteCount: byteCount) else {
            model.lastError = AttachmentStaging.tooLargeMessage(noun: "image")
            return
        }

        let url = AttachmentStaging.temporaryPastedImageURL(fileExtension: image.fileExtension)
        do {
            try image.data.write(to: url, options: .atomic)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showAttach = false }
            setPendingFileSend(url)
        } catch {
            model.lastError = "Could not paste this image."
        }
    }

    private func acceptAttachmentForStaging(_ url: URL) -> Bool {
        let byteCount = AttachmentStaging.byteCount(at: url)
        guard !AttachmentStaging.canStageFile(byteCount: byteCount) else { return true }
        cleanupTemporaryAttachment(at: url)
        reportAttachmentTooLarge()
        return false
    }

    private func reportAttachmentTooLarge() {
        model.lastError = AttachmentStaging.tooLargeMessage(noun: "file")
    }

    private func cleanupTemporaryAttachment(_ file: PendingFileSend?) {
        guard let file else { return }
        cleanupTemporaryAttachment(at: file.url)
    }

    private func cleanupTemporaryAttachment(at url: URL) {
        guard AttachmentStaging.isInTemporaryDirectory(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func submitComposer() {
        let sendsFile = pendingFileSend != nil
        if !draft.isEmpty {
            sendCurrentDraft()
        }
        if sendsFile {
            confirmPendingFileSend()
        }
    }

    private func sendCurrentDraft() {
        if let editing {
            model.correctMessage(conversationId, item: editing.id, body: draft)
            self.editing = nil
            draft = ""
            showSend = false
            model.setTyping(conversationId, false)
            return
        }

        let body = draft
        if !body.isEmpty {
            outgoingMessageFollowTrigger.begin(latestItemID: latestMessageItemID)
            model.send(conversationId, body, replyTo: replyingTo?.id ?? 0)
        }
        replyingTo = nil
        draft = ""
        showSend = false
        model.setTyping(conversationId, false)
    }

    private func reactionSheet(for m: ChatMessage) -> some View {
        ReactionSheet(
            msg: m,
            onReact: { emoji in
                let mine = m.reactions.first { $0.emoji == emoji }?.me ?? false
                model.setReaction(conversationId, item: m.id, emoji: emoji, add: !mine)
            },
            onReply: {
                editing = nil
                replyingTo = m
            },
            onEdit: m.editable ? {
                replyingTo = nil
                pendingFileSend = nil
                editing = m
                draft = m.body
            } : nil)
    }

    private func messageList(
        topChromeInset: CGFloat,
        bottomChromeInset: CGFloat,
        scrollIndicatorTopInset: CGFloat,
        scrollIndicatorBottomInset: CGFloat,
        scrollButtonBottomPadding: CGFloat
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            SwiftUIMessageList(
                messages: chatMessages,
                messageUpdateWasSynced: model.messageUpdateWasSynced(for: conversationId),
                historyPageRevision: model.historyPageRevision(for: conversationId),
                historyPageRenderedRowsAdded:
                    model.historyPageRenderedRowsAdded(for: conversationId),
                canLoadOlderHistory: model.canLoadOlderHistory(for: conversationId),
                conversationId: conversationId,
                isGroupchat: isGroupChat,
                avatarPaths: model.avatars,
                visualTopInset: topChromeInset,
                visualBottomInset: bottomChromeInset,
                visualScrollIndicatorTopInset: scrollIndicatorTopInset,
                visualScrollIndicatorBottomInset: scrollIndicatorBottomInset,
                model: model,
                isAtBottom: $isAtBottom,
                scrollToBottomToken: scrollToBottomToken,
                onEdit: editFromList,
                onReply: { m in editing = nil; replyingTo = m },
                onImageTap: { path in openMediaViewer(.image(path)) },
                onVideoTap: { path in openMediaViewer(.video(path)) },
                onLoadOlder: { model.requestOlderMessages(conversationId) },
                onActions: { m in actionMsg = m }
            )
            .id(conversationId)
            .ignoresSafeArea(.container, edges: .vertical)

            if !isAtBottom {
                scrollDownButton(bottomPadding: scrollButtonBottomPadding)
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.2), value: isAtBottom)
    }

    /// Shared "begin editing this message" action for both list backends.
    private func editFromList(_ m: ChatMessage) {
        replyingTo = nil
        pendingFileSend = nil
        editing = m
        draft = m.body
    }

    private func bottomChromeInset(safeAreaBottom: CGFloat) -> CGFloat {
        let toolbarHeight = max(composerHeight, composerControlHeight + composerInputVerticalPadding * 2)
        let transparentTopOverlap = hasComposerAccessory ? 0 : composerInputVerticalPadding
        return safeAreaBottom + toolbarHeight - transparentTopOverlap + composerMessageClearance
    }

    private func scrollIndicatorBottomInset() -> CGFloat {
        let toolbarHeight = max(composerHeight, composerControlHeight + composerInputVerticalPadding * 2)
        let transparentTopOverlap = hasComposerAccessory ? 0 : composerInputVerticalPadding
        return max(0, toolbarHeight - transparentTopOverlap - composerInputVerticalPadding)
    }

    private func scrollIndicatorTopInset(safeAreaTop: CGFloat) -> CGFloat {
        max(0, topChromeInset(safeAreaTop: safeAreaTop) - topToolbarVerticalPadding)
    }

    private func chromeSafeAreaBottom(from safeAreaBottom: CGFloat) -> CGFloat {
        max(0, safeAreaBottom - keyboardOverlap)
    }

    private func scrollButtonBottomPadding(bottomChromeInset: CGFloat) -> CGFloat {
        if keyboardOverlap > 0 {
            let toolbarHeight = max(composerHeight, composerControlHeight + composerInputVerticalPadding * 2)
            return toolbarHeight + composerInputVerticalPadding
        }
#if targetEnvironment(macCatalyst)
        // Catalyst has no iPhone home-indicator inset to lift the button. Keep
        // its bottom edge above the composer instead of inside the text field.
        return max(0, bottomChromeInset + floatingOverlaySpacing)
#else
        return max(0, bottomChromeInset - composerInputVerticalPadding)
#endif
    }

    private var typingIndicatorBottomPadding: CGFloat {
        max(composerHeight, composerControlHeight + composerInputVerticalPadding * 2)
            + composerMessageClearance
    }

    private func updateKeyboardOverlap(from note: Notification) {
        guard
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = scene.windows.first(where: \.isKeyWindow),
            let screenFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else {
            keyboardOverlap = 0
            return
        }

        let frame = window.convert(screenFrame, from: nil)
        let overlap = window.bounds.intersection(frame)
        let coversBottom = !overlap.isNull && overlap.maxY >= window.bounds.maxY - 1
        keyboardOverlap = coversBottom ? overlap.height : 0
    }

    private func topChromeInset(safeAreaTop: CGFloat) -> CGFloat {
        // The system navigation bar occupies the top safe area; the message list
        // ignores that safe area and scrolls under the glass bar, so we only add
        // a little breathing room below the bar before the first message.
        safeAreaTop + topToolbarMessageClearance
    }

    private func scrollDownButton(bottomPadding: CGFloat) -> some View {
#if targetEnvironment(macCatalyst)
        Button {
            scrollToBottomToken &+= 1
        } label: {
            Image(systemName: "chevron.down")
                .frame(width: floatingButtonSize, height: floatingButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .accessibilityLabel("Scroll to latest messages")
        .padding(.trailing, composerHorizontalPadding)
        .padding(.bottom, bottomPadding)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
#else
        Button {
            scrollToBottomToken &+= 1
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: floatingButtonSize, height: floatingButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Scroll to latest messages")
        .padding(.trailing, composerHorizontalPadding)
        .padding(.bottom, bottomPadding)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
#endif
    }

    /// Per-conversation notification setting; identical on both platforms, only
    /// its menu chrome differs.
    @ViewBuilder
    private var notifyMenuContent: some View {
        notifyOption("All messages", "on")
        if isGroupChat {
            notifyOption("Only when mentioned", "highlight")
        }
        notifyOption("Off", "off")
    }

    private func showParticipants() {
        model.requestOccupants(conversationId)
        showOccupants = true
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            chatTitleItem
        }
#if targetEnvironment(macCatalyst)
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 0) {
                Menu {
                    notifyMenuContent
                } label: {
                    Image(systemName: bellIcon)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .contentShape(.interaction, Rectangle())
                .accessibilityLabel("Notifications")

                if isGroupChat {
                    Button(action: showParticipants) {
                        Image(systemName: "person.2")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CatalystToolbarButtonStyle())
                    .frame(width: 32, height: 32)
                    .contentShape(.interaction, Rectangle())
                    .accessibilityLabel("Participants")
                }

                Button(action: toggleEncryption) {
                    Image(systemName: lockIcon)
                        .foregroundStyle(lockTint)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CatalystToolbarButtonStyle())
                .frame(width: 32, height: 32)
                .contentShape(.interaction, Rectangle())
                .accessibilityLabel(lockAccessibilityLabel)
            }
        }
        .sharedBackgroundVisibility(.visible)
#else
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                notifyMenuContent
            } label: {
                Image(systemName: bellIcon)
            }
            .accessibilityLabel("Notifications")
        }
        if isGroupChat {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showParticipants) {
                    Image(systemName: "person.2")
                }
                .accessibilityLabel("Participants")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: toggleEncryption) {
                Image(systemName: lockIcon)
                    .foregroundStyle(lockTint)
            }
            .accessibilityLabel(lockAccessibilityLabel)
        }
#endif
    }

    /// The tappable avatar+name shown in the navigation bar's principal slot.
    /// Tapping reveals the full title/JID popover (long names truncate inline).
    private var chatTitleItem: some View {
        let name: String = conversation?.name ?? "Chat"
        let jid: String = conversation?.jid ?? ""
        return Button {
            showFullTitle = true
        } label: {
            HStack(spacing: 8) {
                AvatarView(
                    jid: jid, name: name, isGroup: isGroupChat, size: 30,
                    presence: isGroupChat ? nil : model.presence(for: jid),
                    avatarPath: model.avatars[jid],
                    requestAvatar: jid.isEmpty ? nil : { model.ensureAvatar(for: jid) })
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFullTitle, arrowEdge: .top) {
            titlePopover
        }
    }

    private var titlePopover: some View {
        let name: String = conversation?.name ?? "Chat"
        let jid: String = conversation?.jid ?? ""
        return HStack(spacing: 12) {
            AvatarView(jid: jid, name: name, isGroup: isGroupChat, size: 44,
                       avatarPath: model.avatars[jid],
                       requestAvatar: jid.isEmpty ? nil : { model.ensureAvatar(for: jid) })
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                if !jid.isEmpty, jid != name {
                    Text(jid)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(12)
        .presentationCompactAdaptation(.popover)
    }

    private func toggleEncryption() {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        let available: Bool = conversation?.encryptionAvailable ?? false
        if available {
            model.setEncryption(conversationId, omemo: !omemoOn)
        } else {
            showEncryptionHelp = true
        }
    }

    private var lockIcon: String {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        let available: Bool = conversation?.encryptionAvailable ?? false
        return available ? (omemoOn ? "lock.fill" : "lock.open") : "lock.slash"
    }

    private var lockTint: Color {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        let available: Bool = conversation?.encryptionAvailable ?? false
        return omemoOn && available ? .green : .secondary
    }

    private var lockAccessibilityLabel: String {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        let available: Bool = conversation?.encryptionAvailable ?? false
        return available ? (omemoOn ? "Encryption on" : "Encryption off") : "Encryption unavailable"
    }

    @ViewBuilder
    private func notifyOption(_ title: String, _ value: String) -> some View {
        let effective = conversation?.notifyEffective ?? "on"
        Button {
            model.setNotify(conversationId, value)
        } label: {
            if effective == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var bellIcon: String {
        switch conversation?.notifyEffective {
        case "off": return "bell.slash"
        case "highlight": return "bell.badge"
        default: return "bell"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let topInset = topChromeInset(safeAreaTop: geo.safeAreaInsets.top)
            let chromeSafeAreaBottom = chromeSafeAreaBottom(from: geo.safeAreaInsets.bottom)
            let bottomInset = bottomChromeInset(safeAreaBottom: chromeSafeAreaBottom)
            let indicatorTopInset = scrollIndicatorTopInset(safeAreaTop: geo.safeAreaInsets.top)
            let indicatorBottomInset = scrollIndicatorBottomInset()
            messageList(
                topChromeInset: topInset,
                bottomChromeInset: bottomInset,
                scrollIndicatorTopInset: indicatorTopInset,
                scrollIndicatorBottomInset: indicatorBottomInset,
                scrollButtonBottomPadding: scrollButtonBottomPadding(bottomChromeInset: bottomInset))
                // Tap anywhere in the chat to dismiss the attach expander (the
                // system Menu used to give this for free). The composer itself is
                // added as a later overlay so the plus/X and options stay tappable.
                .overlay {
                    if showAttach {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    showAttach = false
                                }
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    composerToolbar
                }
                .overlay(alignment: .bottomTrailing) {
                    typingIndicatorOverlay
                        .animation(.easeInOut(duration: 0.18),
                                   value: model.typingIndicatorText(for: conversationId) != nil)
                }
                .onPreferenceChange(ComposerHeightKey.self) { height in
                    if abs(composerHeight - height) > 0.5 {
                        composerHeight = height
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification
        )) { note in
            updateKeyboardOverlap(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { _ in
            keyboardOverlap = 0
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(
                allowsVideos: true,
                onPicked: { url in setPendingFileSend(url) },
                onTooLarge: reportAttachmentTooLarge)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                guard acceptAttachmentForStaging(url) else {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    return
                }
                if let dest = AttachmentStaging.stageCopy(of: url) {
                    setPendingFileSend(dest)
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        .navigationTitle(conversation?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar { chatToolbar }
        .sheet(isPresented: $showOccupants, onDismiss: {
            // Start the DM only after the sheet has finished sliding away, so
            // the push into the new chat reads as a distinct second step.
            if let nick = occupantDMNick {
                occupantDMNick = nil
                model.startOccupantDM(conversationId, nick: nick)
            }
        }) {
            RoomDetailsView(conversationId: conversationId) { nick in
                occupantDMNick = nick
                showOccupants = false
            }
            .environmentObject(model)
        }
        .sheet(item: $actionMsg) { m in
            reactionSheet(for: m)
        }
        .onChange(of: model.viewerRequest) { _, path in
            if let path {
                openMediaViewer(.image(path))
                model.viewerRequest = nil
            }
        }
        .onChange(of: model.messageRevision(for: conversationId)) { _, _ in
            if outgoingMessageFollowTrigger.observe(
                latestOutgoingItemID: latestOutgoingMessageItemID
            ) {
                scrollToBottomToken &+= 1
            }
        }
        .onAppear {
            guard talksToCore else { return }
            model.openConversation(conversationId)
            model.focusConversation(conversationId)
            // So the encryption-help dialog knows whether you're the owner.
            if isGroupChat { model.requestRoomInfo(conversationId) }
        }
        .onDisappear {
            guard talksToCore else { return }
            model.blurConversation(conversationId)
        }
        .confirmationDialog("Encryption unavailable", isPresented: $showEncryptionHelp, titleVisibility: .visible) {
            if model.roomInfo[conversationId]?.iAmOwner == true {
                Button("Make room private") { model.setRoomPrivate(conversationId, true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.roomInfo[conversationId]?.iAmOwner == true {
                Text("End-to-end encryption needs a private room (members-only, with member addresses visible). "
                     + "Make it private to enable encryption, then tap the lock.")
            } else {
                Text("End-to-end encryption needs a private room (members-only, with member addresses visible). "
                     + "Ask a room owner to make it private.")
            }
        }
    }
}

// linkifiedBody(_:) and messageRuns(_:) live in GeckoKit/Sources/GeckoKit/
// MessageFormatting.swift — compiled into this app module by build-app.sh and
// unit-tested via `swift test` in the GeckoKit package.

/// Render a message body: lines starting with `>` become a blockquote (accent
/// bar + muted text), everything else is normal linkified text.
@ViewBuilder
private func messageBody(_ text: String) -> some View {
    if !text.hasPrefix(">") && !text.contains("\n>") {
        Text(linkifiedBody(text)).tint(.accentColor)   // common path: no quotes
    } else {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(messageRuns(text).enumerated()), id: \.offset) { _, run in
                if run.isQuote {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor.opacity(0.5))
                            .frame(width: 3)
                        Text(linkifiedBody(run.text))
                            .italic()
                            .foregroundStyle(.secondary)
                            .tint(.accentColor)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(linkifiedBody(run.text)).tint(.accentColor)
                }
            }
        }
    }
}

struct MessageBubble: View {
    let msg: ChatMessage
    var inGroupchat: Bool = false
    var showSender: Bool = false
    var senderAvatarPath: String?
    var onEdit: ((ChatMessage) -> Void)? = nil
    var onReply: ((ChatMessage) -> Void)? = nil
    var onImageTap: ((String) -> Void)? = nil
    var onVideoTap: ((String) -> Void)? = nil
    var onActions: ((ChatMessage) -> Void)? = nil
    var onAvatarNeeded: ((String) -> Void)? = nil
    var onReaction: ((String, Bool) -> Void)? = nil
    var onDownloadFile: ((Int32) -> Void)? = nil
    var onImageRendered: (() -> Void)? = nil

    @State private var dragOffset: CGFloat = 0
    @State private var replyArmed = false

    private let replyTriggerOffset: CGFloat = 56
    private let replyMaxOffset: CGFloat = 78

    private var replyProgress: CGFloat {
        min(dragOffset / replyTriggerOffset, 1)
    }

    private var replyIndicatorOpacity: Double {
        guard dragOffset > 4 else { return 0 }
        return Double(min(dragOffset / 36, 1))
    }

    @ViewBuilder
    private var markIcon: some View {
        switch msg.marked {
        case "unsent":
            // Queued: the stream was null (disconnected/connecting), so the
            // message is persisted UNSENT and will flush on reconnect. Make
            // that visible rather than letting it look like a normal in-flight
            // message — otherwise the user can't tell it hasn't gone out.
            HStack(spacing: 2) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Pending")
            }
            .font(.system(size: 9))
            .foregroundStyle(.orange)
        case "sending":
            Image(systemName: "clock").font(.system(size: 8))
        case "sent":
            Image(systemName: "checkmark").font(.system(size: 8))
        case "received", "acknowledged":
            Image(systemName: "checkmark").font(.system(size: 8)).foregroundStyle(.secondary)
        case "read":
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 8))
            .foregroundStyle(Color.accentColor)
        case "error", "wontsend":
            Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    var body: some View {
        // The whole row slides right on swipe; the reply icon is anchored to the
        // bubble's leading edge (a leading-aligned background on the bubble) and
        // counter-offset by the drag so it holds still, getting revealed from
        // beneath the bubble as it slides off it.
#if targetEnvironment(macCatalyst)
        bubbleRow
            .offset(x: dragOffset)
            .contextMenu {
                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                    onReply?(msg)
                }
                if msg.editable {
                    Button("Edit", systemImage: "pencil") {
                        onEdit?(msg)
                    }
                }
                if !msg.body.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = msg.body
                    }
                }
                Button("Reactions and More…", systemImage: "face.smiling") {
                    onActions?(msg)
                }
            }
#else
        bubbleRow
            .offset(x: dragOffset)
#endif
    }

    private var replyIndicator: some View {
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(replyArmed ? Color.accentColor : Color.secondary)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color(.secondarySystemBackground).opacity(0.9)))
            .scaleEffect(0.82 + replyProgress * 0.18)
            .opacity(replyIndicatorOpacity)
            .allowsHitTesting(false)
    }

    private var bubbleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.direction == "out" { Spacer(minLength: 40) }
            if inGroupchat && msg.direction == "in" {
                if showSender {
                    AvatarView(jid: msg.from, name: msg.fromDisplay, isGroup: false, size: 30,
                               avatarPath: senderAvatarPath,
                               requestAvatar: { onAvatarNeeded?(msg.from) })
                        .padding(.top, showSender ? 16 : 0)
                        // Sit in front of the reply icon (a background of the
                        // bubble): as the row slides on swipe, the avatar passes
                        // over the stationary icon and should occlude it, just
                        // like the bubble does.
                        .zIndex(1)
                } else {
                    Color.clear.frame(width: 30, height: 1)
                }
            }
            VStack(alignment: msg.direction == "out" ? .trailing : .leading, spacing: 2) {
                if showSender {
                    Text(msg.fromDisplay.isEmpty ? (msg.from.components(separatedBy: "/").last ?? msg.from) : msg.fromDisplay)
                        .font(.caption.bold())
                        .foregroundStyle(jidColor(msg.from))
                        .padding(.leading, 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let quote = msg.quote {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.accentColor)
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(quote.from)
                                    .font(.caption2.bold())
                                Text(quote.body)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    if msg.isFile {
                        FileContent(msg: msg, onImageTap: onImageTap, onVideoTap: onVideoTap,
                                    onDownloadFile: onDownloadFile,
                                    onImageRendered: onImageRendered)
                    } else {
                        messageBody(msg.body)
                    }
                    HStack(spacing: 4) {
                        if msg.encryption == "OMEMO" {
                            Image(systemName: "lock.fill").font(.system(size: 8))
                        }
                        Text(msg.time, style: .time).font(.system(size: 9))
                        if msg.direction == "out" {
                            markIcon
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(msg.direction == "out" ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // Reply affordance parked just behind the bubble's leading edge
                // and counter-offset by the drag, so it holds still while the
                // bubble slides off it — revealed from beneath the bubble for both
                // incoming and outgoing messages (it lives at the bubble, not at
                // the row's edge). Hidden at rest via `replyIndicatorOpacity`.
                .background(alignment: .leading) {
                    replyIndicator
                        .offset(x: -dragOffset)
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.35) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onActions?(msg)
                }
                // Slide-to-reply is anchored to the bubble itself, not the whole
                // row — dragging the empty gutter beside a message no longer arms
                // a reply. The whole row still slides as visual feedback (the
                // offset lives on `bubbleRow`).
                .gesture(replySwipeGesture)
                if !msg.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(msg.reactions, id: \.emoji) { r in
                            Button {
                                onReaction?(r.emoji, !r.me)
                            } label: {
                                Text("\(r.emoji) \(r.count)")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(r.me ? Color.accentColor.opacity(0.3) : Color(.secondarySystemBackground)))
                                    .overlay(
                                        Capsule().stroke(r.me ? Color.accentColor : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if msg.direction != "out" { Spacer(minLength: 40) }
        }
    }

    private var replySwipeGesture: some Gesture {
        // Measure in the GLOBAL space, not the bubble's local space: the gesture
        // lives on the bubble, but the bubble is the view we shift by `dragOffset`.
        // In local coordinates that shift moves the view out from under the finger,
        // shrinking the translation, which shrinks the offset — a feedback loop
        // that makes the bubble vibrate. Global coordinates are immune to the
        // view's own offset, so the translation tracks the finger cleanly.
        DragGesture(minimumDistance: 25, coordinateSpace: .global)
            .onChanged { value in
                // Horizontal pull to the right only; vertical motion stays scroll.
                guard value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = replyOffset(for: value.translation.width)
                let armed = value.translation.width >= replyTriggerOffset
                if armed && !replyArmed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                replyArmed = armed
            }
            .onEnded { value in
                let shouldReply = value.translation.width >= replyTriggerOffset
                    && abs(value.translation.width) > abs(value.translation.height)
                if shouldReply {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onReply?(msg)
                }
                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                    dragOffset = 0
                    replyArmed = false
                }
            }
    }

    private func replyOffset(for translation: CGFloat) -> CGFloat {
        guard translation > replyTriggerOffset else { return max(0, translation) }
        let extra = (translation - replyTriggerOffset) * 0.35
        return min(replyMaxOffset, replyTriggerOffset + extra)
    }
}

/// Inline image preview backed by a downsampled, cached thumbnail. Avoids the
/// scroll-killing pattern of decoding a full-resolution image from disk inside
/// `body` on every re-render: the decode happens once, off the main thread, at
/// preview size (ThumbnailLoader), and cache hits render immediately.
struct CachedThumbnail: View {
    let path: String
    /// Longest-side pixel budget: ~the 280pt max preview at 3x retina.
    private let maxPixel = 840
    /// The box the preview is fit into (matches the old maxWidth/maxHeight).
    static let box = CGSize(width: 220, height: 280)
    @State private var image: UIImage?
    /// The row's final on-screen size, reserved BEFORE the image decodes (from a
    /// cheap header read of its real dimensions). Holding the row at its final
    /// height from the first layout means it never grows when the decode lands —
    /// so a chat already pinned to the bottom stays pinned, instead of being left
    /// scrolled to the new image's top with its bottom below the fold.
    private let reserved: CGSize

    init(path: String) {
        self.path = path
        // Seed from cache synchronously so an already-decoded image appears with
        // no placeholder flash while scrolling back over it.
        _image = State(initialValue: ThumbnailLoader.cachedThumbnail(path: path, maxPixel: 840))
        if let px = ThumbnailLoader.pixelSize(path: path) {
            reserved = ThumbnailLoader.fit(px, in: Self.box)
        } else {
            reserved = CGSize(width: 200, height: 150)   // header unreadable: stable fallback
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                // Neutral placeholder until the thumbnail decodes. Same reserved
                // frame as the loaded image, so there's no layout shift.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))
            }
        }
        .frame(width: reserved.width, height: reserved.height)
        .task(id: path) {
            guard image == nil else { return }   // seeded from cache
            let p = path, mp = maxPixel
            let decoded = await ThumbnailLoader.loadThumbnailAsync(path: p, maxPixel: mp)
            if !Task.isCancelled, let decoded { image = decoded }
        }
    }
}

/// Inline video poster backed by AVFoundation's first-frame generator. The frame
/// stays fixed while the poster lands so rows do not resize during scrolling;
/// aspect-fit keeps portrait and square videos uncropped inside that frame.
struct CachedVideoThumbnail: View {
    private struct Request: Hashable {
        let path: String
        let maxPixel: Int
    }

    let path: String
    /// The box the preview is fit into.
    let box: CGSize
    let maxPixel: Int
    let playSize: CGFloat
    @State private var image: UIImage?
    @State private var loadedRequest: Request?

    init(
        path: String,
        box: CGSize = CGSize(width: 220, height: 124),
        maxPixel: Int = 840,
        playSize: CGFloat = 50
    ) {
        self.path = path
        self.box = box
        self.maxPixel = maxPixel
        self.playSize = playSize
        let request = Request(path: path, maxPixel: maxPixel)
        let cached = ThumbnailLoader.cachedVideoThumbnail(path: path, maxPixel: maxPixel)
        _image = State(initialValue: cached)
        _loadedRequest = State(initialValue: cached == nil ? nil : request)
    }

    var body: some View {
        let request = Request(path: path, maxPixel: maxPixel)
        ZStack {
            Group {
                if let image, loadedRequest == request {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()

            Image(systemName: "play.fill")
                .font(.system(size: playSize * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, playSize * 0.06)
                .frame(width: playSize, height: playSize)
                .background(.black.opacity(0.36), in: Circle())
        }
        .frame(width: box.width, height: box.height)
        .task(id: request) {
            if let cached = ThumbnailLoader.cachedVideoThumbnail(
                path: request.path,
                maxPixel: request.maxPixel) {
                image = cached
                loadedRequest = request
                return
            }
            image = nil
            loadedRequest = nil
            let decoded = await ThumbnailLoader.loadVideoThumbnail(
                path: request.path,
                maxPixel: request.maxPixel)
            if !Task.isCancelled {
                image = decoded
                loadedRequest = request
            }
        }
    }
}

struct FileContent: View {
    let msg: ChatMessage
    var onImageTap: ((String) -> Void)? = nil
    var onVideoTap: ((String) -> Void)? = nil
    var onDownloadFile: ((Int32) -> Void)? = nil
    var onImageRendered: (() -> Void)? = nil

    private var sizeLabel: String {
        GeckoDisplayFormatters.fileSize(msg.size)
    }

    var body: some View {
        if msg.fileState == "complete", msg.isImage, !msg.path.isEmpty {
            // Downsampled + cached off the main thread (CachedThumbnail), not
            // decoded full-res in body on every scroll frame. The viewer (on tap)
            // still loads the full-resolution file from msg.path.
            // CachedThumbnail reserves its final size up front (from the image
            // header) so the row doesn't grow when the decode lands.
            CachedThumbnail(path: msg.path)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Safety net: should the reserved size ever be wrong (an
                // unreadable header), report a late height change so the chat can
                // still re-pin. With the size reserved this normally fires once.
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size.height, initial: true) { _, _ in
                                onImageRendered?()
                            }
                    }
                }
                .onTapGesture {
                    onImageTap?(msg.path)
                }
        } else if msg.fileState == "complete", msg.isVideo, !msg.path.isEmpty {
            Button {
                onVideoTap?(msg.path)
            } label: {
                CachedVideoThumbnail(path: msg.path)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(videoAccessibilityLabel)
        } else if msg.fileState == "complete", !msg.path.isEmpty {
            // No inline preview for this type — hand it to the share sheet so
            // the user can open it in any app that handles it, save it to
            // Files, etc.
            ShareLink(item: URL(fileURLWithPath: msg.path)) { fileRow }
                .buttonStyle(.plain)
        } else {
            fileRow
                .onTapGesture {
                    if msg.direction == "in",
                       msg.fileState == "not_started" || msg.fileState == "failed" {
                        onDownloadFile?(msg.id)
                    }
                }
        }
    }

    private var fileRow: some View {
        HStack(spacing: 8) {
            switch msg.fileState {
            case "in_progress":
                ProgressView().controlSize(.small)
            case "failed":
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            case "complete":
                Image(systemName: completeIcon).foregroundStyle(.secondary)
            default:
                Image(systemName: "arrow.down.circle").font(.title3)
            }
            VStack(alignment: .leading) {
                Text(msg.fileName.isEmpty ? "File" : msg.fileName).lineLimit(1)
                HStack(spacing: 4) {
                    if !sizeLabel.isEmpty { Text(sizeLabel) }
                    if msg.fileState == "failed" { Text("failed") }
                    if msg.fileState == "in_progress" { Text(msg.direction == "out" ? "uploading…" : "downloading…") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var completeIcon: String {
        if msg.isImage { return "photo" }
        if msg.isVideo { return "play.rectangle.fill" }
        return "doc.fill"
    }

    private var videoAccessibilityLabel: String {
        let name = msg.fileName.isEmpty ? "video" : msg.fileName
        return "Play \(name)"
    }
}
