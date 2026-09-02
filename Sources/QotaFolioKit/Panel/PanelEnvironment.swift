import SwiftUI
import QotaFolioCore

/// A view being rendered is a view the user can see. Only a host that keeps rendering while its
/// window is off screen has to say otherwise, and there is exactly one of those — see below.
private struct SurfaceOnScreenKey: EnvironmentKey {
    static let defaultValue = true
}

private struct OpenQotaFolioSettingsKey: EnvironmentKey {
    static let defaultValue: OpenSettings = {}
}

/// A build with no Settings window has one surface, and that surface presents every flow.
private struct SettingsIsPresentingAddFlowKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NamesHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Whether account names are off the panel — the screen is shared, or the person asked.
    /// A card then calls its account by the provider (`presentedAccountName`).
    var namesHidden: Bool {
        get { self[NamesHiddenKey.self] }
        set { self[NamesHiddenKey.self] = newValue }
    }

    /// Whether the surface rendering this view is on screen.
    ///
    /// Read this to decide whether a per-second re-render is worth running. It is not the same
    /// question as "is the panel open", and the difference is not academic: the add-account flow
    /// has TWO surfaces, and a countdown keyed on the panel freezes on the other one.
    ///
    /// The default is `true` because a rendered view is normally a seen view. SwiftUI does **not**
    /// suspend a periodic `TimelineView` when its window leaves the screen — measured, at full
    /// rate, for an ordered-out `NSPanel` and for a sheet whose parent window was ordered out.
    /// So a host that outlives its window
    /// has to answer for itself, and `PanelRoot` is the only one that does. Defaulting to `false`
    /// instead would arm every future surface to arrive frozen.
    var surfaceIsOnScreen: Bool {
        get { self[SurfaceOnScreenKey.self] }
        set { self[SurfaceOnScreenKey.self] = newValue }
    }

    var openQotaFolioSettings: OpenSettings {
        get { self[OpenQotaFolioSettingsKey.self] }
        set { self[OpenQotaFolioSettingsKey.self] = newValue }
    }

    /// Whether the Settings window has the add-account flow on screen.
    ///
    /// The panel's subtree reads this to know whether the flow is its to draw. It is not the same
    /// question as `surfaceIsOnScreen`: that one asks whether a rendering is being looked at, and
    /// this one asks whose rendering it is. See `panelPresentsAddFlow`.
    var settingsIsPresentingAddFlow: Bool {
        get { self[SettingsIsPresentingAddFlowKey.self] }
        set { self[SettingsIsPresentingAddFlowKey.self] = newValue }
    }
}

public struct PanelRoot<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    private let catalog: any AccountCataloging
    private let store: any AccountsStoring
    private let addFlow: any AddFlowPresenting
    private let accountPrompt: AccountPromptState
    private let openSettingsAction: OpenSettings
    private let requestContentResize: @MainActor () -> Void
    /// The content's height as laid out: where any animation is heading, known the moment the
    /// layout changes.
    private let contentTargetHeightDidChange: @MainActor (CGFloat) -> Void
    /// The flow's other surface, looked up on every render rather than captured once.
    ///
    /// A closure, because this root is a struct built before the composition root has a Settings
    /// window to hand it, and because the answer has to be read inside `body` for SwiftUI to
    /// observe it. The default is the honest answer for a build with no Settings window.
    private let settingsAddFlowSurface: @MainActor () -> (any SettingsAddFlowPresenting)?
    private let content: @MainActor (
        any AccountCataloging,
        any AccountsStoring,
        any AddFlowPresenting
    ) -> Content

    public init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        addFlow: any AddFlowPresenting,
        accountPrompt: AccountPromptState,
        openSettings: @escaping OpenSettings,
        requestContentResize: @escaping @MainActor () -> Void,
        contentTargetHeightDidChange: @escaping @MainActor (CGFloat) -> Void = { _ in },
        settingsAddFlowSurface: @escaping @MainActor () -> (any SettingsAddFlowPresenting)? = { nil },
        @ViewBuilder content: @escaping @MainActor (
            any AccountCataloging,
            any AccountsStoring,
            any AddFlowPresenting
        ) -> Content
    ) {
        self.catalog = catalog
        self.store = store
        self.addFlow = addFlow
        self.accountPrompt = accountPrompt
        self.openSettingsAction = openSettings
        self.requestContentResize = requestContentResize
        self.contentTargetHeightDidChange = contentTargetHeightDidChange
        self.settingsAddFlowSurface = settingsAddFlowSurface
        self.content = content
    }

    public var body: some View {
        // One slab of Liquid Glass is the panel, and the cards are plates lying on it. No
        // second material anywhere inside it: a material in here takes its own blurred copy of
        // the desktop without seeing this glass, and the wallpaper then shows through twice.
        // Reduce Transparency makes the glass opaque by itself and Increase Contrast borders
        // it, so the root draws no fallback of its own; the plates answer for themselves.
        content(catalog, store, addFlow)
            .frame(width: PanelLayout.width)
            // The content takes its own height and reports it — once, at the target, the moment
            // the layout changes, because SwiftUI interpolates what it renders and not what it
            // lays out. The window does not follow: it is the room the panel was given and it
            // stands still while the glass travels inside it. What the report is for is where
            // the glass is on screen, which is what a picture of this panel is framed on.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentTargetHeightDidChange(height)
            }
            // The panel is the surface that outlives its window: this hosting controller is
            // built once and never torn down, so its subtree keeps rendering after `orderOut`.
            // That is why the panel has to answer, and the store's own visibility flag is the
            // answer.
            .environment(\.surfaceIsOnScreen, store.isPanelVisible)
            // Read here, inside `body`, so the panel re-renders when Settings takes the flow or
            // gives it back. Both surfaces stay live and only one of them draws the flow.
            .environment(\.settingsIsPresentingAddFlow, settingsIsPresentingAddFlow)
            .environment(\.openQotaFolioSettings, openSettingsAction)
            // The card list measures its own height and asks through this when it changes.
            .environment(\.requestPanelResize, requestContentResize)
            // The panel's own prompt, handed to the whole subtree from the object that owns the
            // panel's lifetime. Nothing below has to carry it, and nothing below outlives it.
            .environment(accountPrompt)
            .onChange(of: structure) { _, _ in
                requestContentResize()
            }
            // Everything the panel draws is cut to the slab's outline, so a card scrolled to
            // the top edge is cut by the glass's curve rather than poking a square corner out
            // past it. The clip is on the content, not on the window's layer: the material
            // needs to reach past the shape it draws, and a mask on the layer takes that away.
            .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
            // The slab, tinted to the panel's own neutral. Untinted, Regular glass passes far
            // more of the desktop than the glass Apple's own panels are cut from, so a
            // wallpaper's colour arrives inside the panel and the numbers sit on a picture
            // instead of a surface. A neutral tint is the public control for that: it keeps
            // every adaptive behaviour of the material, and spends them on a surface.
            .glassEffect(.regular.tint(PanelSlab.tint(scheme)), in: .rect(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
            // No shadow is drawn here. The material carries one — glass in a panel is given the
            // window server's shadow for a window of this kind at twice the blur — and it is the
            // shadow Apple adapts: it deepens over text, lightens over a light background, and
            // answers Reduce Transparency and Increase Contrast without being asked. A second
            // one drawn on top of it nearly doubled the density at the slab's edge.
            //
            // The room the material's shadow falls into. The slab keeps its own width; the
            // window is wider by this on each side, so the slab lands where it always did. The
            // room below the slab is whatever the window has left, which is never less than
            // `shadowRoom.bottom` — see `layoutPanel`.
            .padding(.horizontal, PanelLayout.shadowRoom.side)
            .padding(.top, PanelLayout.shadowRoom.top)
            // Pinned to the top of the window, which is taller than the glass whenever the
            // fleet does not fill the panel: the slab sits where it belongs, under the status
            // item, and clear air is below it. The unbounded maximum is load-bearing for that:
            // an `NSHostingController` publishes its content's maximum size as the window's
            // `contentMaxSize`, and a finite one here would clamp the window back down to the
            // content on the next layout pass, which would put the window back on the same
            // clock as the motion.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("QotaFolio")
            .accessibilityIdentifier(AXIdentifiers.panel)
#if DEBUG
            .modifier(DebugAccommodationOverrides())
#endif
    }

    /// Whether the Settings window has the flow, asked fresh on every render.
    private var settingsIsPresentingAddFlow: Bool {
        settingsAddFlowSurface()?.settingsIsPresentingAddFlow ?? false
    }

    /// The value the open panel re-measures itself on.
    private var structure: PanelStructure {
        PanelStructure(
            loadState: catalog.loadState,
            accountIDs: catalog.accounts.map(\.id),
            hasAdvisory: catalog.recoveryAdvisory != nil,
            // The step the panel is drawing, which is `.none` while the Settings sheet has the
            // flow. Measured from the flow itself, the panel would size itself for an add step
            // that is on screen in another window.
            flowStep: PanelFlowStep(
                panelPresentsAddFlow(
                    addFlow.activeFlow,
                    settingsIsPresentingAddFlow: settingsIsPresentingAddFlow
                ) ? addFlow.activeFlow : nil
            ),
            promptStep: accountPrompt.step
        )
    }
}
