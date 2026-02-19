// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import HealthKit
import Observation
import os
import SwiftData
import SwiftUI
import UIKit

/// 服务器连接信息（用于显示给用户）
struct ServerInfo: Codable {
    let host: String
    let port: Int
    let fingerprint: String
}

@MainActor
@Observable
final class AppState {
    private let modelContainer: ModelContainer
    private let healthService = HealthKitService()
    private let auditService: AuditService
    private let networkServer: NetworkServer
    private let backgroundTaskManager: BackgroundTaskManaging
    private let backgroundTaskController: BackgroundTaskController
    private var notificationTask: Task<Void, Never>?

    var syncConfiguration: SyncConfiguration
    var serverInfo: ServerInfo?
    var isServerRunning: Bool = false
    var isServerStarting: Bool = false
    var serverPort: Int = 0
    var serverFingerprint: String = ""
    var lastError: String?
    var protectedDataAvailable: Bool = true
    var healthAuthorizationStatus: Bool = false

    init(modelContainer: ModelContainer, backgroundTaskManager: BackgroundTaskManaging = UIApplication.shared) {
        self.modelContainer = modelContainer
        self.auditService = AuditService(modelContainer: modelContainer)
        self.backgroundTaskManager = backgroundTaskManager
        self.backgroundTaskController = BackgroundTaskController(manager: backgroundTaskManager)
        self.networkServer = NetworkServer(
            healthService: healthService,
            auditService: auditService,
            modelContainer: modelContainer,
            protectedDataAvailable: {
                await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
            },
            deviceNameProvider: {
                // Use anonymized device identifier to prevent PII exposure
                // Format: "HealthSync-XXXX" where XXXX is first 4 chars of hashed device ID
                await MainActor.run {
                    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
                    let hash = SHA256.hash(data: Data(deviceId.utf8))
                    let shortHash = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
                    return "HealthSync-\(shortHash.uppercased())"
                }
            },
            listenerPort: nil
        )

        // Pre-warm TLS identity on a background thread to avoid first-run UI stalls.
        Task.detached(priority: .utility) {
            _ = try? CertificateService.loadOrCreateIdentity()
        }

        let context = modelContainer.mainContext
        do {
            if let existing = try context.fetch(FetchDescriptor<SyncConfiguration>()).first {
                self.syncConfiguration = existing
            } else {
                let newConfig = SyncConfiguration()
                context.insert(newConfig)
                try context.save()
                self.syncConfiguration = newConfig
            }
        } catch {
            AppLoggers.app.error("加载或创建同步配置失败: \(error.localizedDescription, privacy: .public)")
            // Fallback to in-memory config (not persisted)
            self.syncConfiguration = SyncConfiguration()
        }

        self.protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        self.backgroundTaskController.setOnExpiration { [weak self] in
            guard let self else { return }
            // 当后台时间过期时，不再停止服务器
            // 服务器将继续运行，iOS会处理挂起
            AppLoggers.app.info("后台时间已过期，服务器继续在后台运行")
            // 结束后台任务但保持服务器运行
            self.backgroundTaskController.endIfNeeded()
        }
        // Notification observers are started from the App entry point on the main actor.
        
        // 应用启动时自动开始共享
        Task {
            // 等待一小段时间确保UI已准备好
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            await self.startServer()
        }
    }

    deinit {}

    func startNotificationObservers() {
        guard notificationTask == nil else { return }

        notificationTask = Task { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: UIApplication.protectedDataDidBecomeAvailableNotification
                    ) {
                        await self?.handleProtectedDataAvailable()
                    }
                }

                group.addTask { [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: UIApplication.protectedDataWillBecomeUnavailableNotification
                    ) {
                        await self?.handleProtectedDataUnavailable()
                    }
                }

                group.addTask { [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: UIApplication.didBecomeActiveNotification
                    ) {
                        await self?.handleAppDidBecomeActive()
                    }
                }
            }
        }
    }

    func requestHealthAuthorization() async {
        do {
            guard await healthService.isAvailable() else {
                healthAuthorizationStatus = false
                lastError = "Health data is unavailable on this device."
                await auditService.record(eventType: "auth.healthkit", details: ["status": "unavailable"])
                return
            }

            // Show the authorization dialog
            let dialogShown = try await healthService.requestAuthorization(for: syncConfiguration.enabledTypes)

            // NOTE: For READ-only permissions, Apple hides whether user granted or denied.
            // requestAuthorization returns true if the dialog was shown successfully,
            // NOT whether the user approved. We can only know the dialog was presented.
            // Use hasRequestedAuthorization to verify the dialog was shown.
            healthAuthorizationStatus = await healthService.hasRequestedAuthorization(for: syncConfiguration.enabledTypes)

            await auditService.record(eventType: "auth.healthkit", details: [
                "dialogShown": String(dialogShown),
                "requested": String(healthAuthorizationStatus)
            ])
        } catch {
            lastError = "HealthKit authorization failed: \(error.localizedDescription)"
        }
    }

    private var isRunningInSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    func toggleType(_ type: HealthDataType, enabled: Bool) {
        var types = syncConfiguration.enabledTypes
        if enabled {
            if !types.contains(type) {
                types.append(type)
            }
        } else {
            types.removeAll { $0 == type }
        }
        syncConfiguration.enabledTypes = types
        do {
            try modelContainer.mainContext.save()
        } catch {
            AppLoggers.app.error("保存类型切换失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startServer() async {
        do {
            isServerStarting = true
            defer { isServerStarting = false }

            try await networkServer.start()
            isServerRunning = true
            let snapshot = await networkServer.snapshot()
            serverPort = snapshot.port
            serverFingerprint = snapshot.fingerprint
            AppLoggers.app.info("服务器已启动 - 端口: \(self.serverPort), 指纹: \(self.serverFingerprint.prefix(16), privacy: .public)...")

            let host = await Task.detached(priority: .utility) {
                Self.localIPAddress() ?? "127.0.0.1"
            }.value
            AppLoggers.app.info("解析主机IP: \(host, privacy: .public)")

            // 保存服务器信息（公开访问，无需配对）
            serverInfo = ServerInfo(host: host, port: serverPort, fingerprint: serverFingerprint)

            await auditService.record(eventType: "api.server_start", details: ["port": String(serverPort)])
            // Prevent auto-lock while actively sharing.
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            isServerStarting = false
            lastError = "启动服务器失败: \(error.localizedDescription)"
            AppLoggers.app.error("服务器启动失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopServer() async {
        await networkServer.stop()
        isServerRunning = false
        serverPort = 0
        serverInfo = nil
        await auditService.record(eventType: "api.server_stop", details: [:])
        backgroundTaskController.endIfNeeded()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            backgroundTaskController.endIfNeeded()
        case .background:
            guard isServerRunning else { return }
            // Background tasks are time-limited; this is a best-effort grace period.
            // If the system denies the task, the OS may suspend networking shortly after.
            if !backgroundTaskController.beginIfNeeded() {
                AppLoggers.app.info("后台任务被拒绝，应用挂起时共享可能会暂停")
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    nonisolated private static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer = firstAddr
        while true {
            let interface = pointer.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var addr = interface.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                        let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        address = String(decoding: bytes, as: UTF8.self)
                        break
                    }
                }
            }
            if let next = interface.ifa_next {
                pointer = next
            } else {
                break
            }
        }
        return address
    }

    private func handleProtectedDataAvailable() {
        protectedDataAvailable = true
    }

    private func handleProtectedDataUnavailable() {
        protectedDataAvailable = false
    }

    private func handleAppDidBecomeActive() {
        // Refresh protected data status when app becomes active
        // The initial check in init() may run before UIApplication is ready
        protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable

        // Also refresh HealthKit authorization status
        Task { await refreshHealthAuthorizationStatus() }
    }

    private func refreshHealthAuthorizationStatus() async {
        guard await healthService.isAvailable() else {
            healthAuthorizationStatus = false
            return
        }

        // NOTE: For READ-only permissions, Apple hides whether user granted or denied.
        // We can only check if we've REQUESTED authorization (user saw the dialog).
        // This is Apple's privacy design - apps can't know if health data access was denied.
        healthAuthorizationStatus = await healthService.hasRequestedAuthorization(for: syncConfiguration.enabledTypes)
    }
    
    // MARK: - Health Insights
    
    /// 获取指定健康数据类型的洞察信息
    /// - Parameters:
    ///   - type: 健康数据类型
    ///   - startDate: 开始日期
    ///   - endDate: 结束日期
    /// - Returns: 健康洞察对象，如果无数据则返回 nil
    func fetchInsight(for type: HealthDataType, from startDate: Date, to endDate: Date) async -> HealthInsight? {
        let response = await healthService.fetchSamples(types: [type], startDate: startDate, endDate: endDate, limit: 10000, offset: 0)
        
        guard response.status == .ok, !response.samples.isEmpty else {
            return nil
        }
        
        let values = response.samples.map { $0.value }
        
        // 安全计算平均值，避免除零错误
        guard !values.isEmpty else {
            return nil
        }
        
        let average = values.reduce(0, +) / Double(values.count)
        let total = values.reduce(0, +)
        let min = values.min() ?? 0
        let max = values.max() ?? 0
        
        let category: HealthInsight.Category
        switch type {
        case .steps, .distanceWalkingRunning, .distanceCycling, .activeEnergyBurned, .basalEnergyBurned, .exerciseTime, .standHours, .flightsClimbed, .workouts:
            category = .activity
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .heartRateVariability, .bloodPressureSystolic, .bloodPressureDiastolic, .bloodOxygen, .respiratoryRate, .bodyTemperature, .vo2Max:
            category = .heart
        case .sleepAnalysis, .sleepInBed, .sleepAsleep, .sleepAwake, .sleepREM, .sleepCore, .sleepDeep:
            category = .sleep
        default:
            category = .body
        }
        
        let dataPoints = response.samples.map { sample in
            HealthInsight.DataPoint(date: sample.startDate, value: sample.value)
        }
        
        return HealthInsight(
            type: type.rawValue,
            category: category,
            averageValue: average,
            totalValue: total,
            minValue: min,
            maxValue: max,
            dataPoints: dataPoints
        )
    }
}
