import Darwin
import Foundation

/// Diagnostic only: samples the main thread's frame-pointer stack.
final class MainThreadSampler: @unchecked Sendable {
    private let target: thread_act_t
    private let stackTop: UInt
    private let stackBottom: UInt
    private let lock = NSLock()
    private var running = false
    private var samples: [[UInt]] = []
    private var thread: Thread?

    init() {
        target = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackTop = top
        stackBottom = top - UInt(pthread_get_stacksize_np(pthread_self()))
    }

    func start() {
        lock.lock()
        running = true
        samples = []
        lock.unlock()
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let go = running
                lock.unlock()
                if !go {
                    break
                }
                if let stack = sample() {
                    lock.lock()
                    samples.append(stack)
                    lock.unlock()
                }
                usleep(500)
            }
        }
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() -> String {
        lock.lock()
        running = false
        let taken = samples
        lock.unlock()
        usleep(3000)
        return Self.report(taken)
    }

    private func sample() -> [UInt]? {
        guard thread_suspend(target) == KERN_SUCCESS else {
            return nil
        }
        defer { thread_resume(target) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(target, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        var stack = [UInt(state.__pc) & mask, UInt(state.__lr) & mask]
        var fp = UInt(state.__fp) & mask
        while fp >= stackBottom, fp + 16 <= stackTop, stack.count < 200 {
            guard let frame = UnsafePointer<UInt>(bitPattern: fp) else {
                break
            }
            let next = frame[0] & mask
            let ret = frame[1] & mask
            if ret == 0 {
                break
            }
            stack.append(ret)
            if next <= fp {
                break
            }
            fp = next
        }
        return stack
    }

    private static func report(_ samples: [[UInt]]) -> String {
        var names: [UInt: String] = [:]
        func name(_ address: UInt) -> String {
            if let cached = names[address] {
                return cached
            }
            var info = Dl_info()
            var result = "?"
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                let path = info.dli_fname.map { String(cString: $0) } ?? ""
                let image = path.split(separator: "/").last.map(String.init) ?? ""
                let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                result = "\(image)`\(symbol.prefix(110))"
            }
            names[address] = result
            return result
        }
        var leaf: [String: Int] = [:], inclusive: [String: Int] = [:]
        for stack in samples {
            leaf[name(stack[0]), default: 0] += 1
            for symbol in Set(stack.map(name)) {
                inclusive[symbol, default: 0] += 1
            }
        }
        let top = { (counts: [String: Int], n: Int) in
            counts.sorted { $0.value > $1.value }.prefix(n).map { "    \($0.value) \($0.key)" }.joined(separator: "\n")
        }
        return "  samples \(samples.count)\n  leaf:\n\(top(leaf, 25))\n  inclusive:\n\(top(inclusive, 90))"
    }
}
