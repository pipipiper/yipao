import SwiftUI

struct SettingsView: View {
    @Environment(VehicleStore.self) private var store
    @State private var showLogoutConfirm = false
    @State private var showCalibration = false
    @State private var presentedDoc: LegalDoc?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        @Bindable var store = store

        List {
            // 账号和车辆是一件事：这个账号下有哪些车。原来分成两段，中间隔着别的设置，
            // 得上下翻才对得起来。
            Section {
                accountRow
                vehicleRows
            } header: {
                Text("账号")
            }

            Section {
                if store.biometricKind == .none {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("生物识别不可用")
                            Text("此设备未启用面容或指纹，控车时需要输入操作密码")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                } else {
                    Toggle(isOn: $store.biometricEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(store.biometricKind.label) 快捷验证")
                                Text("控车时用\(store.biometricKind.label)解锁已保存的操作密码")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: store.biometricKind.symbol)
                        }
                    }
                    .tint(LeapStyle.accent)
                }

                if store.hasSavedPassword {
                    Button(role: .destructive) {
                        store.forgetPassword()
                    } label: {
                        Label("忘记已保存的操作密码", systemImage: "key.slash")
                    }
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("操作密码未保存")
                            Text("下次控车输入后可选择记住")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "key")
                    }
                }
            } header: {
                Text("安全")
            } footer: {
                Text("操作密码只加密保存在本机，不会同步到别处。")
            }

            Section {
                Picker(selection: $store.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Label("深浅外观", systemImage: "circle.lefthalf.filled")
                }

                Toggle(isOn: $store.showCarModel) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("显示车模型")
                            Text("关闭官方 2D / 3D 车图")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "car.fill")
                    }
                }
                .tint(LeapStyle.accent)

                NavigationLink {
                    VehicleAppearanceView()
                } label: {
                    Label("爱车外观", systemImage: "paintpalette")
                }
            } header: {
                Text("外观")
            } footer: {
                Text("车模型资源来自零跑官方，关闭后不再下载，重新打开时自动恢复。")
            }

            // calibrationSection

            Section {
                Button { presentedDoc = .userAgreement } label: {
                    Label("用户协议", systemImage: "doc.text")
                }
                .tint(LeapStyle.primaryLabel)
                Button { presentedDoc = .privacy } label: {
                    Label("隐私政策", systemImage: "hand.raised")
                }
                .tint(LeapStyle.primaryLabel)
            } header: {
                Text("关于")
            } footer: {
                Text("我们不会记录和上传零跑官方服务的会话信息，控车信息等其他信息。")
            }

            Section {
                Button(role: .destructive) { showLogoutConfirm = true } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
                // iOS 26 起确认弹窗会锚定在修饰符附着的视图上弹出。
                // 挂在 List 上它会锚到列表顶部，必须挂在触发它的按钮上。
                .confirmationDialog("退出登录？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                    Button("退出登录", role: .destructive) { Task { await store.logout() } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("会清除本机的登录状态和操作密码，需要重新用验证码登录。")
                }
            } footer: {
                Text("壹跑 \(appVersion)")
                    .font(.caption2)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        // 这一段单独拆出来：整个 Form 的表达式已经大到编译器要放弃类型检查了。
        .scrollContentBackground(.hidden)
        .background { LeapBackground(tint: LeapStyle.cool) }
        .sheet(isPresented: $showCalibration) {
            CalibrationView()
                .environment(store)
        }
        .sheet(item: $presentedDoc) { LegalDocView(doc: $0) }
    }

    /// 只在这台车确实有认不出的车况时才出现。
    /// 字段都认全的车（比如 S01）根本看不到这一段——对他们来说这个入口只会让人困惑。
    @ViewBuilder
    private var calibrationSection: some View {
        let pending = store.pendingCalibrationTasks
        if !pending.isEmpty {
            Section {
                Button {
                    showCalibration = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("适配我的车型")
                            Text("还有 \(pending.count) 项车况认不出来")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wand.and.sparkles")
                    }
                }
                .tint(LeapStyle.primaryLabel)
            } footer: {
                Text("零跑没有公开车况字段表，不同车型上报的字段名也不一样。在车边按提示操作几下，App 就能认出你这台车的门锁、车窗和空调。不上传任何数据。")
            }
        }
    }

    private var accountRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.fill")
                .font(.system(size: 19))
                .foregroundStyle(LeapStyle.accent)
                .frame(width: 46, height: 46)
                .leapGlass(.regular.tint(LeapStyle.accent.opacity(0.28)), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(maskedPhone)
                    .font(.headline)
                    .monospaced()
                Text(store.session.isLoggedIn ? "已登录" : "未登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// 账号行下面那几行车。多车时可点着换，单车时只是一行只读信息。
    @ViewBuilder
    private var vehicleRows: some View {
        if store.session.vehicles.count > 1 {
            ForEach(store.session.vehicles) { vehicle in
                Button {
                    Task { await store.selectVehicle(vehicle) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vehicle.name)
                            Text(vehicle.maskedVin)
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if vehicle.vin == store.session.selectedVin {
                            Image(systemName: "checkmark")
                                .foregroundStyle(LeapStyle.accent)
                        }
                    }
                }
                .tint(LeapStyle.primaryLabel)
            }
        } else if let vehicle = store.session.selectedVehicle {
            LabeledContent(vehicle.name, value: vehicle.maskedVin)
                .monospaced()
        }
    }

    private var maskedPhone: String {
        let phone = store.session.phone
        guard phone.count == 11 else { return phone.isEmpty ? "未知账号" : phone }
        return "\(phone.prefix(3)) **** \(phone.suffix(4))"
    }
}
