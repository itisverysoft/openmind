import SwiftUI

/// Maker links shared by the in-app About sheet and (in text form) the README.
enum VerySoftInfo {
    static let website = URL(string: "https://openmind.verysoft.site")!
    static let email = URL(string: "mailto:itisverysoft@gmail.com")!
    static let x = URL(string: "https://x.com/itisverysoft")!
    static let youTube = URL(string: "https://youtube.com/@itisverysoft")!
    static let instagram = URL(string: "https://instagram.com/itisverysoft")!
    static let facebook = URL(string: "https://facebook.com/itisverysoft")!
    static let maintainerSite = URL(string: "https://shoibur.pro.bd")!
    static let supportKori = URL(string: "https://www.supportkori.com/srksifat")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/shoibur")!
}

/// About sheet: what OpenMind is, its version, and who makes it (VerySoft
/// links + maintainer site). Presented from the board list toolbar and the
/// canvas Export menu.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OpenMind")
                .font(.title.weight(.semibold))
            Text("Infinite canvas for boards, notes & media.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(appVersion)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Built by VerySoft")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Link(destination: VerySoftInfo.website) {
                    Label("openmind.verysoft.site", systemImage: "globe")
                }
                Link(destination: VerySoftInfo.email) {
                    Label("itisverysoft@gmail.com", systemImage: "envelope")
                }
                Link(destination: VerySoftInfo.x) {
                    Label("x.com/itisverysoft", systemImage: "at")
                }
                Link(destination: VerySoftInfo.youTube) {
                    Label("youtube.com/@itisverysoft", systemImage: "play.rectangle")
                }
                Link(destination: VerySoftInfo.instagram) {
                    Label("instagram.com/itisverysoft", systemImage: "camera")
                }
                Link(destination: VerySoftInfo.facebook) {
                    Label("facebook.com/itisverysoft", systemImage: "hand.thumbsup")
                }
            }
            .font(.callout)
            Divider()
            Link(destination: VerySoftInfo.maintainerSite) {
                Label("Maintainer: shoibur.pro.bd", systemImage: "person")
            }
            .font(.callout)
            Divider()
            Text("Support OpenMind")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Link(destination: VerySoftInfo.supportKori) {
                    Label("Supportkori", systemImage: "heart")
                }
                Link(destination: VerySoftInfo.buyMeACoffee) {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer")
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }
}
