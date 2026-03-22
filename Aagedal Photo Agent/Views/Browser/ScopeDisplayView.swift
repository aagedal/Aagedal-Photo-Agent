import SwiftUI

struct ScopeDisplayView: View {
    let scopeViewModel: ScopeViewModel

    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: Bindable(scopeViewModel).scopeMode) {
                Text("Wave").tag(ScopeViewModel.ScopeMode.waveform)
                Text("Parade").tag(ScopeViewModel.ScopeMode.parade)
                Text("Vector").tag(ScopeViewModel.ScopeMode.vectorscope)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            ZStack {
                Color(nsColor: NSColor(white: 0.1, alpha: 1))

                if let image = scopeViewModel.scopeImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else if scopeViewModel.isComputing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
