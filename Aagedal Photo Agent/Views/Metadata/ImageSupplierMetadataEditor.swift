import SwiftUI

/// Structured editor for the ordered PLUS Image Supplier sequence. Name and identifier stay in
/// one row so neither templates nor batch editing can lose their association.
struct ImageSupplierMetadataEditor: View {
    @Binding var suppliers: [EditorialImageSupplier]
    var onChange: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Image Supplier", isExpanded: $isExpanded) {
            supplierRows(suppliers: $suppliers, onChange: onChange)
                .padding(.top, 6)
        }
        .accessibilityIdentifier("metadata.imageSupplier")
    }
}

/// Batch editing has an explicit operation boundary. Common/partial values are display-only and
/// never become write data; only the user-created draft is supplied to append/replace.
struct BatchImageSupplierMetadataEditor: View {
    let selection: BatchListSelection<EditorialImageSupplier>
    var onMutation: (EditorialImageSupplierMutation) -> Void

    @State private var isExpanded = false
    @State private var operation: Operation = .untouched
    @State private var draft: [EditorialImageSupplier] = []

    private enum Operation: String, CaseIterable, Identifiable {
        case untouched = "Leave untouched"
        case append = "Append"
        case replace = "Replace"
        case clear = "Clear"

        var id: Self { self }
    }

    var body: some View {
        DisclosureGroup("Image Supplier", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                selectionSummary
                Picker("Batch operation", selection: operationBinding) {
                    ForEach(Operation.allCases) { operation in
                        Text(operation.rawValue).tag(operation)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("metadata.imageSupplier.batchOperation")

                if operation == .append || operation == .replace {
                    supplierRows(suppliers: $draft, onChange: publishDraft)
                } else if operation == .clear {
                    Text("All structured Image Supplier entries will be removed from every selected image.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier("metadata.imageSupplier.batch")
    }

    private var operationBinding: Binding<Operation> {
        Binding(
            get: { operation },
            set: { newOperation in
                operation = newOperation
                switch newOperation {
                case .untouched:
                    draft = []
                    onMutation(.untouched)
                case .append:
                    draft = [EditorialImageSupplier()]
                    publishDraft()
                case .replace:
                    draft = selection.common.isEmpty
                        ? [EditorialImageSupplier()]
                        : selection.common
                    publishDraft()
                case .clear:
                    draft = []
                    onMutation(.clear)
                }
            }
        )
    }

    @ViewBuilder
    private var selectionSummary: some View {
        if !selection.common.isEmpty {
            Text("Common: \(supplierSummary(selection.common))")
                .font(.caption)
        }
        if !selection.partial.isEmpty {
            Text("Only some images: \(supplierSummary(selection.partial))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if selection.common.isEmpty && selection.partial.isEmpty {
            Text("No selected image has a structured Image Supplier entry.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func publishDraft() {
        let normalized = EditorialImageSupplier.normalizedValues(draft)
        guard !normalized.isEmpty else {
            // An empty draft is not a synonym for clear. Keep the current records untouched until
            // the user enters at least one valid supplier or explicitly chooses Clear.
            onMutation(.untouched)
            return
        }
        switch operation {
        case .append: onMutation(.append(normalized))
        case .replace: onMutation(.replace(normalized))
        case .untouched, .clear: break
        }
    }
}

@ViewBuilder
private func supplierRows(
    suppliers: Binding<[EditorialImageSupplier]>,
    onChange: @escaping () -> Void
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        if suppliers.wrappedValue.isEmpty {
            Text("No structured suppliers")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(suppliers.wrappedValue.indices, id: \.self) { index in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Supplier \(index + 1)")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Remove", role: .destructive) {
                        guard suppliers.wrappedValue.indices.contains(index) else { return }
                        suppliers.wrappedValue.remove(at: index)
                        onChange()
                    }
                    .buttonStyle(.borderless)
                }
                TextField("Supplier name", text: supplierText(at: index, keyPath: \.name, in: suppliers, onChange: onChange))
                TextField("Supplier identifier", text: supplierText(at: index, keyPath: \.identifier, in: suppliers, onChange: onChange))
            }
            .textFieldStyle(.roundedBorder)
            .padding(8)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        }
        Button("Add Image Supplier") {
            suppliers.wrappedValue.append(EditorialImageSupplier())
            onChange()
        }
        .buttonStyle(.borderless)
    }
}

private func supplierText(
    at index: Int,
    keyPath: WritableKeyPath<EditorialImageSupplier, String?>,
    in suppliers: Binding<[EditorialImageSupplier]>,
    onChange: @escaping () -> Void
) -> Binding<String> {
    Binding(
        get: {
            guard suppliers.wrappedValue.indices.contains(index) else { return "" }
            return suppliers.wrappedValue[index][keyPath: keyPath] ?? ""
        },
        set: { value in
            guard suppliers.wrappedValue.indices.contains(index) else { return }
            suppliers.wrappedValue[index][keyPath: keyPath] = value.isEmpty ? nil : value
            onChange()
        }
    )
}

private func supplierSummary(_ suppliers: [EditorialImageSupplier]) -> String {
    suppliers.map { supplier in
        switch (supplier.name, supplier.identifier) {
        case let (name?, identifier?): "\(name) (\(identifier))"
        case let (name?, nil): name
        case let (nil, identifier?): identifier
        case (nil, nil): ""
        }
    }.filter { !$0.isEmpty }.joined(separator: ", ")
}
