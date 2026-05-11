import Foundation
import HealthKit

protocol HealthKitServiceDelegate: AnyObject {
    func healthKitDidUpdate(_ summary: HealthSummary)
    func healthKitError(_ error: Error)
}

struct HealthSummary: Codable {
    var heartRate: Double?
    var bloodOxygen: Double?
    var steps: Int?
    var hrv: Double?
    var sleepHours: Double?
    var lastUpdated: Date

    var dictionary: [String: Any] {
        var dict: [String: Any] = ["last_updated": ISO8601DateFormatter().string(from: lastUpdated)]
        if let hr = heartRate { dict["heart_rate_bpm"] = hr }
        if let spo2 = bloodOxygen { dict["blood_oxygen_percent"] = spo2 }
        if let s = steps { dict["steps_today"] = s }
        if let h = hrv { dict["hrv_ms"] = h }
        if let sl = sleepHours { dict["sleep_hours"] = sl }
        return dict
    }
}

class HealthKitService {
    weak var delegate: HealthKitServiceDelegate?

    private let healthStore = HKHealthStore()
    private var updateTimer: Timer?
    private(set) var latestSummary: HealthSummary?
    private(set) var isAuthorized = false

    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        if let spo2 = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) { types.insert(spo2) }
        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
        if let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        return types
    }()

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            delegate?.healthKitError(HealthKitError.notAvailable)
            return
        }

        healthStore.requestAuthorization(toShare: nil, read: readTypes) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.isAuthorized = true
                    self?.startPeriodicUpdates()
                } else if let error = error {
                    self?.delegate?.healthKitError(error)
                }
            }
        }
    }

    func startPeriodicUpdates(interval: TimeInterval = 60) {
        stopPeriodicUpdates()
        fetchAllData()
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchAllData()
        }
    }

    func stopPeriodicUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func fetchAllData() {
        let group = DispatchGroup()
        var heartRate: Double?
        var bloodOxygen: Double?
        var steps: Int?
        var hrv: Double?
        var sleepHours: Double?

        group.enter()
        fetchLatestQuantity(.heartRate, unit: HKUnit.count().unitDivided(by: .minute())) { value in
            heartRate = value
            group.leave()
        }

        group.enter()
        fetchLatestQuantity(.oxygenSaturation, unit: HKUnit.percent()) { value in
            bloodOxygen = value.map { $0 * 100 }
            group.leave()
        }

        group.enter()
        fetchTodaySum(.stepCount, unit: HKUnit.count()) { value in
            steps = value.map { Int($0) }
            group.leave()
        }

        group.enter()
        fetchLatestQuantity(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli)) { value in
            hrv = value
            group.leave()
        }

        group.enter()
        fetchLastNightSleep { hours in
            sleepHours = hours
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            let summary = HealthSummary(
                heartRate: heartRate,
                bloodOxygen: bloodOxygen,
                steps: steps,
                hrv: hrv,
                sleepHours: sleepHours,
                lastUpdated: Date()
            )
            self?.latestSummary = summary
            self?.delegate?.healthKitDidUpdate(summary)
        }
    }

    // MARK: - Private Queries

    private func fetchLatestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, completion: @escaping (Double?) -> Void) {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(nil)
            return
        }

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: quantityType, predicate: nil, limit: 1, sortDescriptors: [sortDescriptor]) { _, samples, _ in
            let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
            completion(value)
        }
        healthStore.execute(query)
    }

    private func fetchTodaySum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, completion: @escaping (Double?) -> Void) {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(nil)
            return
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)

        let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, _ in
            let value = result?.sumQuantity()?.doubleValue(for: unit)
            completion(value)
        }
        healthStore.execute(query)
    }

    private func fetchLastNightSleep(completion: @escaping (Double?) -> Void) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(nil)
            return
        }

        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let predicate = HKQuery.predicateForSamples(withStart: yesterday, end: now, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, samples, _ in
            guard let samples = samples as? [HKCategorySample] else {
                completion(nil)
                return
            }

            let asleepSamples = samples.filter { sample in
                sample.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
                sample.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue ||
                sample.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue ||
                sample.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
            }

            let totalSeconds = asleepSamples.reduce(0.0) { sum, sample in
                sum + sample.endDate.timeIntervalSince(sample.startDate)
            }
            let hours = totalSeconds / 3600.0
            completion(hours > 0 ? hours : nil)
        }
        healthStore.execute(query)
    }
}

enum HealthKitError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "HealthKit is not available on this device"
        }
    }
}
