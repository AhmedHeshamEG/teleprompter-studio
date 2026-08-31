import SwiftUI

struct StylePanelView: View {
    @Bindable var style: ScriptStyle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext


    var body: some View {
        NavigationStack {
            Form {
                Section("Font") {
                    // One list of faces, shared with Studio's on-set picker, so a script can't be
                    // set to a typeface only one of the two screens knows how to render.
                    Picker("Typeface", selection: $style.fontName) {
                        ForEach(PrompterTypeface.allCases) { face in
                            Text(face.displayName)
                                .font(PrompterFonts.font(named: face.rawValue, size: 17))
                                .tag(face.rawValue)
                        }
                    }
                    LabeledSlider(label: "Size", systemImage: "textformat.size", value: $style.baseSize, range: 18...120)
                    LabeledSlider(label: "Line Height", systemImage: "line.3.horizontal", value: $style.lineHeight, range: 1.0...2.2) {
                        String(format: "%.1f×", $0)
                    }
                }

                Section("Colors") {
                    ColorPicker("Text Color", selection: Binding(
                        get: { HexColor.color(style.textColorHex) },
                        set: { style.textColorHex = HexColor.hex($0) }
                    ))
                    ColorPicker("Background", selection: Binding(
                        get: { HexColor.color(style.bgColorHex) },
                        set: { style.bgColorHex = HexColor.hex($0) }
                    ))
                    ColorPicker("Accent", selection: Binding(
                        get: { HexColor.color(style.accentColorHex) },
                        set: { style.accentColorHex = HexColor.hex($0) }
                    ))
                }

                Section("Margins") {
                    LabeledSlider(label: "Top", systemImage: "arrow.up.to.line", value: $style.marginTop, range: 0...30) { "\(Int($0))%" }
                    LabeledSlider(label: "Bottom", systemImage: "arrow.down.to.line", value: $style.marginBottom, range: 0...30) { "\(Int($0))%" }
                    LabeledSlider(label: "Horizontal", systemImage: "arrow.left.and.right", value: $style.marginHorizontal, range: 0...30) { "\(Int($0))%" }
                }

                Section("Mirror (Beam-Splitter Rig)") {
                    Toggle("Flip Horizontal", isOn: $style.mirrorHorizontal)
                    Toggle("Flip Vertical", isOn: $style.mirrorVertical)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Script Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
