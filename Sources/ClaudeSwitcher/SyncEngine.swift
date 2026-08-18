import Foundation

/// 동기화 실행을 **단일화**하는 엔진.
///
/// 초기 구현에는 메모리를 폭주시키는 결함이 있었다(실측: 20시간에 수십 GB 누수):
///  1. **피드백 루프** — 동기화가 세션 폴더에 파일을 쓰면 폴더 감시자가 그 변화를 감지해
///     다시 동기화를 부르고, 그게 또 파일을 써서 끝없이 반복됐다.
///  2. **재진입 방어 없음** — 타이머·감시자·생명주기 훅이 각각 동기화를 띄워 동시에 여러 개가 돌았다.
///  3. **오토릴리즈 풀 없음** — 한 번에 수천 개 파일을 `Data`/`JSONSerialization` 으로 읽는 루프에서
///     오토릴리즈 객체가 작업이 끝날 때까지 쌓였다.
///  4. **매번 전수 스캔** — `buildLogIndex()`(~/.claude/projects 전체)를 동기화마다 여러 번 다시 만들었다.
///
/// 그래서 이 엔진은: 직렬 큐 1개 + 실행 중 플래그 + 최소 간격 + **자기 쓰기 무시 구간**을 강제하고,
/// 무거운 스캔 결과는 캐시한다.
final class SyncEngine {
    static let shared = SyncEngine()

    struct Result {
        var copied = 0
        var skippedDead = 0
        var quarantined = 0
        var lockHeld = 0
        var lockReleased = 0
        var orphansRecovered = 0     // 인덱스가 유실됐다 되살린 세션 수
        var deferredRunning = 0      // 실행 중인 창이라 미룬 복사(종료/재실행 때 반영)
        var skipped = false          // 최소 간격/중복 실행으로 건너뜀
    }

    private let queue = DispatchQueue(label: "io.github.claudeaccountswitcher.sync", qos: .utility)
    private var running = false
    private var lastRun = Date.distantPast
    private var lastQuarantine = Date.distantPast
    private var lastOrphanScan = Date.distantPast
    /// 이 시각까지는 감시자 이벤트를 무시한다(우리가 쓴 파일이 되돌아오는 것을 차단).
    private var ignoreWatchUntil = Date.distantPast
    private let lock = NSLock()

    /// 최소 실행 간격 — 타이머/감시자가 아무리 자주 불러도 이보다 자주 돌지 않는다.
    private let minInterval: TimeInterval = 60
    /// 동기화 직후 이 시간 동안의 감시자 이벤트는 자기 쓰기로 간주해 무시한다.
    private let selfWriteWindow: TimeInterval = 15
    /// 죽은 인덱스 격리는 비싸므로 이 간격으로만 수행한다.
    private let quarantineInterval: TimeInterval = 30 * 60
    /// 고아 세션(인덱스 유실) 복구 주기. Claude 가 비정상 종료되면 인덱스가 기록되지 못해
    /// 로그만 남고 목록에서 사라지므로, 주기적으로 되살린다.
    private let orphanInterval: TimeInterval = 30 * 60

    /// 감시자 이벤트를 받아들일지 판단.
    func shouldAcceptWatchEvent() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() >= ignoreWatchUntil && !running
    }

    /// 동기화 요청. `force` 면 최소 간격을 무시한다(사용자가 직접 누른 경우).
    /// - Parameter skipWriteTo: 읽기만 하고 **쓰지 않을** 폴더(실행 중인 창). Claude 는 시작 시에만
    ///   폴더를 읽으므로, 실행 중인 창에 넣어도 안 보이고 사이드바 그룹만 잠시 쪼개진다.
    func request(folders: @escaping () -> [URL],
                 autoClean: Bool,
                 force: Bool = false,
                 skipWriteTo: @escaping () -> Set<String> = { [] },
                 completion: ((Result) -> Void)? = nil) {
        lock.lock()
        if running {
            lock.unlock()
            completion?(Result(skipped: true))
            return
        }
        if !force, Date().timeIntervalSince(lastRun) < minInterval {
            lock.unlock()
            completion?(Result(skipped: true))
            return
        }
        running = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            var result = Result()
            // 파일을 대량으로 다루는 구간은 반드시 오토릴리즈 풀로 감싼다.
            autoreleasepool {
                let f = folders()
                guard f.count > 1 else { return }

                let doQuarantine = autoClean &&
                    Date().timeIntervalSince(self.lastQuarantine) > self.quarantineInterval
                if doQuarantine {
                    result.quarantined = SessionSync.quarantineDeadIndexes(folders: f)
                    self.lastQuarantine = Date()
                }

                let r = SessionSync.syncAll(folders: f, skipWriteTo: skipWriteTo())
                result.copied = r.copied
                result.skippedDead = r.skippedDead
                result.deferredRunning = r.deferredRunning

                // 잠금은 **창이 뜨는 순간에만** 의미가 있다(Claude 는 시작할 때 한 번만 폴더를 읽는다).
                // 그래서 상시 잠금은 하지 않고, 조용해진 보류본을 되돌리는 일만 한다.
                result.lockReleased = SessionLock.releaseIdleAll(folders: f)

                // 인덱스가 유실된 세션 되살리기 —
                // Claude 가 비정상 종료되면 세션은 로그만 남고 목록에서 사라진다.
                if Date().timeIntervalSince(self.lastOrphanScan) > self.orphanInterval {
                    self.lastOrphanScan = Date()
                    let orphans = OrphanSessions.find(folders: f)
                    if !orphans.isEmpty {
                        result.orphansRecovered = OrphanSessions.recover(orphans, into: f)
                    }
                }
            }
            SessionIndex.flushCaches()

            self.lock.lock()
            self.running = false
            self.lastRun = Date()
            // 방금 우리가 쓴 변화가 감시자로 되돌아오는 것을 차단
            self.ignoreWatchUntil = Date().addingTimeInterval(self.selfWriteWindow)
            self.lock.unlock()

            completion?(result)
        }
    }
}
