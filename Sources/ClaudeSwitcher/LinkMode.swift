import Foundation

/// **공유 모드** — 계정·인스턴스마다 흩어진 세션 폴더를 심볼릭 링크로 **하나의 실체**에 연결한다.
///
/// 왜 필요한가(복사 방식의 한계):
///  복사 기반 합집합 동기화는 **없는 파일만 채운다.** 이미 양쪽에 있는 세션의 *내용*이 바뀌면
///  (아카이브, 제목 변경 등) 그 변화는 서로에게 전파되지 않는다. 실측: 512개 중 209개가
///  아카이브 상태 불일치. 한쪽에서 정리해도 다른 쪽에서 또 해야 하는 이유가 이것이다.
///
/// 공유 모드에서는 사본이 존재하지 않는다. 어느 창에서 아카이브하든 **같은 파일**을 고치므로
/// 상태가 갈라질 수 없고, 삭제도 그대로 반영되며, 수천 개를 복사할 일도 사라진다.
/// (다만 Claude 가 목록을 시작할 때만 읽는 것은 그대로라, 화면 반영은 그 창의 재시작 시점이다)
enum LinkMode {
    /// 모두가 가리킬 실체 디렉터리.
    static var canonical: URL {
        Paths.appDir.appending(path: "shared-sessions", directoryHint: .isDirectory)
    }

    struct Report {
        var linked = 0          // 링크로 바꾼 폴더 수
        var merged = 0          // 실체로 모은 인덱스 수
        var conflictsResolved = 0  // 내용이 갈라져 최신본으로 정리한 수
        var skippedRunning: [String] = []   // 실행 중이라 건드리지 않은 창
    }

    static func isLinked(_ folder: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) != nil
    }

    /// 지금 공유 모드인지(대상 폴더가 하나라도 링크면 켜진 것으로 본다).
    static func isEnabled(folders: [URL]) -> Bool {
        folders.contains { isLinked($0) }
    }

    /// 공유 모드로 전환. **실행 중인 창의 폴더는 건드리지 않는다**(그 창을 닫은 뒤 다시 실행할 것).
    @discardableResult
    static func enable(folders: [URL], runningFolders: Set<String>) -> Report {
        var report = Report()
        let fm = FileManager.default
        try? fm.createDirectory(at: canonical, withIntermediateDirectories: true)

        // 1) 모든 폴더의 인덱스를 실체로 모은다. 같은 이름이 여러 벌이면 **가장 최근 것**을 남긴다
        //    (아카이브처럼 갈라진 상태를 최신 기준으로 수렴시킨다).
        for folder in folders {
            guard !isLinked(folder) else { continue }
            guard let items = try? fm.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
                autoreleasepool {
                    let dest = canonical.appending(path: item.lastPathComponent)
                    let srcTime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if fm.fileExists(atPath: dest.path) {
                        let dstTime = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        if srcTime > dstTime {
                            try? fm.removeItem(at: dest)
                            try? fm.copyItem(at: item, to: dest)
                            report.conflictsResolved += 1
                        }
                    } else {
                        try? fm.copyItem(at: item, to: dest)
                        report.merged += 1
                    }
                }
            }
        }

        // 2) 각 폴더를 실체로 향하는 링크로 교체(원본은 백업으로 보관)
        let backup = Paths.backupsDir.appending(path: "prelink-\(stamp())")
        for folder in folders {
            if isLinked(folder) { continue }
            if runningFolders.contains(folder.standardizedFileURL.path) {
                report.skippedRunning.append(folder.lastPathComponent)
                continue
            }
            let key = "\(folder.deletingLastPathComponent().lastPathComponent)_\(folder.lastPathComponent)"
            let saved = backup.appending(path: key)
            do {
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                try fm.moveItem(at: folder, to: saved)                 // 원본 보관
                try fm.createSymbolicLink(at: folder, withDestinationURL: canonical)
                report.linked += 1
            } catch {
                Log.error("링크 전환 실패 \(folder.lastPathComponent): \(error.localizedDescription)")
                // 실패하면 원상복구 시도
                if fm.fileExists(atPath: saved.path), !fm.fileExists(atPath: folder.path) {
                    try? fm.moveItem(at: saved, to: folder)
                }
            }
        }
        Log.info("공유 모드: 링크 \(report.linked)개, 통합 \(report.merged)개, 충돌 정리 \(report.conflictsResolved)개")
        return report
    }

    /// 공유 모드 해제 — 링크를 실제 폴더로 되돌린다(실체 내용을 각 폴더에 복사).
    @discardableResult
    static func disable(folders: [URL], runningFolders: Set<String>) -> Int {
        let fm = FileManager.default
        var restored = 0
        for folder in folders where isLinked(folder) {
            if runningFolders.contains(folder.standardizedFileURL.path) { continue }
            do {
                try fm.removeItem(at: folder)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if let items = try? fm.contentsOfDirectory(at: canonical, includingPropertiesForKeys: nil) {
                    for item in items where item.pathExtension == "json" {
                        try? fm.copyItem(at: item, to: folder.appending(path: item.lastPathComponent))
                    }
                }
                restored += 1
            } catch {
                Log.error("링크 해제 실패 \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        Log.info("공유 모드 해제: \(restored)개 폴더 복원")
        return restored
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
