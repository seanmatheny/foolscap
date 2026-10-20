import SwiftUI

/// The iPhone app. Phase 1 shows the closed cover and the version: enough to prove that
/// the free-team signature is renewed by `Tools/ios-refresh.sh` before its seven days
/// run out. The notebook itself follows once the packages compile for iOS.
@main
struct FoolscapMobileApp: App {
    var body: some Scene {
        WindowGroup {
            ClosedCoverPage()
        }
    }
}

/// Leather and a wordmark, the way the Mac app opens; the version line is what a glance
/// at the phone needs to tell whether the latest refresh landed.
struct ClosedCoverPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ZStack {
            Color("CoverColor").ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Foolscap")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .kerning(2)
                Text(version)
                    .font(.footnote)
                    .opacity(0.7)
            }
            .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.87).opacity(0.75))
        }
    }
}
