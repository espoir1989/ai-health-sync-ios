// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - ContentView

/// 主应用视图，采用 iOS 26 液态玻璃设计语言
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \AuditEventRecord.timestamp, order: .reverse) private var auditEvents: [AuditEventRecord]

    var body: some View {
        NavigationStack {
            List {
                statusSection
                permissionsSection
                serverSection
                pairingSection
                dataTypesSection
                auditSection
                settingsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("健康同步")
            .onChange(of: scenePhase) { _, newPhase in
                appState.handleScenePhaseChange(newPhase)
            }
            .alert("错误", isPresented: Binding(get: { appState.lastError != nil }, set: { if !$0 { appState.lastError = nil } })) {
                Button("确定") { appState.lastError = nil }
            } message: {
                Text(appState.lastError ?? "")
            }
        }
    }

    /// 应用版本号
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var statusSection: some View {
        Section("状态") {
            LabeledContent("版本", value: appVersion)
            LabeledContent("数据保护", value: appState.protectedDataAvailable ? "可用" : "已锁定")
            LabeledContent("健康数据", value: appState.healthAuthorizationStatus ? "已授权" : "未授权")
            if let lastExport = appState.syncConfiguration.lastExportAt {
                LabeledContent("上次导出", value: lastExport.formatted())
            }
        }
    }

    private var permissionsSection: some View {
        Section("权限") {
            Button {
                HapticFeedback.impact(.medium)
                Task { await appState.requestHealthAuthorization() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                    Text("请求健康数据访问权限")
                }
            }
            .liquidGlassButtonStyle(.prominent)
        }
    }

    private var serverSection: some View {
        Section("共享服务") {
            // 状态指示器
            HStack {
                Image(systemName: appState.isServerRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(appState.isServerRunning ? .green : .secondary)
                    .symbolEffect(.variableColor, isActive: appState.isServerRunning)
                Text("状态")
                Spacer()
                Text(appState.isServerRunning ? "运行中" : "已停止")
                    .foregroundStyle(.secondary)
            }

            if appState.isServerRunning {
                LabeledContent("端口", value: String(appState.serverPort))

                Button {
                    HapticFeedback.impact(.light)
                    Task { await appState.stopServer() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("停止共享")
                    }
                }
                .liquidGlassButtonStyle(.standard)
                .tint(.red)
            } else {
                Button {
                    HapticFeedback.impact(.medium)
                    Task { await appState.startServer() }
                } label: {
                    if appState.isServerStarting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("启动中...")
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("开始共享")
                        }
                    }
                }
                .liquidGlassButtonStyle(.prominent)
                .disabled(appState.isServerStarting)
            }
        }
        .animation(.smooth, value: appState.isServerRunning)
    }

    @State private var showingShareSheet = false
    @State private var qrImageToShare: UIImage?
    @State private var qrPayloadToShare: String?
    @State private var showCopiedFeedback = false

    private var pairingSection: some View {
        Section("连接信息") {
            if let serverInfo = appState.serverInfo {
                // 服务器信息显示
                LabeledContent("主机", value: serverInfo.host)
                    .font(.system(.body, design: .monospaced))
                LabeledContent("端口", value: String(serverInfo.port))
                LabeledContent("指纹") {
                    Text(serverInfo.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // 生成服务器信息 JSON 用于分享
                let serverInfoPayload = serverInfoPayloadString(for: serverInfo)

                // QR 码显示
                if !serverInfoPayload.isEmpty {
                    QRCodeView(text: serverInfoPayload)
                        .padding(.vertical, 8)
                }

                // 复制按钮
                Button {
                    copyPayloadToClipboard(serverInfoPayload)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                        Text(showCopiedFeedback ? "已复制!" : "复制连接信息")
                    }
                }
                .liquidGlassButtonStyle(showCopiedFeedback ? .prominent : .standard)

                // 分享按钮
                Button {
                    HapticFeedback.impact(.light)
                    if let image = QRCodeRenderer.render(payload: serverInfoPayload) {
                        qrImageToShare = image
                        qrPayloadToShare = serverInfoPayload
                        showingShareSheet = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("分享连接信息")
                    }
                }
                .liquidGlassButtonStyle(.standard)
                .sheet(isPresented: $showingShareSheet) {
                    if let image = qrImageToShare,
                       let payload = qrPayloadToShare {
                        ShareSheet(
                            items: [image],
                            activities: [CopyPayloadActivity(payload: payload, image: image)],
                            excludedActivityTypes: [.copyToPasteboard]
                        )
                    } else if let image = qrImageToShare {
                        ShareSheet(items: [image])
                    }
                }

                // 提示信息
                Label("公开访问模式 - 无需配对", systemImage: "lock.open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 空状态
                ContentUnavailableView {
                    Label("无连接信息", systemImage: "qrcode")
                } description: {
                    Text("开始共享以生成连接信息")
                }
                .listRowBackground(Color.clear)
            }
        }
        .animation(.smooth, value: appState.serverInfo != nil)
    }

    /// 复制 QR 配对载荷到剪贴板
    private func copyPayloadToClipboard(_ payload: String) {
        guard !payload.isEmpty else {
            HapticFeedback.notification(.error)
            return
        }

        // 从相同的载荷字符串生成 QR 图像
        guard let qrImage = QRCodeRenderer.render(payload: payload),
              let pngData = qrImage.pngData() else {
            // 如果图像生成失败，回退到仅文本
            PairingClipboard.setTextPayload(payload)
            HapticFeedback.notification(.success)
            showCopiedFeedback = true
            resetCopiedFeedback()
            return
        }

        // 同时设置文本和图像
        PairingClipboard.setPayload(payload, pngData: pngData)

        HapticFeedback.notification(.success)
        showCopiedFeedback = true
        resetCopiedFeedback()
    }

    /// 重置"已复制"反馈
    private func resetCopiedFeedback() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                showCopiedFeedback = false
            }
        }
    }

    private var dataTypesSection: some View {
        Section("共享数据类型") {
            ForEach(HealthDataType.allCases) { type in
                Toggle(type.displayName, isOn: Binding(
                    get: { appState.syncConfiguration.enabledTypes.contains(type) },
                    set: { newValue in appState.toggleType(type, enabled: newValue) }
                ))
            }
        }
    }

    private var auditSection: some View {
        Section("审计日志") {
            // 公开访问模式 - 无需撤销配对

            if auditEvents.isEmpty {
                ContentUnavailableView {
                    Label("无事件", systemImage: "list.bullet.clipboard")
                } description: {
                    Text("暂无审计事件")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(auditEvents.prefix(10), id: \.id) { event in
                    HStack {
                        Image(systemName: auditEventIcon(for: event.eventType))
                            .foregroundStyle(auditEventColor(for: event.eventType))
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.eventType)
                                .font(.subheadline)
                            Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// 返回审计事件类型对应的 SF Symbol
    private func auditEventIcon(for eventType: String) -> String {
        switch eventType {
        case let type where type.contains("auth"):
            return "person.badge.key.fill"
        case let type where type.contains("server"):
            return "server.rack"
        case let type where type.contains("health"):
            return "heart.fill"
        case let type where type.contains("revoke"):
            return "xmark.circle.fill"
        default:
            return "doc.text.fill"
        }
    }

    /// 返回审计事件类型对应的颜色
    private func auditEventColor(for eventType: String) -> Color {
        switch eventType {
        case let type where type.contains("revoke"):
            return .red
        case let type where type.contains("auth"):
            return .blue
        case let type where type.contains("server"):
            return .green
        case let type where type.contains("health"):
            return .pink
        default:
            return .secondary
        }
    }

    private var settingsSection: some View {
        Section("设置") {
            NavigationLink {
                HealthInsightsView()
            } label: {
                Label("健康洞察", systemImage: "chart.line.uptrend.xyaxis")
            }
            
            NavigationLink {
                PrivacyPolicyView()
            } label: {
                Label("隐私政策", systemImage: "hand.raised.fill")
            }

            NavigationLink {
                AboutView()
            } label: {
                Label("关于", systemImage: "info.circle.fill")
            }
        }
    }

    private func serverInfoPayloadString(for info: ServerInfo) -> String {
        // 生成兼容 CLI 的 JSON 格式
        let payload: [String: Any] = [
            "version": "1",
            "host": info.host,
            "port": info.port,
            "code": "",  // 公开访问模式，无需配对码
            "certificateFingerprint": info.fingerprint
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return ""
        }
        return jsonString
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var activities: [UIActivity]? = nil
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: activities)
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 自定义"复制"活动
final class CopyPayloadActivity: UIActivity {
    private let payload: String
    private let image: UIImage?

    init(payload: String, image: UIImage?) {
        self.payload = payload
        self.image = image
        super.init()
    }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("org.mvneves.healthsync.copy")
    }

    override var activityTitle: String? {
        "复制"
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "doc.on.doc")
    }

    override class var activityCategory: UIActivity.Category {
        .action
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        !payload.isEmpty
    }

    override func perform() {
        if let image, let pngData = image.pngData() {
            PairingClipboard.setPayload(payload, pngData: pngData)
        } else {
            PairingClipboard.setTextPayload(payload)
        }
        activityDidFinish(true)
    }
}

// MARK: - Haptic Feedback

/// 触觉反馈辅助类
@MainActor
enum HapticFeedback {
    /// 冲击反馈样式
    enum ImpactStyle {
        case light, medium, heavy, soft, rigid

        var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light: return .light
            case .medium: return .medium
            case .heavy: return .heavy
            case .soft: return .soft
            case .rigid: return .rigid
            }
        }
    }

    /// 通知反馈类型
    enum NotificationType {
        case success, warning, error

        var uiType: UINotificationFeedbackGenerator.FeedbackType {
            switch self {
            case .success: return .success
            case .warning: return .warning
            case .error: return .error
            }
        }
    }

    /// 触发冲击触觉反馈
    static func impact(_ style: ImpactStyle) {
        UIImpactFeedbackGenerator(style: style.uiStyle).impactOccurred()
    }

    /// 触发通知触觉反馈
    static func notification(_ type: NotificationType) {
        UINotificationFeedbackGenerator().notificationOccurred(type.uiType)
    }

    /// 触发选择触觉反馈
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

#Preview {
    let schema = Schema([
        SyncConfiguration.self,
        PairedDevice.self,
        AuditEventRecord.self
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: configuration)
    let state = AppState(modelContainer: container)
    return ContentView()
        .environment(state)
        .modelContainer(container)
}
