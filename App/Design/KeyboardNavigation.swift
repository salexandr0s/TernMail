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
