import SwiftUI

/// Edits the already-persisted IPTC Creator Contact Info and Location structures without
/// flattening repeatable values into delimiter-dependent strings.
struct StructuredEditorialMetadataEditor: View {
    @Binding var creatorContactInfo: CreatorContactInfo?
    @Binding var locationsCreated: [EditorialLocation]
    @Binding var locationsShown: [EditorialLocation]
    var onChange: () -> Void
    /// Saves like the panel's other fields: on Return, on leaving a field, and on Remove.
    var onCommit: () -> Void = {}

    @State private var isContactExpanded = false
    @State private var isCreatedExpanded = false
    @State private var isShownExpanded = false
    @FocusState private var focusedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Creator Contact Information", isExpanded: $isContactExpanded) {
                contactEditor
                    .padding(.top, 6)
            }
            .accessibilityIdentifier("metadata.creatorContactInfo")

            locationCollection(
                title: "Location Created",
                locations: $locationsCreated,
                isExpanded: $isCreatedExpanded,
                identifier: "metadata.locationsCreated"
            )

            locationCollection(
                title: "Location Shown",
                locations: $locationsShown,
                isExpanded: $isShownExpanded,
                identifier: "metadata.locationsShown"
            )
        }
        .onSubmit { onCommit() }
        .onChange(of: focusedKey) { oldValue, newValue in
            if oldValue != nil, oldValue != newValue { onCommit() }
        }
    }

    var contact: Binding<CreatorContactInfo> {
        Binding(
            get: { creatorContactInfo ?? CreatorContactInfo() },
            set: { updated in
                // Empty rows are editor state: retain them until the user types or removes
                // them. isEmpty deliberately ignores blank values for metadata writes.
                let hasRows = !updated.addressLines.isEmpty || !updated.emails.isEmpty
                    || !updated.phoneNumbers.isEmpty || !updated.webURLs.isEmpty
                creatorContactInfo = updated.isEmpty && !hasRows ? nil : updated
                onChange()
            }
        )
    }

    @ViewBuilder
    private var contactEditor: some View {
        let contact = contact
        VStack(alignment: .leading, spacing: 6) {
            RepeatableStructuredTextEditor(title: "Address line", values: contact.addressLines,
                focus: $focusedKey, keyPrefix: "contact.address", onRemove: onCommit)
            HStack {
                TextField("City", text: optionalText(contact.city))
                    .focused($focusedKey, equals: "contact.city")
                TextField("Region / State", text: optionalText(contact.region))
                    .focused($focusedKey, equals: "contact.region")
            }
            HStack {
                TextField("Postal code", text: optionalText(contact.postalCode))
                    .focused($focusedKey, equals: "contact.postalCode")
                TextField("Country", text: optionalText(contact.country))
                    .focused($focusedKey, equals: "contact.country")
            }
            RepeatableStructuredTextEditor(title: "Email", values: contact.emails,
                focus: $focusedKey, keyPrefix: "contact.email", onRemove: onCommit)
            RepeatableStructuredTextEditor(title: "Phone", values: contact.phoneNumbers,
                focus: $focusedKey, keyPrefix: "contact.phone", onRemove: onCommit)
            RepeatableStructuredTextEditor(title: "Web URL", values: contact.webURLs,
                focus: $focusedKey, keyPrefix: "contact.web", onRemove: onCommit)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func locationCollection(
        title: String,
        locations: Binding<[EditorialLocation]>,
        isExpanded: Binding<Bool>,
        identifier: String
    ) -> some View {
        DisclosureGroup(title, isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if locations.wrappedValue.isEmpty {
                    Text("No structured locations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(locations.wrappedValue.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(title) \(index + 1)")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button("Remove", role: .destructive) {
                                guard locations.wrappedValue.indices.contains(index) else { return }
                                locations.wrappedValue.remove(at: index)
                                onChange()
                                onCommit()
                            }
                            .buttonStyle(.borderless)
                        }
                        EditorialLocationEditor(location: location(at: index, in: locations),
                            focus: $focusedKey, keyPrefix: "\(identifier).\(index)", onRemove: onCommit)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                }
                Button("Add \(title)") {
                    locations.wrappedValue.append(EditorialLocation())
                    onChange()
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier(identifier)
    }

    private func location(
        at index: Int,
        in locations: Binding<[EditorialLocation]>
    ) -> Binding<EditorialLocation> {
        Binding(
            get: {
                guard locations.wrappedValue.indices.contains(index) else {
                    return EditorialLocation()
                }
                return locations.wrappedValue[index]
            },
            set: { updated in
                guard locations.wrappedValue.indices.contains(index) else { return }
                locations.wrappedValue[index] = updated
                onChange()
            }
        )
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct EditorialLocationEditor: View {
    @Binding var location: EditorialLocation
    let focus: FocusState<String?>.Binding
    let keyPrefix: String
    var onRemove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RepeatableStructuredTextEditor(title: "Identifier", values: $location.identifiers,
                focus: focus, keyPrefix: "\(keyPrefix).identifier", onRemove: onRemove)
            TextField("Location name", text: optionalText($location.name))
                .focused(focus, equals: "\(keyPrefix).name")
            HStack {
                TextField("Sublocation", text: optionalText($location.sublocation))
                    .focused(focus, equals: "\(keyPrefix).sublocation")
                TextField("City", text: optionalText($location.city))
                    .focused(focus, equals: "\(keyPrefix).city")
            }
            HStack {
                TextField("Province / State", text: optionalText($location.provinceState))
                    .focused(focus, equals: "\(keyPrefix).provinceState")
                TextField("Country", text: optionalText($location.countryName))
                    .focused(focus, equals: "\(keyPrefix).country")
            }
            HStack {
                TextField("Country code", text: optionalText($location.countryCode))
                    .focused(focus, equals: "\(keyPrefix).countryCode")
                TextField("World region", text: optionalText($location.worldRegion))
                    .focused(focus, equals: "\(keyPrefix).worldRegion")
            }
            HStack {
                TextField("Latitude", value: $location.latitude, format: .number)
                    .focused(focus, equals: "\(keyPrefix).latitude")
                TextField("Longitude", value: $location.longitude, format: .number)
                    .focused(focus, equals: "\(keyPrefix).longitude")
                TextField("Altitude (m)", value: $location.altitudeMeters, format: .number)
                    .focused(focus, equals: "\(keyPrefix).altitude")
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct RepeatableStructuredTextEditor: View {
    let title: String
    @Binding var values: [String]
    let focus: FocusState<String?>.Binding
    let keyPrefix: String
    var onRemove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(values.indices, id: \.self) { index in
                HStack {
                    TextField(title, text: value(at: index))
                        .accessibilityIdentifier("metadata.structured.\(title).\(index)")
                        .focused(focus, equals: "\(keyPrefix).\(index)")
                    Button {
                        guard values.indices.contains(index) else { return }
                        values.remove(at: index)
                        onRemove()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(title.lowercased())")
                }
            }
            Button("Add \(title)") {
                values.append("")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("metadata.structured.add.\(title)")
        }
    }

    private func value(at index: Int) -> Binding<String> {
        Binding(
            get: { values.indices.contains(index) ? values[index] : "" },
            set: { newValue in
                guard values.indices.contains(index) else { return }
                values[index] = newValue
            }
        )
    }
}
