//
//  TxDSimpleRootView.swift
//  TxD xDrip — wizard + status front-end. Replaces the five-tab UI when
//  "txdSimpleMode" is on (default in this fork). "Advanced" shows the full
//  xDrip4iOS interface for troubleshooting; the engine is shared.
//

import SwiftUI
import Charts

struct TxDSimpleRootView: View {

    @ObservedObject var stateModel: RootTabStateModel
    let applicationCoordinator: RootApplicationCoordinator
    let tabTitles: RootTabTitles
    @StateObject private var model = TxDBridgeModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var chartHours = 6
    @State private var confirmForget = false

    var body: some View {
        Group {
            if model.showAdvanced {
                RootTabView(stateModel: stateModel, applicationCoordinator: applicationCoordinator, tabTitles: tabTitles)
                    .overlay(alignment: .topTrailing) {
                        Button("Simple") { model.showAdvanced = false }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                            .padding(.top, 4).padding(.trailing, 70)
                    }
            } else {
                wizard
            }
        }
        .onChange(of: stateModel.dependencies?.coreDataManager === nil) { _ in attachIfReady() }
        .onAppear(perform: attachIfReady)
        .onChange(of: scenePhase) { if $0 == .active { model.refreshStatus() } }
        .preferredColorScheme(.dark)
    }

    private func attachIfReady() {
        if let deps = stateModel.dependencies { model.attach(dependencies: deps) }
    }

    // MARK: - Wizard

    private var wizard: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.dependenciesReady {
                        ProgressView("Starting…").frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        switch model.step {
                        case .welcome: welcome
                        case .health:  health
                        case .connect: connect
                        case .status:  status
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            footer
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundColor(.white)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("TxD xDrip").font(.title3.weight(.bold))
                Text("Stelo → Apple Health, in real time").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            stepDots
        }
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 2)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4) { i in
                Circle().fill(i <= model.step.rawValue ? Color.accentColor : Color.white.opacity(0.2)).frame(width: 8, height: 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Advanced") { model.showAdvanced = true }
                .font(.footnote).foregroundColor(.secondary)
            Spacer()
            Text("xDrip4iOS engine · GPL-3").font(.footnote).foregroundColor(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 4)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Three steps").font(.title.weight(.semibold))
            bullet("1", "Allow writing glucose to Apple Health.")
            bullet("2", "Connect to your Stelo. The Stelo app stays in charge; this app only listens.")
            bullet("3", "Leave this app installed. Readings land in Apple Health every ~5 minutes, and Food Health TxD reads them from there.")
            Text("Keep the Stelo app on your phone and don't force-quit it. Nothing here replaces it.")
                .font(.footnote).foregroundColor(.secondary)
            primary("Start") { model.next() }
        }
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apple Health").font(.title.weight(.semibold))
            Text("Tap Allow, then turn on **Blood Glucose** in the sheet that appears. This is how readings reach Food Health TxD.")
            if model.healthAuthorized {
                Label("Writing to Apple Health is allowed", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                primary("Continue") { model.next() }
            } else if model.healthDenied {
                Label("Permission is off", systemImage: "xmark.octagon.fill").foregroundColor(.orange)
                Text("Open iPhone Settings ▸ Health ▸ Data Access & Devices ▸ TxD xDrip and turn on Blood Glucose, then come back.")
                    .font(.footnote).foregroundColor(.secondary)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url).font(.headline)
                }
                primary("I turned it on") { model.refreshHealthStatus(); if model.healthAuthorized { model.next() } }
            } else {
                primary("Allow Apple Health") { model.requestHealthAccess() }
            }
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Stelo").font(.title.weight(.semibold))
            bullet("•", "Open the Stelo app once and confirm it shows a current reading. Then come back here.")
            bullet("•", "Tap Connect and leave this screen open. The sensor only talks every ~5 minutes, so the first connection can take up to 6 minutes.")
            if model.isScanning || model.connectionStatus == .discovering || model.connectionStatus == .connecting {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text("Listening for your Stelo…").font(.headline)
                        if let t = model.scanStartedAt {
                            TimelineView(.periodic(from: t, by: 1)) { ctx in
                                Text("\(Int(ctx.date.timeIntervalSince(t)) / 60):\(String(format: "%02d", Int(ctx.date.timeIntervalSince(t)) % 60)) elapsed · keep this screen open")
                                    .font(.footnote).foregroundColor(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                .padding().background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                Button("Stop") { model.stopScan() }.foregroundColor(.secondary)
            } else {
                primary("Connect") { model.startScan() }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            card {
                row("Sensor", model.deviceName ?? "Stelo", symbol: "sensor.tag.radiowaves.forward.fill")
                row("Connection", statusText, symbol: "antenna.radiowaves.left.and.right", color: statusColor)
                row("Last reading", lastReadingText, symbol: "drop.fill")
                row("Readings, 24 h", "\(model.readingsLast24h)", symbol: "chart.xyaxis.line")
                row("Apple Health", model.healthAuthorized ? (model.lastHealthWrite.map { "written \(rel($0))" } ?? "allowed · waiting for first reading") : "NOT allowed", symbol: "heart.fill", color: model.healthAuthorized ? .green : .orange)
            }
            glucoseChart
            HStack {
                Button("Refresh") { model.refreshStatus() }
                Spacer()
                Text("Keep this app installed; don't force-quit the Stelo app.").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button("Forget sensor…", role: .destructive) { confirmForget = true }
            }
            .font(.footnote)
            .confirmationDialog("Forget this sensor?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget sensor", role: .destructive) { model.forgetDevice() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Readings stop until you connect again. The Stelo app is not affected.")
            }
        }
    }

    // MARK: Chart

    private var visiblePoints: [TxDBridgeModel.ChartPoint] {
        let cutoff = Date().addingTimeInterval(-Double(chartHours) * 3600)
        return model.chartPoints.filter { $0.date >= cutoff }
    }

    private var glucoseChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Glucose · green band 70–180").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Hours", selection: $chartHours) {
                    Text("3 h").tag(3); Text("6 h").tag(6); Text("12 h").tag(12); Text("24 h").tag(24)
                }
                .pickerStyle(.segmented).frame(width: 190)
            }
            if visiblePoints.isEmpty {
                Text("No readings in this window yet.").font(.footnote).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                let lo = Date().addingTimeInterval(-Double(chartHours) * 3600)
                Chart {
                    // Target band 70–180 mg/dL
                    RectangleMark(xStart: .value("t0", lo), xEnd: .value("t1", Date()), yStart: .value("lo", 70), yEnd: .value("hi", 180))
                        .foregroundStyle(Color.green.opacity(0.10))
                    ForEach(visiblePoints) { p in
                        LineMark(x: .value("Time", p.date), y: .value("mg/dL", p.mgdl))
                            .foregroundStyle(Color(red: 0.75, green: 0.35, blue: 0.95))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Time", p.date), y: .value("mg/dL", p.mgdl))
                            .foregroundStyle(p.mgdl < 70 ? Color.red : p.mgdl > 180 ? Color.orange : Color(red: 0.75, green: 0.35, blue: 0.95))
                            .symbolSize(chartHours <= 6 ? 22 : 10)
                    }
                    if let last = visiblePoints.last {
                        PointMark(x: .value("Time", last.date), y: .value("mg/dL", last.mgdl))
                            .foregroundStyle(.white).symbolSize(60)
                            .annotation(position: .top) {
                                Text("\(Int(last.mgdl.rounded()))").font(.caption.weight(.bold)).foregroundColor(.white)
                            }
                    }
                }
                .chartXScale(domain: lo...Date())
                .chartYScale(domain: 40...max(250, (visiblePoints.map(\.mgdl).max() ?? 0) + 20))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: chartHours <= 6 ? 6 : 6)) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated))).foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [40, 70, 100, 140, 180, 250]) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel().foregroundStyle(.secondary)
                    }
                }
                .frame(height: 440)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
    }

    // MARK: Bits

    private var statusText: String {
        switch model.connectionStatus {
        case .notScanning: return model.isScanning ? "listening…" : "idle"
        case .discovering: return "listening…"
        case .connecting: return "connecting…"
        case .reconnecting: return "reconnecting…"
        case .waitingForNextReading: return "waiting for next reading"
        case .connected: return "connected"
        }
    }

    private var statusColor: Color {
        switch model.connectionStatus {
        case .connected, .waitingForNextReading: return .green
        case .notScanning: return .secondary
        default: return .yellow
        }
    }

    private var lastReadingText: String {
        guard let v = model.lastReadingValue, let d = model.lastReadingDate else { return "none yet" }
        return "\(Int(v.rounded())) mg/dL · \(rel(d))"
    }

    private func rel(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    private func bullet(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.headline).foregroundColor(.accentColor).frame(width: 18, alignment: .trailing)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor)).foregroundColor(.white)
        }
        .padding(.top, 8)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
    }

    private func row(_ label: String, _ value: String, symbol: String, color: Color = .white) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundColor(color).frame(width: 22)
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).foregroundColor(color)
        }
        .font(.footnote)
    }
}
