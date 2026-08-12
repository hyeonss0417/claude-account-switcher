import Foundation

/// 인스턴스 간 **데스크탑 앱 설정**을 맞춘다.
///
/// 무엇이 어디에 사는지(실측):
///  - 메모리 `~/.claude/projects/<project>/memory/`, 대화 로그, CLI 설정(`~/.claude/settings.json`,
///    `~/.claude.json`) → **홈 밑이라 이미 모든 인스턴스가 공유**한다. 손댈 필요 없음.
///  - 데스크탑 앱 설정 → `<userDataDir>` 안이라 **인스턴스마다 갈라진다**. 이 파일이 그걸 맞춰준다.
///
/// ⚠️ 계정·인증에 얽힌 값은 절대 복사하지 않는다. 복사하면 인스턴스가 남의 계정으로 오인되거나
/// 로그인이 깨진다(`lastKnownAccountUuid`, `oauth:tokenCache*` 등).
enum SettingsSync {

    /// 통째로 복사해도 되는 설정 파일(전부 사용자 취향/도구 설정).
    private static let wholeFiles = ["claude_desktop_config.json"]

    /// `config.json` 에서 **공유할 키만** 골라낸다(화이트리스트).
    /// 여기에 없는 키는 인스턴스 고유값으로 간주해 건드리지 않는다.
    private static let sharedConfigKeys: Set<String> = [
        "darkMode", "scale", "userThemeMode", "locale", "quickWindowPosition",
    ]

    struct Report { var filesCopied = 0; var keysMerged = 0; var targets = 0 }

    /// 가장 최근에 수정된 인스턴스를 기준으로 나머지 인스턴스에 설정을 전파한다.
    @discardableResult
    static func sync(dataDirs: [URL]) -> Report {
        var report = Report()
        guard dataDirs.count > 1 else { return report }
        let fm = FileManager.default
        report.targets = dataDirs.count

        // 1) 통째 복사 대상: 가장 최신본을 원본으로
        for name in wholeFiles {
            var newest: (URL, Date)?
            for dir in dataDirs {
                let f = dir.appending(path: name)
                guard fm.fileExists(atPath: f.path),
                      let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                else { continue }
                if newest == nil || m > newest!.1 { newest = (f, m) }
            }
            guard let src = newest?.0, let data = try? Data(contentsOf: src) else { continue }
            for dir in dataDirs {
                let dst = dir.appending(path: name)
                if dst.standardizedFileURL == src.standardizedFileURL { continue }
                // 내용이 같으면 건너뛴다(불필요한 쓰기로 감시자를 깨우지 않도록)
                if let cur = try? Data(contentsOf: dst), cur == data { continue }
                if (try? data.write(to: dst, options: .atomic)) != nil { report.filesCopied += 1 }
            }
        }

        // 2) config.json: 화이트리스트 키만 병합 (계정/인증 키는 그대로 둔다)
        var sharedValues: [String: Any] = [:]
        var newestTime: Date = .distantPast
        for dir in dataDirs {
            let f = dir.appending(path: "config.json")
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if m > newestTime {
                newestTime = m
                sharedValues = obj.filter { sharedConfigKeys.contains($0.key) }
            }
        }
        guard !sharedValues.isEmpty else { return report }

        for dir in dataDirs {
            let f = dir.appending(path: "config.json")
            guard let data = try? Data(contentsOf: f),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var changed = false
            for (k, v) in sharedValues {
                let before = String(describing: obj[k])
                if before != String(describing: v) { obj[k] = v; changed = true; report.keysMerged += 1 }
            }
            guard changed, let out = try? JSONSerialization.data(withJSONObject: obj) else { continue }
            try? out.write(to: f, options: .atomic)
        }

        if report.filesCopied > 0 || report.keysMerged > 0 {
            Log.info("설정 동기화: 파일 \(report.filesCopied)개, 키 \(report.keysMerged)개 (\(dataDirs.count)개 인스턴스)")
        }
        return report
    }

    /// 인스턴스 간에 **공유되지 않는** 것들을 사람이 읽을 수 있게 설명한다(진단용).
    static func explain() -> [String] {
        [
            "공유됨(이미): 메모리 ~/.claude/projects/<project>/memory/",
            "공유됨(이미): 대화 로그 ~/.claude/projects/*.jsonl",
            "공유됨(이미): CLI 설정 ~/.claude/settings.json, ~/.claude.json (권한·훅·MCP)",
            "동기화함: claude_desktop_config.json (전역 단축키·MCP·cowork 경로·환경설정)",
            "동기화함: config.json 중 화면 설정만 (darkMode·scale·userThemeMode·locale)",
            "제외(계정별): lastKnownAccountUuid, oauth:tokenCache* — 복사하면 로그인이 깨진다",
            "제외(인스턴스별): Local Storage, 창 위치, 사용량 기록",
        ]
    }
}
