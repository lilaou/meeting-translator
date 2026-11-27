import Foundation

/// The short, readable Chinese messages the UI shows for errors, shared by the session
/// (`SessionCoordinator`), the onboarding (`OnboardingModel`) and the face-to-face language packs
/// (`ConversationPacks`) so the wording stays the same.
enum UserMessages {
    static let speechPack = "语音识别离线包"
    static let translationPack = "翻译离线包"
    static let selfTestFailedPrefix = "离线自检未通过："
    static let recognitionTimedOut = "识别未能及时完成"

    /// The hint for an error of the session: readiness and audio errors have their own texts,
    /// anything else shows its `localizedDescription`.
    static func hint(for error: any Error) -> String {
        switch error {
        case let failure as ReadinessFailure:
            switch failure {
            case .speechPackMissing: return "\(speechPack)未安装，请先下载"
            case .translationPackMissing: return "\(translationPack)未安装，请先下载"
            case .selfTestFailed(let detail): return selfTestFailedPrefix + detail
            }
        case let failure as AudioCaptureError:
            switch failure {
            case .permissionDenied: return "没有麦克风权限，请在系统设置中允许"
            case .engineStartFailed(let detail): return "无法启动录音：\(detail)"
            }
        default:
            return "出现错误：\(error.localizedDescription)"
        }
    }

    /// The system has no offline speech recognition for `locale`'s language.
    static func speechUnsupported(_ locale: Locale) -> String {
        "系统不支持\(CaptionStrings.languageName(of: locale))的离线语音识别"
    }

    /// The system cannot translate `locale`'s language into Chinese offline.
    static func translationUnsupported(_ locale: Locale) -> String {
        "系统不支持把\(CaptionStrings.languageName(of: locale))离线翻译成中文"
    }

    /// The system cannot translate `source`'s language into `target`'s offline (the
    /// face-to-face screen, which translates both ways).
    static func translationUnsupported(from source: Locale, to target: Locale) -> String {
        "系统不支持把\(CaptionStrings.languageName(of: source))离线翻译成\(CaptionStrings.languageName(of: target))"
    }

    /// `installSpeechPack` failed; `ModelReadinessError` already reads well on its own.
    static func speechInstallFailed(_ error: any Error) -> String {
        if let error = error as? ModelReadinessError { return error.localizedDescription }
        return "\(speechPack)安装失败：\(error.localizedDescription)"
    }

    /// The view's translation pack download failed.
    static func translationDownloadFailed(_ error: any Error) -> String {
        "\(translationPack)下载失败：\(error.localizedDescription)"
    }

    /// A pack still does not report `.installed` after its install or download succeeded.
    static func stillMissing(_ pack: String) -> String { "\(pack)仍未就绪，请重试" }

    /// The self-test did not pass: a `ReadinessFailure` uses the session's hint, anything
    /// else shows its `localizedDescription`.
    static func selfTestFailed(_ error: any Error) -> String {
        error is ReadinessFailure ? hint(for: error) : selfTestFailedPrefix + error.localizedDescription
    }
}
