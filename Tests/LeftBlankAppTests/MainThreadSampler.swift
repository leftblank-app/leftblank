import Darwin
import Foundation

/// Temporary diagnostic: samples the main thread's frame-pointer stack from a
/// background thread, so CI's macOS can report where the time goes.
final class MainThreadSampler: @unchecked Sendable {
    private let thread: thread_act_t
    private let low: UInt
    private let high: UInt
    private let lock = NSLock()
    private var samples: [[UInt]] = []
    private var running = false
    private var finished = DispatchSemaphore(value: 0)

    @MainActor init() {
        thread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        high = top
        low = top - UInt(pthread_get_stacksize_np(pthread_self()))
    }

    func start() {
        lock.withLock {
            samples = []
            running = true
        }
        finished = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            run()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop(_ phase: String) {
        lock.withLock { running = false }
        finished.wait()
        report(phase, lock.withLock { samples })
    }

    private func run() {
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: 256)
        let state = UnsafeMutablePointer<natural_t>.allocate(capacity: 68)
        defer {
            buffer.deallocate()
            state.deallocate()
            finished.signal()
        }
        let mask: UInt = 0x0000_000F_FFFF_FFFF
        while lock.withLock({ running }) {
            var count = 0
            // Nothing may allocate while the main thread is suspended.
            if thread_suspend(thread) == KERN_SUCCESS {
                var size = mach_msg_type_number_t(68)
                if thread_get_state(thread, thread_state_flavor_t(6), state, &size) == KERN_SUCCESS {
                    state.withMemoryRebound(to: UInt64.self, capacity: 34) { registers in
                        buffer[0] = UInt(registers[32]) & mask
                        buffer[1] = UInt(registers[30]) & mask
                        count = 2
                        var frame = UInt(registers[29])
                        while count < 256, frame >= low, frame + 16 <= high, frame & 7 == 0 {
                            guard let pointer = UnsafePointer<UInt>(bitPattern: frame) else {
                                break
                            }
                            let address = pointer[1] & mask
                            let next = pointer[0]
                            if address == 0 {
                                break
                            }
                            buffer[count] = address
                            count += 1
                            if next <= frame {
                                break
                            }
                            frame = next
                        }
                    }
                }
                thread_resume(thread)
            }
            if count > 0 {
                let stack = Array(UnsafeBufferPointer(start: buffer, count: count))
                lock.withLock { samples.append(stack) }
            }
            usleep(500)
        }
    }

    private func report(_ phase: String, _ samples: [[UInt]]) {
        var names: [UInt: String] = [:]
        func name(_ address: UInt, leaf: Bool) -> String {
            let key = leaf || address == 0 ? address : address - 1
            if let name = names[key] {
                return name
            }
            var info = Dl_info()
            var result = String(format: "0x%lx", key)
            if dladdr(UnsafeRawPointer(bitPattern: key), &info) != 0 {
                let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                result = "\(image)`\(symbol)"
            }
            names[key] = result
            return result
        }
        var inclusive: [String: Int] = [:], leaves: [String: Int] = [:], stacks: [String: Int] = [:]
        for sample in samples {
            let symbols = sample.enumerated().filter { $0.element != 0 }.map { name($0.element, leaf: $0.offset == 0) }
            for symbol in Set(symbols) {
                inclusive[symbol, default: 0] += 1
            }
            leaves[symbols[0], default: 0] += 1
            stacks[symbols.prefix(28).joined(separator: " <- "), default: 0] += 1
        }
        let total = max(1, samples.count)
        func line(_ entry: (key: String, value: Int)) -> String {
            String(format: "%5.1f%% %@", Double(entry.value) * 100 / Double(total), entry.key)
        }
        var text = "LEFTBLANK PROFILE \(phase): \(samples.count) samples\n-- inclusive\n"
        text += inclusive.sorted { $0.value > $1.value }.prefix(60).map(line).joined(separator: "\n")
        text += "\n-- self\n" + leaves.sorted { $0.value > $1.value }.prefix(25).map(line).joined(separator: "\n")
        text += "\n-- stacks\n" + stacks.sorted { $0.value > $1.value }.prefix(6).map(line).joined(separator: "\n")
        print(text + "\nLEFTBLANK PROFILE END")
    }
}
