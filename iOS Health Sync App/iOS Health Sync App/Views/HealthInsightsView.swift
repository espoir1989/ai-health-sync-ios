// Copyright 2026 Marcus Neves
// SPDX-License-Identifier: Apache-2.0

import Charts
import HealthKit
import SwiftUI
import SwiftData

/// 健康洞察仪表板视图
struct HealthInsightsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPeriod: TimePeriod = .week
    @State private var insights: [HealthInsight] = []
    @State private var isLoading = false
    
    enum TimePeriod: String, CaseIterable {
        case week = "本周"
        case month = "本月"
        case year = "本年"
        
        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .year: return 365
            }
        }
    }
    
    var body: some View {
        List {
            // 时间段选择
            Picker("时间段", selection: $selectedPeriod) {
                ForEach(TimePeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("加载中...")
                    Spacer()
                }
            } else if insights.isEmpty {
                ContentUnavailableView {
                    Label("暂无数据", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("请确保已授权健康数据访问")
                }
            } else {
                // 活动概览
                Section("活动概览") {
                    activityOverview
                }
                
                // 心脏健康
                Section("心脏健康") {
                    heartHealthOverview
                }
                
                // 睡眠分析
                Section("睡眠分析") {
                    sleepOverview
                }
                
                // 趋势图表
                Section("趋势") {
                    trendCharts
                }
                
                // 健康建议
                Section("健康建议") {
                    healthRecommendations
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("健康洞察")
        .task {
            await loadInsights()
        }
        .onChange(of: selectedPeriod) { _, _ in
            Task { await loadInsights() }
        }
    }
    
    // MARK: - 活动概览
    
    @ViewBuilder
    private var activityOverview: some View {
        let activityInsights = insights.filter { $0.category == .activity }
        
        if let stepsInsight = activityInsights.first(where: { $0.type == "steps" }) {
            LabeledContent("平均步数") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(stepsInsight.averageValue))")
                        .font(.headline)
                    Text("目标: 10,000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // 步数进度条
            ProgressView(value: stepsInsight.averageValue, total: 10000)
                .progressViewStyle(.linear)
                .tint(stepsInsight.averageValue >= 10000 ? .green : .blue)
        }
        
        if let caloriesInsight = activityInsights.first(where: { $0.type == "activeEnergyBurned" }) {
            LabeledContent("活动能量") {
                Text("\(Int(caloriesInsight.averageValue)) 千卡")
                    .font(.headline)
            }
        }
        
        if let distanceInsight = activityInsights.first(where: { $0.type == "distanceWalkingRunning" }) {
            LabeledContent("总距离") {
                Text(String(format: "%.1f 公里", distanceInsight.totalValue / 1000))
                    .font(.headline)
            }
        }
    }
    
    // MARK: - 心脏健康
    
    @ViewBuilder
    private var heartHealthOverview: some View {
        let heartInsights = insights.filter { $0.category == .heart }
        
        if let heartRateInsight = heartInsights.first(where: { $0.type == "heartRate" }) {
            LabeledContent("平均心率") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(heartRateInsight.averageValue)) bpm")
                        .font(.headline)
                    Text("范围: \(Int(heartRateInsight.minValue))-\(Int(heartRateInsight.maxValue))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        
        if let restingHRInsight = heartInsights.first(where: { $0.type == "restingHeartRate" }) {
            LabeledContent("静息心率") {
                Text("\(Int(restingHRInsight.averageValue)) bpm")
                    .font(.headline)
            }
        }
        
        if let hrvInsight = heartInsights.first(where: { $0.type == "heartRateVariability" }) {
            LabeledContent("心率变异性") {
                Text(String(format: "%.1f ms", hrvInsight.averageValue))
                    .font(.headline)
            }
        }
        
        if let bloodOxygenInsight = heartInsights.first(where: { $0.type == "bloodOxygen" }) {
            LabeledContent("血氧饱和度") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f%%", bloodOxygenInsight.averageValue))
                        .font(.headline)
                    if bloodOxygenInsight.averageValue >= 95 {
                        Label("正常", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }
        }
    }
    
    // MARK: - 睡眠分析
    
    @ViewBuilder
    private var sleepOverview: some View {
        let sleepInsights = insights.filter { $0.category == .sleep }
        
        if let sleepInsight = sleepInsights.first(where: { $0.type == "sleepAnalysis" }) {
            let hours = sleepInsight.averageValue / 3600
            LabeledContent("平均睡眠") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f 小时", hours))
                        .font(.headline)
                    if hours >= 7 {
                        Label("充足", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if hours >= 6 {
                        Label("一般", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else {
                        Label("不足", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
        }
    }
    
    // MARK: - 趋势图表
    
    @ViewBuilder
    private var trendCharts: some View {
        if let stepsInsight = insights.first(where: { $0.type == "steps" }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("步数趋势")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Chart(stepsInsight.dataPoints) { point in
                    LineMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value("步数", point.value)
                    )
                    .foregroundStyle(.blue)
                    
                    AreaMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value("步数", point.value)
                    )
                    .foregroundStyle(.blue.opacity(0.2))
                }
                .frame(height: 150)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
            }
        }
        
        if let heartRateInsight = insights.first(where: { $0.type == "heartRate" }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("心率趋势")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Chart(heartRateInsight.dataPoints) { point in
                    LineMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value("心率", point.value)
                    )
                    .foregroundStyle(.red)
                }
                .frame(height: 150)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
            }
        }
    }
    
    // MARK: - 健康建议
    
    @ViewBuilder
    private var healthRecommendations: some View {
        let recommendations = generateRecommendations()
        
        ForEach(recommendations, id: \.self) { recommendation in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 24)
                
                Text(recommendation)
                    .font(.subheadline)
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - 数据加载
    
    private func loadInsights() async {
        isLoading = true
        defer { isLoading = false }
        
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -selectedPeriod.days, to: endDate) ?? endDate
        
        // 获取健康数据洞察
        var loadedInsights: [HealthInsight] = []
        
        let types = appState.syncConfiguration.enabledTypes
        
        for type in types {
            if let insight = await appState.fetchInsight(for: type, from: startDate, to: endDate) {
                loadedInsights.append(insight)
            }
        }
        
        insights = loadedInsights
    }
    
    private func generateRecommendations() -> [String] {
        var recommendations: [String] = []
        
        // 基于步数的建议
        if let stepsInsight = insights.first(where: { $0.type == "steps" }) {
            if stepsInsight.averageValue < 5000 {
                recommendations.append("您的日均步数较低，建议每天至少步行 10,000 步以保持健康。")
            } else if stepsInsight.averageValue >= 10000 {
                recommendations.append("太棒了！您已达到每日步数目标，继续保持！")
            }
        }
        
        // 基于心率的建议
        if let heartRateInsight = insights.first(where: { $0.type == "heartRate" }) {
            if heartRateInsight.averageValue > 100 {
                recommendations.append("您的静息心率偏高，建议增加有氧运动并保持充足睡眠。")
            }
        }
        
        // 基于睡眠的建议
        if let sleepInsight = insights.first(where: { $0.type == "sleepAnalysis" }) {
            let hours = sleepInsight.averageValue / 3600
            if hours < 7 {
                recommendations.append("您的睡眠时间不足，成年人建议每天睡眠 7-9 小时。")
            }
        }
        
        // 基于血氧的建议
        if let bloodOxygenInsight = insights.first(where: { $0.type == "bloodOxygen" }) {
            if bloodOxygenInsight.averageValue < 95 {
                recommendations.append("您的血氧饱和度偏低，建议咨询医生。")
            }
        }
        
        if recommendations.isEmpty {
            recommendations.append("继续保持健康的生活方式！")
        }
        
        return recommendations
    }
}

// MARK: - 数据模型

struct HealthInsight {
    let type: String
    let category: Category
    let averageValue: Double
    let totalValue: Double
    let minValue: Double
    let maxValue: Double
    let dataPoints: [DataPoint]
    
    enum Category {
        case activity
        case heart
        case sleep
        case body
    }
    
    struct DataPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
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
    
    return NavigationStack {
        HealthInsightsView()
    }
    .environment(state)
    .modelContainer(container)
}
