import SwiftUI

extension EnvironmentValues {
    /// Whether buttons take keyboard focus: Keyboard navigation in System
    /// Settings. `tracksKeyboardNavigation()` keeps it current for the views
    /// inside it.
    @Entry var buttonsTakeKeyboardFocus = false
}

extension View {
    /// Gives the views inside the Keyboard navigation setting. It is read again
    /// each time the app becomes active, because it changes in System Settings.
    func tracksKeyboardNavigation() -> some View { modifier(KeyboardNavigationTracking()) }

    /// Binds a button's focus only while buttons can take it. A focus binding
    /// registers its view with the window. One on every row of a list makes
    /// the window work out its focus and rebuild its toolbar menus as rows
    /// scroll in and out, which delays frames.
    func focused(_ focus: FocusState<Bool>.Binding, whileButtonsTakeFocus enabled: Bool) -> some View {
        modifier(ButtonFocusBinding(focus: focus, isEnabled: enabled))
    }

    /// The same for one of several buttons that share a focus state.
    func focused<Value: Hashable>(_ focus: FocusState<Value?>.Binding, equals value: Value,
                                  whileButtonsTakeFocus enabled: Bool) -> some View {
        modifier(ButtonValueFocusBinding(focus: focus, value: value, isEnabled: enabled))
    }
}

/// The style for a button on a row that enters and leaves a lazy stack as it
/// scrolls.
///
/// A button drawn by one of SwiftUI's styles binds a focus state of its own,
/// even while Keyboard navigation is off. A row that enters then changes the
/// window's focus store, and SwiftUI updates the main menu and every toolbar
/// item to match, which delays the frame. This style draws the label and takes
/// the click itself, so the row leaves the store alone. While Keyboard
/// navigation is on, the system style draws the button and it takes focus.
/// The row needs `tracksKeyboardNavigation()` above it.
struct RowButtonStyle: PrimitiveButtonStyle {
    /// The system style that draws the button while it can take focus.
    enum SystemStyle { case borderless, plain }

    var system = SystemStyle.borderless

    func makeBody(configuration: Configuration) -> some View {
        RowButton(configuration: configuration, system: system)
    }
}

private struct RowButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let system: RowButtonStyle.SystemStyle
    @Environment(\.buttonsTakeKeyboardFocus) private var takesFocus
    @GestureState private var isPressed = false

    var body: some View {
        if takesFocus {
            switch system {
            case .borderless: Button(configuration).buttonStyle(.borderless)
            case .plain: Button(configuration).buttonStyle(.plain)
            }
        } else {
            switch system {
            case .borderless:
                // The borderless style leaves a pressed label as it is when
                // the label sets its own foreground style, as a row's do.
                configuration.label.onTapGesture { configuration.trigger() }
            case .plain:
                configuration.label
                    .opacity(isPressed ? Tokens.Opacity.pressedLabel : 1)
                    .onTapGesture { configuration.trigger() }
                    .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, pressed, _ in pressed = true })
            }
        }
    }
}

private struct KeyboardNavigationTracking: ViewModifier {
    @State private var isOn = NSApplication.shared.isFullKeyboardAccessEnabled

    func body(content: Content) -> some View {
        content
            .environment(\.buttonsTakeKeyboardFocus, isOn)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                isOn = NSApplication.shared.isFullKeyboardAccessEnabled
            }
    }
}

private struct ButtonFocusBinding: ViewModifier {
    let focus: FocusState<Bool>.Binding
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled { content.focused(focus) } else { content }
    }
}

private struct ButtonValueFocusBinding<Value: Hashable>: ViewModifier {
    let focus: FocusState<Value?>.Binding
    let value: Value
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled { content.focused(focus, equals: value) } else { content }
    }
}

/// Hands the keyboard to a section of the workspace when it comes to front.
/// The sections stay mounted behind the one in front, where a view could keep
/// the keyboard, so arrow keys and Space would act on content that isn't on
/// screen. Views read only `isInFront`, so a switch updates the small views
/// that move focus and leaves the section alone.
@MainActor @Observable final class SectionKeyboard {
    /// What may have the keyboard for a view in the section to take it.
    enum Holder {
        /// A view in the window's content, or nothing. A text field the person
        /// can see keeps the keyboard, such as one in the utility panel beside
        /// the section, and so does the toolbar's search field, which is
        /// outside the content and searches the section in front.
        case content
        /// Nothing: the window itself has the keyboard.
        case nothing
    }

    /// The section is in front and on screen.
    private(set) var isInFront = false
    /// What the section's views take the keyboard from as it comes to front.
    @ObservationIgnored fileprivate var arrivalHolder = Holder.content
    /// Set by `SectionKeyboardAnchor` when the section joins a window.
    @ObservationIgnored fileprivate weak var window: NSWindow?
    /// The views showing that take the keyboard for the section: one, or two
    /// for a moment while one fades out and the next fades in.
    @ObservationIgnored fileprivate var shownTargets = 0

    /// `holder` is what the section's views take the keyboard from if the
    /// section comes to front.
    func update(isInFront inFront: Bool, takingFrom holder: Holder = .content) {
        guard inFront != isInFront else { return }
        arrivalHolder = holder
        isInFront = inFront
        // Nothing that takes the keyboard shows yet. A view that shows later
        // takes the keyboard if it is still free. One that shows before the
        // keyboard is cleared starts its own focus task after the clearing
        // task, so it finds the keyboard free.
        if inFront, shownTargets == 0, holder == .content { clearKeyboard() }
    }

    /// Takes the keyboard from the window's content once the update in
    /// progress is done, so keys go nowhere rather than to a section behind.
    /// A text field the person can see keeps it.
    fileprivate func clearKeyboard() {
        Task { [weak self] in
            await Task.yield()
            guard let self, canTake(from: .content) else { return }
            window?.makeFirstResponder(nil)
        }
    }

    /// Runs `focus` once the update in progress is done, if the section is
    /// still in front, a view that takes the keyboard still shows and the
    /// keyboard is with `holder` or with nothing.
    func focus(takingFrom holder: Holder, _ focus: @escaping @MainActor () -> Void) {
        Task { [weak self] in
            await Task.yield()
            guard let self, isInFront, shownTargets > 0, canTake(from: holder) else { return }
            focus()
        }
    }

    private func canTake(from holder: Holder) -> Bool {
        guard let window, let responder = window.firstResponder, responder !== window else { return true }
        guard holder == .content, let view = responder as? NSView, let content = window.contentView,
              view.isDescendant(of: content) else { return false }
        return !isVisibleTextField(view, in: content)
    }

    /// Whether `view` is a text field or text view that a click would reach.
    /// The sections behind the one in front take no clicks.
    private func isVisibleTextField(_ view: NSView, in content: NSView) -> Bool {
        guard let text = view as? NSText else { return false }
        // A text field's editor is inside the field while it edits.
        let field = (text.delegate as? NSView) ?? text
        let middle = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        guard let hit = content.hitTest(content.superview?.convert(middle, from: nil) ?? middle) else { return false }
        return hit === field || hit.isDescendant(of: field)
    }
}

/// Tells a `SectionKeyboard` which window its section is in as soon as the
/// section joins it, before a view that takes the keyboard shows.
private struct SectionKeyboardAnchor: NSViewRepresentable {
    let keyboard: SectionKeyboard

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.keyboard = keyboard
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { view.keyboard = keyboard }

    final class AnchorView: NSView {
        weak var keyboard: SectionKeyboard?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            keyboard?.window = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Tells `keyboard` which window this section is in, whether the section
    /// is in front and whether it is on screen. A section that comes to front
    /// takes the keyboard from the window's content, as `SectionKeyboard.Holder`
    /// describes. One that comes to front hidden, as under the utility panel in
    /// a narrow window, only clears it. One that is shown again while in front
    /// takes the keyboard only if nothing has it.
    func sectionKeyboard(_ keyboard: SectionKeyboard, isInFront: Bool, isShown: Bool = true) -> some View {
        background { SectionKeyboardAnchor(keyboard: keyboard) }
            .onChange(of: SectionPlacement(isInFront: isInFront, isShown: isShown), initial: true) { old, new in
                let isShownAgain = old.isInFront == new.isInFront && old.isShown != new.isShown
                keyboard.update(isInFront: new.isInFront && new.isShown, takingFrom: isShownAgain ? .nothing : .content)
                if new.isInFront, !old.isInFront, !new.isShown { keyboard.clearKeyboard() }
            }
    }

    /// Makes this view the one that takes the keyboard for its section: when
    /// the section comes to front, as `sectionKeyboard` describes, and when
    /// this view shows while nothing has the keyboard. `release` runs when the
    /// section goes behind. While `isEnabled` is false, as for a list with no
    /// rows, the view takes nothing and the section takes the keyboard from
    /// the sections behind it instead.
    func takesSectionKeyboard(_ keyboard: SectionKeyboard, isEnabled: Bool = true,
                              release: (@MainActor () -> Void)? = nil,
                              focus: @escaping @MainActor () -> Void) -> some View {
        background {
            if isEnabled { SectionKeyboardTarget(keyboard: keyboard, focus: focus, release: release) }
        }
    }
}

private struct SectionPlacement: Equatable {
    let isInFront: Bool
    let isShown: Bool
}

/// Moves the keyboard to and from a view. See `takesSectionKeyboard`.
private struct SectionKeyboardTarget: View {
    let keyboard: SectionKeyboard
    let focus: @MainActor () -> Void
    let release: (@MainActor () -> Void)?

    var body: some View {
        Color.clear
            .onChange(of: keyboard.isInFront) { _, inFront in
                if inFront { keyboard.focus(takingFrom: keyboard.arrivalHolder, focus) } else { release?() }
            }
            // A view can show well after the switch, and the keyboard may have
            // moved by then, so a view that shows late takes it only if it is free.
            .onAppear {
                keyboard.shownTargets += 1
                keyboard.focus(takingFrom: .nothing, focus)
            }
            .onDisappear { keyboard.shownTargets -= 1 }
    }
}
