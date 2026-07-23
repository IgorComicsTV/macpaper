import Combine
import Foundation
import IOKit.ps

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var isOnBattery = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return }
        isOnBattery = type == (kIOPSBatteryPowerValue as String)
    }
}
