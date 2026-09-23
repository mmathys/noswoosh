import Cocoa
import ServiceManagement

// MARK: - Settings window

// A plain AppKit window: two groups of checkboxes and a permission line. It is
// the only UI this app has, so it stays a window rather than a scene — no
// SwiftUI, nothing to load, and it costs nothing until the user opens it.
//
// Checkboxes, not switches: the HIG asks for a checkbox to present a single
// setting that can be on or off, and reserves the switch's heavier weight for
// controls that govern more than one thing ("in general, don't replace a
// checkbox with a switch").
final class SettingsWindow: NSObject, NSWindowDelegate {
    // Fixed width: the content is short enough that sizing to the longest label
    // makes the window jump around as its own copy changes, and a settings window
    // has no resize control to correct it with.
    private static let width: CGFloat = 440
    private static let inset: CGFloat = 20
    private var textWidth: CGFloat { Self.width - Self.inset * 2 }

    private var window: NSWindow?
    // lazy throughout: this instance is a global, so eager properties would build
    // AppKit controls during top-level initialisation — before NSApplication.shared
    // exists. Nothing here is constructed until the user opens the window.
    private lazy var loginCheckbox = NSButton(checkboxWithTitle: "Launch on login",
                                              target: nil, action: nil)
    private lazy var hideIconCheckbox = NSButton(checkboxWithTitle: "Hide menu bar icon",
                                                 target: nil, action: nil)
    private lazy var hotkeyCheckbox = NSButton(checkboxWithTitle: "Ctrl + ← / → switches spaces",
                                               target: nil, action: nil)
    private lazy var swipeCheckbox = NSButton(checkboxWithTitle: "Three-finger swipe switches spaces",
                                              target: nil, action: nil)
    private lazy var grantTitle = NSTextField(labelWithString: "Accessibility permission needed")
    private lazy var grantDetail = NSTextField(labelWithString: "")
    private lazy var grantButton = NSButton(title: "Grant Accessibility…",
                                            target: nil, action: nil)
    private var grantBox: NSStackView?
    // Hidden with the CTA. Collapsing only the box leaves its separator behind as
    // a stray rule across the top of the window.
    private var grantSeparator: NSBox?
    private var content: NSStackView?
    private var permissionTimer: Timer?
    private var wasTrusted = false

    func show() {
        let window = self.window ?? build()
        self.window = window
        refresh()
        // .accessory apps are never frontmost on their own, so without this the
        // window opens behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        // Accessibility can be granted while this is open. Poll so the line stops
        // lying, and only while the window is actually up.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermission()
        }
    }

    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    var isOpen: Bool { window?.isVisible ?? false }

    // MARK: building blocks

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        if secondary {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
        }
        // Descriptions wrap rather than widening the window.
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = textWidth
        return field
    }

    // Eats the slack in a row so whatever follows it sits against the right edge.
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        // .leading, deliberately. NSStackView's .width alignment does not stretch a
        // child that is narrower than the stack — it aligns it to the trailing
        // edge, which right-aligned every single-line description. Rows that need
        // the whole width (a trailing version or button, a separator) get an
        // explicit width constraint via fullWidth() instead.
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    // Pin a row to the text column so its trailing item lands on the right edge.
    private func fullWidth(_ view: NSView) -> NSView {
        view.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return view
    }

    private func checkbox(_ button: NSButton, _ action: Selector) -> NSButton {
        button.target = self
        button.action = action
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func build() -> NSWindow {
        // Group 1: the app itself. The version rides on the first row's right edge
        // rather than taking a footer of its own.
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin(_:))
        let version = label("v\(noswooshVersion)", secondary: true)
        let general = vstack([
            fullWidth(hstack([loginCheckbox, spacer(), version])),
            checkbox(hideIconCheckbox, #selector(toggleHideIcon(_:))),
            label("When the menu bar icon is hidden, relaunch noswoosh from Finder to open settings.",
                  secondary: true),
        ], spacing: 6)

        // Group 2: the two ways to actually switch a space.
        let inputs = vstack([
            checkbox(hotkeyCheckbox, #selector(toggleHotkey(_:))),
            label("Off returns the shortcut to macOS, animation and all.", secondary: true),
            checkbox(swipeCheckbox, #selector(toggleSwipe(_:))),
        ], spacing: 6)

        // The call to action, first in the window and hidden once we are trusted.
        // Everything below it is switched off meanwhile, because none of it can
        // take effect without the permission — a live-looking checkbox that
        // silently does nothing is worse than a disabled one.
        grantTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        grantDetail.stringValue = """
            noswoosh can't switch spaces until you allow it under Privacy & \
            Security › Accessibility. It picks the permission up on its own once \
            you do — no restart needed.
            """
        grantDetail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        grantDetail.textColor = .secondaryLabelColor
        grantDetail.lineBreakMode = .byWordWrapping
        grantDetail.maximumNumberOfLines = 0
        grantDetail.preferredMaxLayoutWidth = textWidth
        grantButton.target = self
        grantButton.action = #selector(openAccessibilityPane(_:))
        grantButton.bezelStyle = .rounded
        grantButton.keyEquivalent = "\r"          // default button styling
        let grantBox = vstack([
            grantTitle,
            grantDetail,
            grantButton,
        ], spacing: 8)
        self.grantBox = grantBox

        let grantSeparator = separator()
        self.grantSeparator = grantSeparator

        let content = vstack([
            grantBox,
            grantSeparator,
            general,
            separator(),
            inputs,
        ], spacing: 16)
        self.content = content
        content.alignment = .leading
        // .width alignment equalises the groups against each other, not against
        // the window, so a narrower group ends up centred — which indented the
        // second group 39pt past the first. Pin every group to the text column
        // instead, and each group's own .width alignment carries that down to its
        // rows so trailing items land on the same right edge.
        for group in content.arrangedSubviews {
            group.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        }
        content.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset,
                                          bottom: Self.inset, right: Self.inset)

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "noswoosh Settings"
        window.contentView = content
        window.delegate = self
        // This window is what makes the empty-desktop yank guard dangerous. The
        // guard takes activation when we land on a windowless space, and its whole
        // premise (see installYankGuard) is that we have no off-space window to
        // order in — true until Settings existed. With the window open on another
        // space, activating ordered it in there and the Dock followed us to it:
        // bug #15, reintroduced by our own UI. Measured 1/4 switches yanked with
        // the window open, 0/6 with it closed.
        //
        // .canJoinAllSpaces, not .moveToActiveSpace. Moving races the follow rule
        // (still 2/8) and drags the window onto whatever desktop you land on,
        // which also makes that desktop non-empty. Joining every space means the
        // window is already on the space we land on, so ordering it in never
        // crosses a space boundary and the rule has nothing to chase.
        //
        // The other half of this is in spaceHasWindows, which must ignore our own
        // windows — otherwise a window on every space makes every space look
        // occupied and the guard stops firing at all.
        window.collectionBehavior.insert(.canJoinAllSpaces)
        // Float above ordinary windows while open. This is a menu bar app: you
        // reached this window from the status item, usually on top of whatever you
        // were working in, and having it fall behind that app is how you lose it.
        // Note the side effect on the yank guard — a floating window is no longer
        // layer 0, so spaceHasWindows would stop seeing it even without the
        // pid check there. The pid check stays anyway: it is what keeps this
        // correct if the level ever goes back to .normal.
        window.level = .floating
        // No resize control, so settle the constraints and take the height once.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        window.isReleasedWhenClosed = false   // this instance is reused
        return window
    }

    // MARK: state

    private func refresh() {
        loginCheckbox.state = loginItemIsEnabled() ? .on : .off
        hideIconCheckbox.state = menuBarIconHidden ? .on : .off
        hotkeyCheckbox.state = hotkeyEnabled ? .on : .off
        swipeCheckbox.state = swipeEnabled ? .on : .off
        refreshPermission()
    }

    private func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        for control in [loginCheckbox, hideIconCheckbox, hotkeyCheckbox, swipeCheckbox] {
            control.isEnabled = trusted
        }
        // A bare binary has no bundle identity to register, so this row would be a
        // checkbox that cannot do anything even once we are trusted.
        if trusted { loginCheckbox.isEnabled = appBundleURL != nil }

        grantBox?.isHidden = trusted
        grantSeparator?.isHidden = trusted
        // A hidden arranged subview collapses out of the stack, so the window has
        // to be resized to match or it keeps the taller frame.
        if trusted != wasTrusted, let content, let window {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
        wasTrusted = trusted
    }

    @objc private func toggleHotkey(_ sender: NSButton) { setHotkeyEnabled(sender.state == .on) }
    @objc private func toggleSwipe(_ sender: NSButton) { setSwipeEnabled(sender.state == .on) }
    @objc private func toggleHideIcon(_ sender: NSButton) { setMenuBarIconHidden(sender.state == .on) }

    @objc private func toggleLogin(_ sender: NSButton) {
        setLoginItemEnabled(sender.state == .on)
        // SMAppService can land on "requires approval" rather than the state we
        // asked for, so show what actually happened, not what was clicked.
        sender.state = loginItemIsEnabled() ? .on : .off
    }

    @objc private func openAccessibilityPane(_ sender: Any?) {
        openAccessibilitySettings()
    }
}

let settingsWindow = SettingsWindow()
