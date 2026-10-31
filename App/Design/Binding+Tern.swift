import SwiftUI

/// Derived bindings for the shapes views keep needing, so views don't build
/// `Binding(get:set:)` by hand. State that a model already stores should get
/// a binding from the model instead.
@MainActor
extension Binding {
    /// Shows `value` and hands each change to `action` without storing it, for
    /// controls whose owner decides what a change does: a guarded navigation,
    /// an editor command or a parent's callback.
    init(_ value: Value, set action: @escaping (Value) -> Void) {
        self.init(get: { value }, set: { action($0) })
    }

    /// `true` while the optional holds a value. Setting `false` clears it, which
    /// is how alerts, dialogs and popovers report a dismissal.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }

    /// `true` while the optional holds a value. Setting `true` stores `initial`
    /// when it's empty; setting `false` clears it.
    func isPresent<Wrapped>(default initial: @autoclosure @escaping () -> Wrapped) -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { isOn in
            if !isOn {
                wrappedValue = nil
            } else if wrappedValue == nil {
                wrappedValue = initial()
            }
        })
    }

    /// `true` while the optional holds `value`. Setting `true` stores `value`.
    /// Setting `false` clears the optional only while it still holds `value`, so
    /// one row's popover closing leaves another row's request alone.
    func equals<Wrapped: Equatable>(_ value: Wrapped) -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue == value }, set: { isOn in
            if isOn {
                wrappedValue = value
            } else if wrappedValue == value {
                wrappedValue = nil
            }
        })
    }

    /// `true` while the value is `value`, for radio-style menu items. Setting
    /// `true` selects `value`; setting `false` does nothing, since picking another
    /// item is what deselects this one.
    func selecting(_ value: Value) -> Binding<Bool> where Value: Equatable {
        Binding<Bool>(get: { wrappedValue == value }, set: { if $0 { wrappedValue = value } })
    }

    /// `true` while the set holds `element`. Setting it inserts or removes the element.
    func contains<Element: Hashable>(_ element: Element) -> Binding<Bool> where Value == Set<Element> {
        Binding<Bool>(get: { wrappedValue.contains(element) }, set: { isOn in
            if isOn {
                wrappedValue.insert(element)
            } else {
                wrappedValue.remove(element)
            }
        })
    }

    /// Reads `fallback` while the optional is empty. Writes store the new value.
    func or<Wrapped>(_ fallback: Wrapped) -> Binding<Wrapped> where Value == Wrapped? {
        Binding<Wrapped>(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }
}

@MainActor
extension Binding where Value == Bool {
    /// The opposite flag, for a control worded the other way round from the
    /// stored setting.
    func negated() -> Binding<Bool> {
        Binding(get: { !wrappedValue }, set: { wrappedValue = !$0 })
    }
}
