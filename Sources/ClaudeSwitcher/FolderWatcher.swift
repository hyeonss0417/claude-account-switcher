import Foundation

/// 세션 폴더를 감시해 **변화가 생기는 즉시** 동기화를 트리거한다.
///
/// 30초 폴링만으로는 "다른 계정에서 방금 만든 세션"이 최대 30초, 게다가 Claude 가
/// **시작할 때만 폴더를 스캔**하기 때문에 다음 재시작까지 안 보이는 창이 생긴다.
/// 폴더 감시로 그 창을 최소화한다.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptors: [Int32] = []
    private let queue = DispatchQueue(label: "io.github.claudeaccountswitcher.watch")
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    /// 주어진 폴더들의 상위(계정 루트)를 감시. 하위 파일 변화도 디렉터리 이벤트로 잡힌다.
    func watch(_ folders: [URL]) {
        stop()
        for folder in folders {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            descriptors.append(fd)
            let s = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename], queue: queue)
            s.setEventHandler { [weak self] in self?.debounced() }
            s.resume()
            if source == nil { source = s } else { extraSources.append(s) }
        }
    }

    private var extraSources: [DispatchSourceFileSystemObject] = []

    /// 연속 이벤트가 쏟아질 때 마지막 것만 처리(2초 디바운스).
    private func debounced() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func stop() {
        pending?.cancel()
        source?.cancel(); source = nil
        extraSources.forEach { $0.cancel() }; extraSources.removeAll()
        descriptors.forEach { close($0) }; descriptors.removeAll()
    }

    deinit { stop() }
}
