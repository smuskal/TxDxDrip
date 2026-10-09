//
//  TxDBridgeModel.swift
//  TxD xDrip — thin bridge front-end over the xDrip4iOS engine.
//
//  Drives the whole setup the way a user would otherwise do by hand:
//    1. defaults: Master mode, mg/dL
//    2. Apple Health write permission (the only bridge to Food Health TxD)
//    3. add "Dexcom G7/ONE+/Stelo" in Coexistence mode and scan
//    4. status: connection, last reading, Health writes
//  Everything below calls the same engine code the full UI uses; nothing in
//  the transmitter / Core Data / HealthKit layers is touched.
//

import Foundation
import SwiftUI
import HealthKit
import Combine

@MainActor
final class TxDBridgeModel: ObservableObject {

    enum Step: Int { case welcome, health, connect, status }

    @Published private(set) var step: Step = .welcome
    @Published private(set) var healthAuthorized = false
    @Published private(set) var healthDenied = false
    @Published private(set) var connectionStatus: BluetoothPeripheralDisplayStatus = .notScanning
    @Published private(set) var deviceName: String?
    @Published private(set) var scanStartedAt: Date?
    @Published private(set) var lastReadingValue: Double?
    @Published private(set) var lastReadingDate: Date?
    @Published private(set) var lastHealthWrite: Date?
    @Published private(set) var readingsLast24h = 0
    /// Last 24 h of readings for the status chart (oldest first).
    @Published private(set) var chartPoints: [ChartPoint] = []

    struct ChartPoint: Identifiable { let id = UUID(); let date: Date; let mgdl: Double }
    @Published private(set) var dependenciesReady = false
    @Published var showAdvanced = false

    private var dependencies: RootTabDependencies?
    private var detailState: BluetoothPeripheralDetailState?
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    static let useOtherAppDefault = true   // Coexistence: Stelo app keeps the sensor

    /// `-txd.demo` launch argument: synthetic status + readings for App Store
    /// screenshots on the simulator (no sensor, no Apple Health writes).
    static let isDemo = ProcessInfo.processInfo.arguments.contains("-txd.demo")

    func enterDemo(step: Step) {
        dependenciesReady = true
        self.step = step
        healthAuthorized = step.rawValue >= Step.connect.rawValue
        deviceName = "DX01AB"
        connectionStatus = .waitingForNextReading
        lastHealthWrite = Date().addingTimeInterval(-120)
        var pts: [ChartPoint] = []
        let now = Date()
        for i in stride(from: 24 * 12, through: 0, by: -1) {
            let t = now.addingTimeInterval(-Double(i) * 300)
            let h = Double(i) / 12
            // Calm, in-range day: ~90–105 with two gentle post-meal bumps.
            let base = 95 + 4 * sin(h / 24 * 2 * .pi) + 7 * max(0, sin((h - 3) / 2 * .pi)) + 8 * max(0, sin((h - 10) / 2.5 * .pi))
            pts.append(ChartPoint(date: t, mgdl: (base + Double((i * 37) % 5) - 2).rounded()))
        }
        chartPoints = pts
        lastReadingValue = pts.last?.mgdl
        lastReadingDate = pts.last?.date
        readingsLast24h = pts.count
        if step == .connect { scanStartedAt = Date().addingTimeInterval(-83); connectionStatus = .discovering }
    }

    // MARK: - Wiring

    func attach(dependencies: RootTabDependencies) {
        guard self.dependencies == nil else { return }
        if Self.isDemo {
            let s = ProcessInfo.processInfo.environment["TXD_DEMO_STEP"].flatMap(Int.init).flatMap(Step.init(rawValue:)) ?? .status
            enterDemo(step: s); return
        }
        self.dependencies = dependencies
        dependenciesReady = true
        applyDefaults()
        refreshHealthStatus()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        // Resume where the user left off.
        if hasDevice {
            step = .status
            adoptExistingDevice()
        } else if healthAuthorized {
            step = .connect
        }
    }

    private func applyDefaults() {
        let d = UserDefaults.standard
        if !d.isMaster { d.isMaster = true }
        if !d.bloodGlucoseUnitIsMgDl { d.bloodGlucoseUnitIsMgDl = true }
        if !d.storeReadingsInHealthkit { d.storeReadingsInHealthkit = true }
    }

    var hasDevice: Bool {
        dependencies?.bluetoothPeripheralManager.getBluetoothPeripherals().contains { $0 is DexcomG7 } ?? false
    }

    // MARK: - Steps

    func next() {
        switch step {
        case .welcome: step = .health
        case .health:  step = .connect
        case .connect: step = .status
        case .status:  break
        }
    }

    // MARK: - Apple Health

    func requestHealthAccess() {
        guard let type = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else { return }
        let store = HKHealthStore()
        UserDefaults.standard.storeReadingsInHealthkit = true
        switch store.authorizationStatus(for: type) {
        case .sharingAuthorized:
            UserDefaults.standard.storeReadingsInHealthkitAuthorized = true
            healthAuthorized = true
            next()
        case .sharingDenied:
            healthDenied = true
        default:
            store.requestAuthorization(toShare: [type], read: nil) { [weak self] ok, _ in
                Task { @MainActor in
                    UserDefaults.standard.storeReadingsInHealthkitAuthorized = ok
                    self?.healthAuthorized = ok
                    self?.healthDenied = !ok
                    if ok { self?.next() }
                }
            }
        }
    }

    func refreshHealthStatus() {
        guard let type = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else { return }
        let status = HKHealthStore().authorizationStatus(for: type)
        healthAuthorized = status == .sharingAuthorized
        healthDenied = status == .sharingDenied
        if healthAuthorized { UserDefaults.standard.storeReadingsInHealthkitAuthorized = true }
    }

    // MARK: - Connect (coexistence)

    func startScan() {
        guard let deps = dependencies, !isScanning else { return }
        let state = BluetoothPeripheralDetailState(
            bluetoothPeripheral: nil,
            expectedBluetoothPeripheralType: .DexcomG7Type,
            dexcomConfiguration: DexcomAddConfiguration(useOtherApp: Self.useOtherAppDefault, transmitterID: nil),
            coreDataManager: deps.coreDataManager,
            bluetoothPeripheralManager: deps.bluetoothPeripheralManager,
            sensorProvider: nil,
            closeDetailView: {},
            presentTextEntryView: { _ in },
            presentSelectionListView: { _ in },
            presentReadSuccessView: { _, _ in },
            presentBatteryHistoryView: { _ in },
            presentSignalStrengthView: { _ in }
        )
        // Blank id → G7 placeholder ("DX0000"); the real name is adopted after discovery.
        state.txdSetTransmitterId("")
        state.$connectionStatus.receive(on: RunLoop.main).sink { [weak self] s in self?.connectionStatus = s }.store(in: &cancellables)
        state.pendingAlert = nil
        detailState = state
        scanStartedAt = Date()
        state.txdBeginScan(type: .DexcomG7Type)
        // The engine's informational alert ("keep the app open…") is not needed here.
        state.$pendingAlert.receive(on: RunLoop.main).sink { alert in if alert != nil { state.pendingAlert = nil } }.store(in: &cancellables)
    }

    func stopScan() {
        dependencies?.bluetoothPeripheralManager.stopScanningForNewDevice()
        scanStartedAt = nil
        connectionStatus = .notScanning
    }

    /// After a relaunch the device already exists; make sure it is enabled.
    private func adoptExistingDevice() {
        guard let deps = dependencies,
              let g7 = deps.bluetoothPeripheralManager.getBluetoothPeripherals().first(where: { $0 is DexcomG7 }) else { return }
        deps.bluetoothPeripheralManager.setConnectionEnabled(true, for: g7)
        deviceName = g7.blePeripheral.name
    }

    var isScanning: Bool { Self.isDemo ? step == .connect : (dependencies?.bluetoothPeripheralManager.isScanning() ?? false) }

    // MARK: - Status

    func refreshStatus() {
        if Self.isDemo { return }
        guard let deps = dependencies else { return }
        refreshHealthStatus()
        if let g7 = deps.bluetoothPeripheralManager.getBluetoothPeripherals().first(where: { $0 is DexcomG7 }) {
            deviceName = g7.blePeripheral.name
            let t = deps.bluetoothPeripheralManager.getBluetoothTransmitter(for: g7, createANewOneIfNecesssary: false)
            if !isScanning {
                connectionStatus = BluetoothPeripheralDisplayStatus(bluetoothTransmitter: t, bluetoothPeripheral: g7)
            }
            if step == .connect { step = .status }
        }
        let readings = deps.bgReadingsAccessor.getLatestBgReadings(limit: 1, howOld: 1, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
        lastReadingValue = readings.first?.calculatedValue
        lastReadingDate = readings.first?.timeStamp
        let day = deps.bgReadingsAccessor.getLatestBgReadings(limit: nil, howOld: 1, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
        readingsLast24h = day.count
        chartPoints = day.filter { $0.calculatedValue > 20 }.map { ChartPoint(date: $0.timeStamp, mgdl: $0.calculatedValue) }.sorted { $0.date < $1.date }
        lastHealthWrite = UserDefaults.standard.timeStampLatestHealthKitStoreBgReading
    }

    func forgetDevice() {
        guard let deps = dependencies else { return }
        for p in deps.bluetoothPeripheralManager.getBluetoothPeripherals() where p is DexcomG7 {
            deps.bluetoothPeripheralManager.deleteBluetoothPeripheral(bluetoothPeripheral: p)
        }
        detailState = nil
        deviceName = nil
        connectionStatus = .notScanning
        step = .connect
    }
}
