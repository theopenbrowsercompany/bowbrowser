import Darwin
import Foundation

// Machine side readings of the opt-in hidden tab measurement (E2E/Tests/S3.swift): the app's processes and their
// kernel resource usage, Activity Monitor's energy figure through `top`, and the load average. Results are plain
// JSON values for s3.json.

/// The app's own process and every child (Chromium's helpers), each with its kind and kernel usage.
@MainActor
enum E2ES3Processes {
    struct Reading {
        var pid: Int32
        /// browser, renderer, gpu, network, audio, storage, utility or other.
        var kind: String
        var usage: BowS3ProcessUsage
    }

    /// Every process now, keyed by pid. A process that ends while it is read is left out.
    static func snapshot() -> [Int32: Reading] {
        var readings: [Int32: Reading] = [:]
        let me = getpid()
        if let usage = BowS3Probe.usage(ofProcess: me) {
            readings[me] = Reading(pid: me, kind: "browser", usage: usage)
        }
        for child in BowChildProcess.childrenOfCurrentProcess() {
            guard let usage = BowS3Probe.usage(ofProcess: child.pid) else { continue }
            readings[child.pid] = Reading(pid: child.pid, kind: kind(of: child.arguments), usage: usage)
        }
        return readings
    }

    static func kind(of arguments: [String]) -> String {
        let type = arguments.first { $0.hasPrefix("--type=") }.map { String($0.dropFirst("--type=".count)) }
        switch type {
        case "renderer": return "renderer"
        case "gpu-process": return "gpu"
        case "utility":
            let sub = arguments.first { $0.hasPrefix("--utility-sub-type=") } ?? ""
            if sub.contains("network") { return "network" }
            if sub.contains("audio") { return "audio" }
            if sub.contains("storage") { return "storage" }
            return "utility"
        default: return "other"
        }
    }

    /// Per process rates between two snapshots `seconds` apart, for processes in both, highest CPU first: CPU in
    /// percent of one core, package idle and interrupt wakeups per second, billed energy in milliwatts, footprint in
    /// MB at the end, and the share of CPU time spent at background quality of service.
    static func rates(from start: [Int32: Reading], to end: [Int32: Reading], seconds: Double) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for (pid, last) in end {
            guard let first = start[pid], seconds > 0 else { continue }
            let cpu = Double(last.usage.cpuNanoseconds &- first.usage.cpuNanoseconds)
            let qos = zip(last.usage.qosNanoseconds, first.usage.qosNanoseconds).map {
                Double($0.uint64Value &- $1.uint64Value)
            }
            let qosTotal = qos.reduce(0, +)
            rows.append([
                "pid": Int(pid),
                "kind": last.kind,
                "cpuPercent": round2(cpu / seconds / 1e7),
                "idleWakeupsPerSecond": round2(
                    Double(last.usage.packageIdleWakeups &- first.usage.packageIdleWakeups) / seconds),
                "interruptWakeupsPerSecond": round2(
                    Double(last.usage.interruptWakeups &- first.usage.interruptWakeups) / seconds),
                "energyMilliwatts": round2(
                    Double(last.usage.billedEnergyNanojoules &- first.usage.billedEnergyNanojoules) / seconds / 1e6),
                "footprintMB": round2(Double(last.usage.physicalFootprint) / 1_048_576),
                "backgroundQosShare": qosTotal > 0 ? round2((qos[2] + qos[1]) / qosTotal) : 0,
            ])
        }
        return rows.sorted { ($0["cpuPercent"] as? Double ?? 0) > ($1["cpuPercent"] as? Double ?? 0) }
    }

    /// The rows of `rates` summed per kind, with a process count.
    static func totals(_ rows: [[String: Any]]) -> [String: Any] {
        var totals: [String: [String: Double]] = [:]
        for row in rows {
            guard let kind = row["kind"] as? String else { continue }
            var total = totals[kind] ?? [:]
            total["processes", default: 0] += 1
            for key in ["cpuPercent", "idleWakeupsPerSecond", "interruptWakeupsPerSecond", "energyMilliwatts",
                "footprintMB"]
            {
                total[key, default: 0] += row[key] as? Double ?? 0
            }
            totals[kind] = total.mapValues(round2)
        }
        return totals
    }
}

/// `top`'s figures for the app's processes, read while a pass measures: CPU, idle wakeups and the POWER column,
/// which is the score Activity Monitor shows as Energy Impact. It needs no root, unlike powermetrics.
@MainActor
final class E2ES3Top {
    private let process = Process()
    private let pipe = Pipe()
    private var result: Result<String, E2EError>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Starts `top -l <samples> -s <interval>` limited to `pids`; it ends on its own after
    /// `(samples - 1) × interval` seconds.
    init(pids: [Int32], samples: Int, interval: Int) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments =
            ["-l", String(samples), "-s", String(interval), "-stats", "pid,command,cpu,idlew,power"]
            + pids.flatMap { ["-pid", String($0)] }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            result = .failure(E2EError("top did not start: \(error.localizedDescription)"))
            return
        }
        // Reads everything top writes until it closes its output, so a full pipe never stalls it, then waits for it
        // to exit.
        let running = E2ES3Running(process: process, reader: pipe.fileHandleForReading)
        DispatchQueue.global(qos: .utility).async {
            let text = String(decoding: running.reader.readDataToEndOfFile(), as: UTF8.self)
            running.process.waitUntilExit()
            let status = running.process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finish(status == 0 ? .success(text) : .failure(E2EError("top exited with \(status)")))
                }
            }
        }
    }

    /// Waits for top to end and returns its rows (pid, command, cpu, idleWakeups, power, each the mean over every
    /// sample but the first, which only sets top's baseline), or an error naming why there are none. A cancelled
    /// wait (the test ran out of time) stops top.
    func rows() async -> [String: Any] {
        if result == nil {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters.append($0) }
            } onCancel: {
                Task { @MainActor in self.stop() }
            }
        }
        switch result {
        case .success(let text): return ["rows": Self.parse(text)]
        case .failure(let error): return ["error": error.description]
        case nil: return ["error": "top did not finish"]
        }
    }

    /// Ends top early (a pass that failed or a test that ended), so nothing outlives the test.
    func stop() {
        if process.isRunning { process.terminate() }
        finish(.failure(E2EError("top was stopped")))
    }

    private func finish(_ outcome: Result<String, E2EError>) {
        if result == nil { result = outcome }
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
    }

    /// Each process's figures averaged over every sample after the first (each sample's rows follow a
    /// `PID COMMAND` header), with how many samples it appeared in, highest power first.
    static func parse(_ text: String) -> [[String: Any]] {
        let lines = text.components(separatedBy: "\n")
        let headers = lines.indices.filter { lines[$0].hasPrefix("PID") && lines[$0].contains("POWER") }
        var sums: [Int: (command: String, cpu: Double, idle: Double, power: Double, samples: Int)] = [:]
        for (number, header) in headers.enumerated() where number > 0 || headers.count == 1 {
            let end = number + 1 < headers.count ? headers[number + 1] : lines.count
            for row in rows(lines[(header + 1)..<end]) {
                var sum = sums[row.pid] ?? (row.command, 0, 0, 0, 0)
                sum.cpu += row.cpu
                sum.idle += row.idle
                sum.power += row.power
                sum.samples += 1
                sums[row.pid] = sum
            }
        }
        return sums.map { pid, sum in
            let count = Double(sum.samples)
            return [
                "pid": pid, "command": sum.command, "samples": sum.samples,
                "cpuPercent": round2(sum.cpu / count), "idleWakeups": round2(sum.idle / count),
                "power": round2(sum.power / count),
            ]
        }.sorted { ($0["power"] as? Double ?? 0) > ($1["power"] as? Double ?? 0) }
    }

    /// One sample's rows. COMMAND may hold spaces, so the numbers are read from the end.
    private static func rows(_ lines: ArraySlice<String>) -> [(
        pid: Int, command: String, cpu: Double, idle: Double, power: Double
    )] {
        lines.compactMap { line in
            // top marks a figure that changed since its last sample with a trailing + or - (`202999+`).
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map {
                String($0).trimmingCharacters(in: CharacterSet(charactersIn: "+-*"))
            }
            guard fields.count >= 5, let pid = Int(fields[0]), let power = Double(fields[fields.count - 1]),
                let idle = Double(fields[fields.count - 2]), let cpu = Double(fields[fields.count - 3])
            else { return nil }
            let command = fields[1..<(fields.count - 3)].joined(separator: " ")
            return (pid, command, cpu, idle, power)
        }
    }
}

/// The running top and its output, handed to the thread that reads it; only that thread uses them after the start
/// (`stop` only sends a signal).
private struct E2ES3Running: @unchecked Sendable {
    let process: Process
    let reader: FileHandle
}

/// The 1, 5 and 15 minute load averages.
func e2eS3LoadAverage() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    let count = getloadavg(&loads, 3)
    return count == 3 ? loads.map(round2) : []
}

/// Mean and 95th percentile of `values`, rounded; zeros for none.
func e2eS3Stats(_ values: [Double]) -> (mean: Double, p95: Double) {
    guard !values.isEmpty else { return (0, 0) }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
    return (round2(values.reduce(0, +) / Double(values.count)), round2(sorted[max(index, 0)]))
}

private func round2(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}
