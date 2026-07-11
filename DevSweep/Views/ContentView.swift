import SwiftUI

struct ContentView: View {
    @State private var model = SweepModel()
    @State private var confirmingClean = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isScanning && model.categories.isEmpty {
                Spacer()
                ProgressView("Scanning developer caches…")
                Spacer()
            } else {
                categoryList
                Divider()
                footer
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .task { await model.scan() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning || model.isCleaning)
            }
        }
        .navigationTitle("DevSweep")
    }

    private var categoryList: some View {
        List {
            ForEach(model.categories) { category in
                Section {
                    ForEach(category.items) { item in
                        ItemRow(item: item, isOn: binding(for: item))
                    }
                } header: {
                    HStack {
                        Text(category.name)
                        Spacer()
                        Text(category.totalSize.byteString)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } footer: {
                    Text(category.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            if let freed = model.lastFreed {
                Label("Freed \(freed.byteString)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if !model.errors.isEmpty {
                Label("\(model.errors.count) item(s) failed — may need Full Disk Access",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(model.errors.joined(separator: "\n"))
            }
            Spacer()
            Text("\(model.selectedCount) selected · \(model.selectedSize.byteString)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                confirmingClean = true
            } label: {
                if model.isCleaning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Clean Selected")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedCount == 0 || model.isCleaning || model.isScanning)
            .confirmationDialog(
                "Delete \(model.selectedCount) item(s) (\(model.selectedSize.byteString))?",
                isPresented: $confirmingClean
            ) {
                Button("Delete", role: .destructive) {
                    Task { await model.cleanSelected() }
                }
            } message: {
                Text("Items are removed permanently, not moved to the Trash.")
            }
        }
        .padding(12)
    }

    private func binding(for item: CacheItem) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(item.id) },
            set: { isOn in
                if isOn { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
            }
        )
    }
}

private struct ItemRow: View {
    let item: CacheItem
    let isOn: Binding<Bool>

    var body: some View {
        HStack {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                        if item.risk == .caution {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .help("Review before deleting")
                        }
                    }
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(item.size > 0 ? item.size.byteString : "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
