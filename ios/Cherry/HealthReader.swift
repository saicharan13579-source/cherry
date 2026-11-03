import Foundation
import HealthKit

/// Reads Apple Health and returns the same JSON shape the Android Health Connect reader produces.
final class HealthReader {
    let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        let q: [HKQuantityTypeIdentifier] = [.stepCount, .activeEnergyBurned, .appleExerciseTime, .heartRate, .restingHeartRate, .dietaryWater, .bodyMass]
        for id in q { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sl = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sl) }
        return s
    }

    func grantedList() -> String {
        guard HKHealthStore.isHealthDataAvailable() else { return "" }
        return UserDefaults.standard.bool(forKey: "hcAsked") ? "READ_STEPS,READ_SLEEP,READ_WEIGHT,READ_HEART_RATE,READ_RESTING_HEART_RATE,READ_ACTIVE_CALORIES_BURNED,READ_EXERCISE,READ_HYDRATION" : ""
    }

    func requestAccess(_ done: @escaping (String) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { DispatchQueue.main.async { done("") }; return }
        store.requestAuthorization(toShare: nil, read: readTypes) { ok, _ in
            if ok { UserDefaults.standard.set(true, forKey: "hcAsked") }
            DispatchQueue.main.async { done(self.grantedList()) }
        }
    }

    func read(days: Int, _ done: @escaping (String) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { done("{\"ok\":false,\"error\":\"nohc\"}"); return }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -(days - 1), to: todayStart)!
        let to = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let group = DispatchGroup()
        let lock = NSLock()
        var parts: [String] = []
        func add(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }

        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.calendar = Calendar(identifier: .gregorian)
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        func daily(_ id: HKQuantityTypeIdentifier, _ key: String, cumulative: Bool, unit: HKUnit, scale: Double) {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
            group.enter()
            let q = HKStatisticsCollectionQuery(quantityType: type,
                                                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: from, end: to),
                                                options: cumulative ? .cumulativeSum : .discreteAverage,
                                                anchorDate: from, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, res, err in
                var items: [String] = []
                res?.enumerateStatistics(from: from, to: to) { st, _ in
                    let qty = cumulative ? st.sumQuantity() : st.averageQuantity()
                    if let v = qty?.doubleValue(for: unit) {
                        let x = (v * scale * 100).rounded() / 100
                        items.append("\"\(df.string(from: st.startDate))\":\(x)")
                    }
                }
                if res == nil, err != nil { add("\"\(key)Err\":\"no access\"") }
                add("\"\(key)\":{\(items.joined(separator: ","))}")
                group.leave()
            }
            store.execute(q)
        }

        daily(.stepCount, "steps", cumulative: true, unit: .count(), scale: 1)
        daily(.activeEnergyBurned, "kcal", cumulative: true, unit: .kilocalorie(), scale: 1)
        daily(.appleExerciseTime, "exMs", cumulative: true, unit: .minute(), scale: 60000)
        daily(.heartRate, "hr", cumulative: false, unit: HKUnit.count().unitDivided(by: .minute()), scale: 1)
        daily(.restingHeartRate, "rhr", cumulative: false, unit: HKUnit.count().unitDivided(by: .minute()), scale: 1)
        daily(.dietaryWater, "water", cumulative: true, unit: .liter(), scale: 1)

        // Sleep: join "asleep" samples into nights (gaps under 90 min belong to the same night).
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            group.enter()
            let sFrom = cal.date(byAdding: .day, value: -1, to: from)!
            let q = HKSampleQuery(sampleType: sleepType, predicate: HKQuery.predicateForSamples(withStart: sFrom, end: Date()),
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                var asleep: [(Date, Date)] = []
                for s in (samples as? [HKCategorySample]) ?? [] {
                    let inBed = HKCategoryValueSleepAnalysis.inBed.rawValue
                    var awake = -1
                    if #available(iOS 16.0, *) { awake = HKCategoryValueSleepAnalysis.awake.rawValue }
                    if s.value != inBed && s.value != awake { asleep.append((s.startDate, s.endDate)) }
                }
                if asleep.isEmpty {
                    for s in (samples as? [HKCategorySample]) ?? [] { asleep.append((s.startDate, s.endDate)) }
                }
                var nights: [(Date, Date)] = []
                for a in asleep {
                    if var last = nights.last, a.0.timeIntervalSince(last.1) < 90 * 60 {
                        last.1 = max(last.1, a.1); nights[nights.count - 1] = last
                    } else { nights.append(a) }
                }
                let items = nights.map { "[\"\(tf.string(from: $0.0))\",\"\(tf.string(from: $0.1))\"]" }
                add("\"sleep\":[\(items.joined(separator: ","))]")
                group.leave()
            }
            store.execute(q)
        }

        if let wType = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            group.enter()
            let q = HKSampleQuery(sampleType: wType, predicate: HKQuery.predicateForSamples(withStart: from, end: Date()),
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                let items: [String] = ((samples as? [HKQuantitySample]) ?? []).map {
                    let kg = ($0.quantity.doubleValue(for: .gramUnit(with: .kilo)) * 10).rounded() / 10
                    return "[\"\(tf.string(from: $0.startDate))\",\(kg)]"
                }
                add("\"weight\":[\(items.joined(separator: ","))]")
                group.leave()
            }
            store.execute(q)
        }

        group.notify(queue: .main) {
            let granted = self.grantedList()
            done("{\"ok\":true,\"granted\":\"\(granted)\"," + parts.joined(separator: ",") + "}")
        }
    }
}
