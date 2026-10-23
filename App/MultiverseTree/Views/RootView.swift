import SwiftUI
import MultiverseCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            UniverseScreen(openTab: { tab = $0 })
                .tabItem { Label("Universe", systemImage: "sparkles") }.tag(0)
            NavigationStack { PeopleView() }
                .tabItem { Label("People", systemImage: "person.3") }.tag(1)
            NavigationStack { ConnectView(openUniverse: { tab = 0 }) }
                .tabItem { Label("Connect", systemImage: "point.3.connected.trianglepath.dotted") }.tag(2)
            NavigationStack { AskAIView(openUniverse: { tab = 0 }) }
                .tabItem { Label("Ask AI", systemImage: "bubble.left.and.text.bubble.right") }.tag(3)
            NavigationStack { ResearchView() }
                .tabItem { Label("Research", systemImage: "magnifyingglass.circle") }.tag(4)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(5)
        }
        .tint(Color(red: 0.45, green: 0.75, blue: 1))
    }
}

/// Shared visual language for overlays.
extension View {
    func cosmicCard() -> some View {
        self.padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.25), lineWidth: 0.5))
    }
}

struct VerificationBadge: View {
    let status: VerificationStatus
    var body: some View {
        Text(status == .candidate ? "Possible — research required" : status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
    var color: Color {
        switch status {
        case .verified: return .green
        case .sourced: return .cyan
        case .userAsserted: return .blue
        case .candidate: return .orange
        case .disputed: return .yellow
        case .rejected: return .red
        }
    }
}

struct SampleBadge: View {
    var body: some View {
        Text("SAMPLE DATA").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.purple.opacity(0.3), in: Capsule()).foregroundStyle(.purple)
    }
}
