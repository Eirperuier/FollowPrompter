import Foundation
import Speech
import Observation

/// 新版识别的语音模型（每种语言一个，由系统下载和管理）。
/// 提词页和设置页共用这一份状态，所以在哪里触发下载，两边都能看到进度；同一语言不会重复下载。
@MainActor @Observable
final class SpeechModelStore {
    static let shared = SpeechModelStore()

    enum Status: Equatable {
        case unknown
        /// 设备或系统不支持新版识别
        case deviceUnsupported
        /// 新版识别不支持这种语言
        case languageUnsupported
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private var downloads: [String: Task<Void, Error>] = [:]

    func status(_ localeID: String) -> Status { statuses[localeID] ?? .unknown }

    /// 查询模型是否已下载（不触发下载）
    func refresh(_ localeID: String) async {
        if case .downloading = status(localeID) { return }
        #if DEBUG
        if Self.fakeDownload {   // 模拟器不支持新版识别，用来预览下载界面
            if statuses[localeID] == nil { statuses[localeID] = .notInstalled }
            return
        }
        #endif
        guard #available(iOS 26, *), SpeechTranscriber.isAvailable else {
            statuses[localeID] = .deviceUnsupported
            return
        }
        guard let locale = await ModernTranscription.resolveLocale(localeID) else {
            statuses[localeID] = .languageUnsupported
            return
        }
        do {
            let request = try await ModernTranscription.installRequest(for: locale)
            if case .downloading = status(localeID) { return }
            statuses[localeID] = request == nil ? .installed : .notInstalled
        } catch {
            statuses[localeID] = .failed(error.localizedDescription)
        }
    }

    /// 确保模型可用：已下载直接返回，否则下载并更新进度。并发调用共享同一次下载。
    func ensure(_ localeID: String) async throws {
        if let running = downloads[localeID] {
            try await running.value
            return
        }
        let task = Task { @MainActor in
            defer { downloads[localeID] = nil }
            do {
                #if DEBUG
                if Self.fakeDownload {
                    for i in 0...40 {
                        statuses[localeID] = .downloading(Double(i) / 40)
                        try await Task.sleep(for: .milliseconds(150))
                    }
                    statuses[localeID] = .installed
                    return
                }
                #endif
                guard #available(iOS 26, *) else { throw Self.unsupported }
                try await download(localeID)
                statuses[localeID] = .installed
            } catch {
                statuses[localeID] = .failed(error.localizedDescription)
                throw error
            }
        }
        downloads[localeID] = task
        try await task.value
    }

    @available(iOS 26, *)
    private func download(_ localeID: String) async throws {
        guard SpeechTranscriber.isAvailable else { throw Self.unsupported }
        guard let locale = await ModernTranscription.resolveLocale(localeID) else { throw Self.unsupported }
        guard let request = try await ModernTranscription.installRequest(for: locale) else { return }
        statuses[localeID] = .downloading(0)
        let progress = request.progress
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.statuses[localeID] = .downloading(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
    }

    #if DEBUG
    static let fakeDownload = ProcessInfo.processInfo.arguments.contains("-fakeModelDownload")
    #endif

    private static let unsupported = NSError(domain: "FollowPrompter", code: 2,
                                             userInfo: [NSLocalizedDescriptionKey: "这台设备不支持新版识别"])
}
