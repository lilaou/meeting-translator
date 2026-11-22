import MeetingCore
import SwiftData
import SwiftUI

@main
struct MeetingTranslatorApp: App {
    private let assembly = AppAssembly.make()

    var body: some Scene {
        WindowGroup {
            switch assembly {
            case .success(let environment):
                RootView(onboarding: environment.onboarding)
                    .modelContainer(environment.container)
                    .environment(environment.coordinator)
            case .failure(let error):
                StartupErrorView(reason: error.reason)
            }
        }
    }
}
