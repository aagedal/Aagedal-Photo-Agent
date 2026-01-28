import SwiftUI

struct KeywordsEditor: View {
    let label: String
    @Binding var keywords: [String]
    var onChange: () -> Void = {}

    @State private var newKeyword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 4) {
                ForEach(keywords, id: \.self) { keyword in
                    HStack(spacing: 2) {
                        Text(keyword)
                            .font(.caption)
                        Button {
                            keywords.removeAll { $0 == keyword }
                            onChange()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 4) {
                TextField("Add \(label.lowercased())...", text: $newKeyword)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit {
                        addKeyword()
                    }
                    .onChange(of: newKeyword) { _, newValue in
                        if newValue.contains(",") || newValue.contains(";") {
                            addKeyword()
                        }
                    }

                Button {
                    addKeyword()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private func addKeyword() {
        let parts = newKeyword
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !keywords.contains($0) }
        guard !parts.isEmpty else {
            newKeyword = ""
            return
        }
        keywords.append(contentsOf: parts)
        newKeyword = ""
        onChange()
    }
}
