import AppKit
import Observation
import SwiftUI
import QotaFolioCore

/// Forwards the panel's AppKit window callbacks to its controller.
///
/// `MenuBarPanelController` is generic, and a generic Swift class cannot expose `@objc` members, so
/// the window delegate has to be this small non-generic object. It owns no resource: the controller
/// holds it, `NSWindow.delegate` is weak, and the callback captures the controller weakly.
@MainActor final class PanelWindowObserver: NSObject, NSWindowDelegate {
    var onPanelWindowChanged: (() -> Void)?

    func windowDidResignKey(_ notification: Notification) {
        onPanelWindowChanged?()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        onPanelWindowChanged?()
    }
}

/// Watches the add flow's phase on the controller's behalf.
///
/// `MenuBarPanelController` is generic, and `withObservationTracking`'s change handler is
/// `@Sendable`, so a capture of the controller drags `Content.Type` across an isolation boundary
/// and does not compile. This small non-generic object does the watching and hands the edge back —
/// the same shape as `PanelWindowObserver` above, for the same kind of reason. Re-arming after
/// every change is how `StatusItemController` observes the catalog: a registration fires once.
@MainActor final class PanelFlowObserver {
    private let addFlow: any AddFlowPresenting
    var onFlowPhaseChanged: (() -> Void)?

    init(addFlow: any AddFlowPresenting) {
        self.addFlow = addFlow
    }

    func arm() {
        withObservationTracking {
            _ = addFlow.activeFlow
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onFlowPhaseChanged?()
                self.arm()
            }
        }
    }
}

/// Which surface is holding the add flow, as the panel has to decide it.
///
/// **Three answers, and the third is the one a Bool cannot give.** "Is this panel holding the
/// flow?" and "is the other surface holding it?" are not each other's negation. A phase that no
/// surface draws is a real third state — `.connected` and a cancelled flow both read that way —
/// and answering the second question with the first question's `false` is how a panel hands a
/// flow to a surface that has nothing to show, on the very success it exists to announce.
///
/// The order of the two facts is the point. Renderability is asked first, of the phase, which is
/// the panel's own knowledge. Whether the Settings window has the flow is the other surface's
/// report about itself, and it decides only which of two surfaces holds a flow that exists at all.
/// A surface claiming a flow that draws nothing cannot take the panel off screen.
nonisolated enum AddFlowSurface: Equatable, Sendable {
    /// This panel is drawing the flow, and it is what a browser sends the user back to.
    case thisPanel
    /// The Settings sheet is drawing it, so a handover has somewhere to arrive.
    case otherSurface
    /// Nobody is drawing it. There is nothing to hand over and nothing to come back to.
    case noSurface
}

/// The rule `panelPresentsAddFlow` and `settingsPresentsAddFlow` each state from one side, said
/// once with all three of its answers.
///
/// `PanelSurfaceTests` pins `.thisPanel` against `panelPresentsAddFlow` over every phase and both
/// readings of the Settings window, so the two cannot drift apart.
nonisolated func surfaceHoldingAddFlow(
    _ flow: AccountFlowPhase?,
    settingsIsPresentingAddFlow: Bool
) -> AddFlowSurface {
    guard renderableFlow(flow) != nil else { return .noSurface }
    return settingsIsPresentingAddFlow ? .otherSurface : .thisPanel
}

@MainActor public final class MenuBarPanelController<Content: View>: PanelToggling {
    private let catalog: any AccountCataloging
    private let store: any AccountsStoring
    private let addFlow: any AddFlowPresenting
    private let onPanelShown: @MainActor () -> Void
    private let openSettingsAction: OpenSettings
    private let contentFactory: @MainActor (
        any AccountCataloging,
        any AccountsStoring,
        any AddFlowPresenting
    ) -> Content

    private let panel = MenuBarPanel()
    let monitor = PanelDismissalMonitor()
    private let panelObserver = PanelWindowObserver()
    private weak var anchorButton: NSStatusBarButton?

    /// The flow's other surface. Weak: the composition root owns both objects, and the Settings
    /// presenter already holds this controller weakly from its side.
    public weak var settingsAddFlowSurface: (any SettingsAddFlowPresenting)?

    /// The status button the panel was last shown from, kept after the panel leaves the screen.
    ///
    /// `anchorButton` is the button of the visit in progress and is released with the rest of the
    /// panel's residue. This one is how the controller finds its way back on screen when a browser
    /// hands an authorization back to a panel the user had closed in the meantime.
    private weak var lastAnchorButton: NSStatusBarButton?
    private var resizeQueued = false

    /// Where the panel's appearance comes from, asked afresh every time the panel is shown.
    ///
    /// The default is the Mac's own, which is what Control Center's panels wear — not the menu
    /// bar's ink polarity, which follows the wallpaper and can be dark over a light desktop. The
    /// composition root points this at the person's choice in Settings; the fixture runtime points
    /// it at whichever form is being photographed, without changing the Mac's appearance.
    ///
    /// A closure and not a value, because the choice can be made while the panel is away: opening
    /// Settings is a click outside the panel, which puts the panel away, so a panel on screen and
    /// a picker being turned cannot happen at once. Reading it at every showing is therefore the
    /// whole of "live" — and `System` is live in the truest sense, because it leaves the window's
    /// appearance nil and macOS moves it at sunset without anybody being told.
    public var appearanceSource: @MainActor () -> NSAppearance? = { nil }

    /// Whether presenting makes the panel the key window. On, as the product wants: a panel the
    /// person opened takes their typing — arrows walk the cards, Return opens one, Escape
    /// closes. A lab that only photographs the panel turns it off, so a stranger's keystroke
    /// on this Mac never lands in a panel nobody asked for.
    public var takesKeyboardFocus = true

    /// The question the panel is asking, for as long as the panel is on screen. See
    /// `AccountPromptState`.
    let accountPrompt = AccountPromptState()

    /// The flow phase this controller last saw, so it can tell one transition from another.
    private var lastObservedFlowPhase: AccountFlowPhase?
    private let flowObserver: PanelFlowObserver

    private lazy var hostingController: NSHostingController<PanelRoot<Content>> = {
        let root = PanelRoot(
            catalog: catalog,
            store: store,
            addFlow: addFlow,
            accountPrompt: accountPrompt,
            openSettings: openSettingsAction,
            requestContentResize: { [weak self] in
                self?.requestContentResize()
            },
            contentTargetHeightDidChange: { [weak self] height in
                self?.contentTargetHeightDidChange(height)
            },
            settingsAddFlowSurface: { [weak self] in
                self?.settingsAddFlowSurface
            },
            content: contentFactory
        )
        return NSHostingController(rootView: root)
    }()

    public init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        addFlow: any AddFlowPresenting,
        onPanelShown: @escaping @MainActor () -> Void,
        openSettings: @escaping OpenSettings,
        @ViewBuilder content: @escaping @MainActor (
            any AccountCataloging,
            any AccountsStoring,
            any AddFlowPresenting
        ) -> Content
    ) {
        self.catalog = catalog
        self.store = store
        self.addFlow = addFlow
        self.onPanelShown = onPanelShown
        self.openSettingsAction = openSettings
        self.contentFactory = content
        self.flowObserver = PanelFlowObserver(addFlow: addFlow)
        // `NSWindow.delegate` is a weak reference and the observer is owned here, so this
        // observation owns no resource and needs no teardown. It is how the controller learns that
        // AppKit removed the panel without routing through `hide`.
        panelObserver.onPanelWindowChanged = { [weak self] in
            self?.disarmDismissalMonitorIfPanelLeftScreen()
        }
        panel.delegate = panelObserver

        // Escape's innermost claimant. The composition root installs the outer one — the live add
        // flow — on the same monitor, and the monitor tries this one first, so the question
        // nearest the user is the one Escape answers. It declines while THIS PANEL renders a
        // flow, because a flow outranks a prompt in the panel's body and Escape must answer what
        // is on screen. A flow the Settings sheet has is not on this screen, so the prompt below
        // it is what Escape answers.
        monitor.panelEscapeClaimant = { [weak self] in
            guard let self,
                  !self.panelPresentsTheAddFlow,
                  self.accountPrompt.prompt != nil
            else { return false }
            self.accountPrompt.clear()
            return true
        }

        // And the outer claimant may only speak for a flow this panel is showing. It cancels or
        // acknowledges `addFlow` directly, so without this an Escape pressed on a panel full of
        // quota numbers would reach into the Settings sheet the user was not even looking at.
        monitor.addFlowIsOnThePanel = { [weak self] in
            self?.panelPresentsTheAddFlow ?? false
        }

        lastObservedFlowPhase = addFlow.activeFlow
        flowObserver.onFlowPhaseChanged = { [weak self] in
            self?.flowPhaseDidChange()
        }
        flowObserver.arm()
    }

    public var isPanelShown: Bool {
        panel.isVisible
    }

    /// Which surface is holding the add flow right now.
    ///
    /// One reading of one rule, for every decision this controller makes about the flow. The panel
    /// asks it two ways — "am I the one drawing this?" below, and "who is?" on the two paths that
    /// move the flow between surfaces — and both are this one value.
    var addFlowSurface: AddFlowSurface {
        surfaceHoldingAddFlow(
            addFlow.activeFlow,
            settingsIsPresentingAddFlow: settingsAddFlowSurface?.settingsIsPresentingAddFlow ?? false
        )
    }

    /// Whether the add-account flow is on the panel rather than in the Settings sheet.
    ///
    /// One surface presents the flow at a time and the sheet wins; see `panelPresentsAddFlow`.
    /// Everything the panel does about the flow — refusing a browser click, letting Escape reach
    /// it, retiring a failure the user dismissed — is about the flow **this** surface is showing.
    ///
    /// Read positively at every call site, and that is why a Bool is enough here: it is asked to
    /// admit an action about a flow the panel is drawing, never to conclude anything from its own
    /// `false`. What its `false` does not say is who else has it, or whether anyone does.
    var panelPresentsTheAddFlow: Bool {
        addFlowSurface == .thisPanel
    }

    /// The panel window this controller owns.
    var panelWindow: MenuBarPanel {
        panel
    }

    /// Whether the process-wide event monitors are installed right now.
    ///
    /// This is deliberately not the same question as `isPanelShown`. A `.transient` panel is taken
    /// off screen by the system — Mission Control, Expose, a space change — without any call into
    /// this controller, and conflating the two would let the monitors outlive the panel.
    private(set) var dismissalMonitorIsArmed = false

    public var dismissalMonitor: any EscapeInterceptable {
        monitor
    }

    public func togglePanel(relativeTo button: NSStatusBarButton) {
        if isPanelShown {
            hide(reason: .statusItemToggle)
        } else {
            show(relativeTo: button)
        }
    }

    public func show(relativeTo button: NSStatusBarButton) {
        present(from: button, anchoredToTheButton: true)
    }

    public func showUnanchored(from button: NSStatusBarButton) {
        present(from: button, anchoredToTheButton: false)
    }

    private func present(from button: NSStatusBarButton, anchoredToTheButton: Bool) {
        guard !isPanelShown else { return }

        anchorButton = button
        lastAnchorButton = button
        panel.appearance = appearanceSource()
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .none
            : .utilityWindow
        store.setPanelVisible(true)
        onPanelShown()

        if panel.contentViewController == nil {
            // Nothing here masks the content. A mask on this layer changes no pixel of the
            // glass's own shadow — measured, on the same desktop, masked against unmasked —
            // and it costs the material the bleed its own edge needs. The cut of the panel's
            // contents to the slab's outline is done in `PanelRoot`, where the outline is.
            panel.contentViewController = hostingController
        }

        layoutPanel(relativeTo: anchoredToTheButton ? button : nil)
        armDismissalMonitor(statusButton: button)
        button.highlight(true)
        if takesKeyboardFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    public func hide(reason: PanelDismissReason) {
        // The reason is read, and exactly one reason is refused.
        //
        // `.outsideApplicationClick` is the global mouse monitor firing because the user clicked
        // in another application. While this panel is showing an account flow that other
        // application is a browser this app opened, on a page this app sent the user to, and the
        // click is part of the transaction rather than a dismissal of it. The panel is then the
        // surface that flow has: it is where a ChatGPT device code is displayed and where an
        // Anthropic sign-in reports its progress, and the app has no Dock icon, no window and no
        // Cmd-Tab entry to return to once it is gone. Every other reason dismisses — including a
        // click on this app's own Settings window, which is a deliberate move elsewhere.
        //
        // A flow the Settings sheet is showing does not hold the panel open. That sheet is the
        // surface the browser sends the user back to, and this panel is in front of quota numbers.
        if reason == .outsideApplicationClick, panelPresentsTheAddFlow {
            return
        }

        // Answered before the panel goes, because the question is about the surface the user was
        // looking at when they made this gesture. Both halves matter: the gesture has to be the
        // user putting the panel away, and the failure has to be one this panel was showing. A
        // rate-limit countdown the user is reading in Settings is not retired by a glance at the
        // menu bar.
        let userDismissedAFailure = panelDismissalAcknowledgesFailure(reason)
            && panelPresentsTheAddFlow
            && isTerminalFailure(addFlow.activeFlow)

        // Disarming is unconditional. The monitors belong to this controller, not to the panel, so
        // releasing them must not depend on the panel still being on screen. A `.transient` panel
        // the system already removed would otherwise leave a global mouse monitor and an app-wide
        // Escape interceptor running behind it.
        releasePanelResidue()

        if isPanelShown {
            panel.orderOut(nil)
        }

        // Last, so the flow is cleared behind a panel that has already left the screen rather than
        // in front of a user watching the failure step blink out into an account list.
        if userDismissedAFailure {
            addFlow.acknowledgeFailure()
        }
    }

    private nonisolated func isTerminalFailure(_ phase: AccountFlowPhase?) -> Bool {
        if case .some(.failed) = phase { return true }
        return false
    }

    /// The moment a browser hands the transaction back, as the panel sees it.
    ///
    /// Two moments, and the second is the same fact seen earlier. A flow that has just become
    /// renderable on the OTHER surface is a flow this panel has handed over, and the panel goes
    /// with it. Without that, pressing Add Account in the panel while Settings is open leaves the
    /// panel sitting there answering with the account list the user already had, while the naming
    /// step they asked for is in a window behind it.
    func flowPhaseDidChange() {
        let previous = lastObservedFlowPhase
        let current = addFlow.activeFlow
        lastObservedFlowPhase = current

        // A flow that has just become renderable, on a surface that is not this one. Both facts
        // are in `addFlowSurface`, which reads the phase this line already put in `current`.
        if renderableFlow(previous) == nil, addFlowSurface == .otherSurface {
            handTheFlowToItsSurface()
            return
        }

        guard Self.isBrowserHandback(from: previous, to: current) else { return }
        presentAfterBrowserHandback()
    }

    /// Gives the flow to the surface that has it, and leaves the screen doing it.
    ///
    /// **The panel hides itself as it hands over.** A user who presses Add Account here while
    /// Settings is open pressed a button on one surface and meets their naming step on another,
    /// and the panel leaving is what marks the handover. It needs no word on the button and no
    /// caption underneath it, because it is a movement this app already performs and the user has
    /// already been taught: Settings hides the panel whenever it opens, and a flow that starts
    /// here and lands there is that same movement seen from the other end.
    ///
    /// The reason is `.supersededBySettings`, which is the reason `SettingsWindowPresenter` gives
    /// for the very same movement. It says the app is moving the flow rather than ending it, and
    /// that is exactly what is happening: nothing the panel was showing has been answered, and the
    /// phase the user started is waiting for them on the sheet. On this path the six reasons would
    /// in fact all behave alike — `hide` retires a failure only when the panel is the surface
    /// showing it, and by definition it is not showing this one — so the reason is chosen for what
    /// it says rather than for what it does, and this is the only thing it could honestly say.
    ///
    /// Hiding first and bringing the other surface forward second is `present()`'s own order, so a
    /// handover looks the same whichever side starts it. `present()` asks for the same dismissal
    /// again on its way past; a panel already off screen answers it by doing nothing.
    private func handTheFlowToItsSurface() {
        hide(reason: .supersededBySettings)
        settingsAddFlowSurface?.bringAddFlowSurfaceForward()
    }

    /// True when a flow that was waiting on a browser is not waiting any more.
    ///
    /// Both providers pass through here. Anthropic's loopback listener receives the callback and
    /// the flow leaves `.anthropicWaitingInBrowser`; ChatGPT's device poll succeeds and the flow
    /// leaves `.openAIAwaitingDevice`. A denial counts too — the listener answers the browser with
    /// "Authorization was denied. You can return to QotaFolio", and a promise of a return is a
    /// promise whether the answer was yes or no.
    ///
    /// A flow the user cancelled does not count. Cancelling is done from the panel, so the panel
    /// is already in front of them, and `.cancelled` on the storing path is the same event
    /// arriving by a different road.
    ///
    /// This answers **when**, and only when. `.connected` is a hand-back like any other — the
    /// browser did return the transaction, and it returned a completed one. Where the user is put
    /// afterwards is `addFlowSurface`'s question, and the two are not interchangeable: every
    /// renderable phase here has a surface holding it and `.connected` has none.
    nonisolated static func isBrowserHandback(
        from previous: AccountFlowPhase?,
        to current: AccountFlowPhase?
    ) -> Bool {
        switch previous {
        case .anthropicWaitingInBrowser?, .openAIAwaitingDevice?:
            break
        default:
            return false
        }

        switch current {
        case .exchanging?, .storing?, .connected?:
            return true
        case .failed(let failure)?:
            return failure != .cancelled
        default:
            return false
        }
    }

    /// Gives the user back the surface the browser told them to return to.
    ///
    /// This is the one place in the panel that activates the application, and it is the only place
    /// that should. Activating on an ordinary open would take focus away from whatever the user
    /// was typing in every time they glanced at their quota — a worse defect than the one this
    /// repairs. Here the user has just finished a page this app opened, that page has just told
    /// them to come back, and there is nothing else to come back to: the app is an accessory with
    /// no Dock icon, and behind a full-screen browser even the menu-bar glyph is off screen.
    ///
    /// Which surface they are given back is decided by which surface has the flow, and that is a
    /// question with three answers rather than two. `isBrowserHandback` above says the moment has
    /// come; `addFlowSurface` says where to send them, or that there is nowhere to send them.
    private func presentAfterBrowserHandback() {
        switch addFlowSurface {
        case .otherSurface:
            // The user is being returned to the sign-in, and the sign-in is in the Settings sheet
            // rather than here. Showing this panel would put quota numbers in front of the result
            // the provider's page just promised them, with the result itself behind it — and a
            // panel they reopened during the browser trip is already doing that, so it goes.
            handTheFlowToItsSurface()

        case .noSurface:
            // The browser handed back a transaction that is already over. `.connected` arrives
            // this way: the hand-back is real, and what it handed back is a finished add that no
            // surface draws, because the new row and the announcement are the success signal.
            // There is nowhere to send the user and nothing to bring forward, so the screen is
            // left exactly as it is — a panel that is open stays open, on the success it exists
            // to announce. Hiding it here and calling for a surface with nothing on it would take
            // the app off screen at the best moment it has.
            break

        case .thisPanel:
            if !isPanelShown, let button = lastAnchorButton {
                show(relativeTo: button)
            }
            guard isPanelShown else { return }
            NSApplication.shared.activate()
            // Ordering front is what moves a `.moveToActiveSpace` panel onto the space the browser
            // was full-screen on.
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func armDismissalMonitor(statusButton: NSStatusBarButton) {
        monitor.start(panel: panel, statusButton: statusButton) { [weak self] reason in
            self?.hide(reason: reason)
        }
        dismissalMonitorIsArmed = true
    }

    private func disarmDismissalMonitor() {
        monitor.stop()
        dismissalMonitorIsArmed = false
    }

    /// Releases the monitors if the panel has left the screen.
    ///
    /// AppKit calls this controller's window-delegate methods when the panel resigns key or changes
    /// occlusion state, which is what happens when the system removes a `.transient` window. The
    /// check runs on the next main-actor turn because the panel's visibility is settled by then.
    private func disarmDismissalMonitorIfPanelLeftScreen() {
        guard dismissalMonitorIsArmed else { return }
        Task { @MainActor [weak self] in
            guard let self, self.dismissalMonitorIsArmed, !self.isPanelShown else { return }
            self.releasePanelResidue()
        }
    }

    /// Releases everything the controller holds on the panel's behalf once the panel is off screen.
    /// Shared by `hide` and by the AppKit path where the system removed the panel for us.
    private func releasePanelResidue() {
        disarmDismissalMonitor()
        // The prompt lasts exactly as long as the user's ability to answer it. The hosting
        // controller is built once and never torn down, so a prompt left here would be waiting on
        // the next visit — a destructive question nobody asked, about whichever account still
        // matched.
        accountPrompt.clear()
        store.setPanelVisible(false)
        anchorButton?.highlight(false)
        anchorButton?.window?.makeFirstResponder(anchorButton)
        anchorButton = nil
    }

    /// The content's height as laid out, recorded so the lab can frame the glass rather than the
    /// room around it. The window does not follow it — see `layoutPanel` — and neither does the
    /// shadow, which is the material's own and travels with the glass. Nothing has to be told.
    public func contentTargetHeightDidChange(_ height: CGFloat) {
        guard height.isFinite, height > 0, height != targetContentHeight else { return }
        targetContentHeight = height
    }

    private var targetContentHeight: CGFloat?

    /// Where the glass is drawn inside the window, on screen.
    ///
    /// Not the window's frame, which is the room the panel was given: it stands still at the full
    /// height the panel is allowed while the glass travels inside it, and it carries the shadow's
    /// room on every side. Anything photographing this panel wants the slab, because the slab is
    /// all there is to see — a picture framed on the window carries a strip of bare desktop under
    /// it and the shadow's room of it either side.
    ///
    /// Measured where it can be and read from the layout where it cannot: the height is what the
    /// content reported, the width is the width the slab is given, and the slab is centred in the
    /// window and hangs the shadow's top room below its top edge. Those are the same three numbers
    /// `PanelRoot` draws with, not a second account of them.
    public var glassFrame: NSRect? {
        guard let height = targetContentHeight else { return nil }
        let frame = panel.frame
        return NSRect(
            x: frame.midX - PanelLayout.width / 2,
            y: frame.maxY - PanelLayout.shadowRoom.top - height,
            width: PanelLayout.width,
            height: height
        )
    }

    /// The content saying it has changed height. Nothing follows it: the window is the room the
    /// panel was given and stands still, and the shadow is the material's own and travels with
    /// the glass. The seam stays because it is the path a card's growth takes, and the
    /// guarantee worth pinning is that the window ignores it.
    public func requestContentResize() {
        guard !resizeQueued else { return }
        resizeQueued = true

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.resizeQueued = false
        }
    }

    /// Puts the window where the panel goes, at the full height the panel is allowed.
    ///
    /// The window is the stage, not the actor. It is clear, so its size is not something anybody
    /// can see; what a person sees is the glass, top-pinned inside it, and the glass is SwiftUI's
    /// to move. Sizing the window to the content instead — following it up and down as cards open
    /// and close — puts a second clock on the same motion: `setFrame` re-lays out the hosting view
    /// there and then, outside the animation, and the measured result was an opening panel that
    /// jumped a quarter of its travel in one frame and then glided the rest, while a closing one
    /// glided the whole way. Same curve, two different motions. So the window is set once, when
    /// the panel is shown, and stands still while the glass does the moving.
    private func layoutPanel(relativeTo button: NSStatusBarButton?) {
        let screen = button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame

        let buttonRect: NSRect
        if let button, let window = button.window {
            buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        } else {
            buttonRect = NSRect(x: visibleFrame.midX, y: visibleFrame.maxY, width: 1, height: 1)
        }

        // Every number here is the slab's. The slab is all anyone can see, and it is what has to
        // stay on the screen; the room the window carries around it for the glass's own shadow is
        // clear, and hangs off the screen's edge quite happily.
        //
        // The slab takes everything between the status item and the bottom of the screen, up to
        // the panel's own ceiling. Taking exactly the room that is there is what keeps the top
        // edge under the item on a short screen: a taller slab would be pushed up by the clamp
        // below and would ride up behind the menu bar.
        let shadow = PanelLayout.shadowRoom
        let slabTop = buttonRect.minY - PanelLayout.anchorGap
        let slabRoom = slabTop - (visibleFrame.minY + 8)
        let slabHeight = max(160, min(PanelLayout.preferredMaxHeight, slabRoom))
        let size = NSSize(width: PanelLayout.windowWidth, height: slabHeight + shadow.top + shadow.bottom)

        // The slab sits `anchorGap` under the item and centred on it, kept clear of the screen's
        // sides; the window starts the shadow's room higher and further out than that.
        let slabX = min(
            max(buttonRect.midX - PanelLayout.width / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - PanelLayout.width - 8
        )
        let origin = NSPoint(x: slabX - shadow.side, y: slabTop - slabHeight - shadow.bottom)

        let frame = NSRect(origin: origin, size: size)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }
}
