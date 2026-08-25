import Foundation
import AppKit

/// **창이 예기치 않게 닫힌 상황을 기록**한다.
///
/// 배경: "쓰다가 앱이 꺼진다"는 신고가 반복됐지만 크래시 덤프도, Jetsam 리포트도 남지 않았다.
/// 즉 프로세스가 *죽은* 게 아니라 *종료된* 것이고, 사후에는 원인을 특정할 단서가 없다.
/// 그래서 종료 순간에 **어느 창이 닫혔는지 + 그때의 시스템 메모리 상태**를 남겨둔다.
/// 다음 재발 때 이 기록만 보면 메모리 압박에 의한 회수인지 아닌지 바로 갈린다.
enum CrashWatch {

    /// 우리가 의도적으로 닫는 동안에는 "예기치 않은 종료"로 세지 않는다.
    private static var intentionalQuitUntil = Date.distantPast
    private static let lock = NSLock()

    static func markIntentionalQuit(seconds: TimeInterval = 40) {
        lock.lock(); intentionalQuitUntil = Date().addingTimeInterval(seconds); lock.unlock()
    }
    static func isIntentional() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < intentionalQuitUntil
    }

    /// 시스템 메모리 상태 한 줄 요약(여유·압축·스왑).
    static func memorySnapshot() -> String {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "메모리 상태 조회 실패" }
        let page = Double(vm_kernel_page_size)
        let mb = { (p: UInt32) in Double(p) * page / 1_048_576 }
        let free = mb(stats.free_count)
        let compressed = mb(stats.compressor_page_count)

        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var swapUsed = -1.0
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
            swapUsed = Double(xsw.xsu_used) / 1_048_576
        }
        return String(format: "여유 %.0fMB · 압축 %.0fMB · 스왑사용 %.0fMB", free, compressed, swapUsed)
    }

    /// 종료된 창을 기록한다. `label` 은 어떤 계정 창이었는지.
    static func recordTermination(label: String, pid: pid_t, uptime: TimeInterval?) {
        let mem = memorySnapshot()
        let up = uptime.map { String(format: "%.1f시간", $0 / 3600) } ?? "?"
        if isIntentional() {
            Log.info("창 종료(의도됨): \(label) pid=\(pid) 실행 \(up) — \(mem)")
        } else {
            Log.error("⚠️ 창이 예기치 않게 닫힘: \(label) pid=\(pid) 실행 \(up) — \(mem)")
            appendIncident(label: label, pid: pid, uptime: up, memory: mem)
        }
    }

    /// 사람이 나중에 확인할 수 있도록 사고 기록을 따로 남긴다.
    private static func appendIncident(label: String, pid: pid_t, uptime: String, memory: String) {
        Paths.ensureAppDir()
        let file = Paths.appDir.appending(path: "unexpected-quits.log")
        let iso = ISO8601DateFormatter().string(from: Date())
        let line = "\(iso)\t\(label)\tpid=\(pid)\t실행=\(uptime)\t\(memory)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// 지금까지 기록된 예기치 않은 종료 횟수(메뉴 표시용).
    static func incidentCount() -> Int {
        let file = Paths.appDir.appending(path: "unexpected-quits.log")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    static var incidentFile: URL { Paths.appDir.appending(path: "unexpected-quits.log") }
}
