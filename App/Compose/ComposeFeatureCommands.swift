import SwiftUI

struct ComposeFeatureCommands: Commands {
    @FocusedValue(\.composeModel) private var model

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Menu("Insert Template") {
                if let model, !model.templates.isEmpty {
                    ForEach(model.templates) { template in
                        Button(template.name) { model.insertTemplate(template) }
                            .disabled(!model.isEditable)
                    }
                } else { Text("No templates") }
            }
            .disabled(model == nil)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Formatting", isOn: Binding(
                get: { model?.showsFormatting ?? false },
                set: { model?.showsFormatting = $0 }
            ))
            .disabled(model == nil)
        }
    }
}
