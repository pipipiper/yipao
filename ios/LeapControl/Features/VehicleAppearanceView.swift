import PhotosUI
import SwiftUI

enum VehicleHomeTheme: String, CaseIterable {
    case automatic
    case forest
    case frost
    case sunset

    var title: String {
        switch self {
        case .automatic: "随车况"
        case .forest: "松林绿"
        case .frost: "冰川蓝"
        case .sunset: "暖阳橙"
        }
    }

    var tint: Color? {
        switch self {
        case .automatic: nil
        case .forest: LeapStyle.accent
        case .frost: LeapStyle.frost
        case .sunset: LeapStyle.warm
        }
    }
}

struct VehicleAppearanceView: View {
    @Environment(VehicleStore.self) private var store
    @AppStorage("vehicleHomeTheme") private var theme = VehicleHomeTheme.automatic

    var body: some View {
        List {
            Section("首页背景") {
                Picker("主题色", selection: $theme) {
                    ForEach(VehicleHomeTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
            }
            if let vehicle = VehicleIdentity(session: store.session) {
                VehiclePhotoSection(vehicle: vehicle)
                    .id(vehicle)
            }
        }
        .navigationTitle("爱车外观")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background { LeapBackground(tint: theme.tint ?? LeapStyle.cool) }
    }
}

private struct VehiclePhotoSection: View {
    let vehicle: VehicleIdentity
    @Environment(VehicleStore.self) private var store
    @State private var selection: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var isImporting = false

    var body: some View {
        Section {
            if let image = store.customVehiclePhoto {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .accessibilityLabel("当前爱车主图")
            }

            PhotosPicker(selection: $selection, matching: .images) {
                Label("从相册选择", systemImage: "photo.on.rectangle")
            }
            .disabled(isImporting)

            if isImporting {
                ProgressView("正在导入照片")
            } else if store.customVehiclePhoto != nil {
                Button("恢复默认车图", role: .destructive) {
                    do {
                        try store.removeCustomVehiclePhoto(for: vehicle)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } header: {
            Text("爱车主图")
        } footer: {
            Text("照片仅保存在本机，并应用到当前车辆的首页。支持透明背景图片。")
        }
        .task(id: selection) { [item = selection] in
            guard let item else { return }
            await importPhoto(item)
        }
        .alert("无法更新爱车主图", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        isImporting = true
        defer {
            isImporting = false
            selection = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw LeapError.decode("无法读取所选照片")
            }
            let prepared = try await Task.detached(priority: .userInitiated) {
                try CustomVehiclePhoto.prepare(data)
            }.value
            try Task.checkCancellation()
            try store.saveCustomVehiclePhoto(prepared, for: vehicle)
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}
