import SwiftData
import SwiftUI

struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background

  @FocusState private var searchFocused: Bool

  var body: some View {
    ZStack {
      VisualEffectView(material: .popover, blendingMode: .behindWindow)

      VStack(alignment: .leading) {
        KeyHandlingView(searchQuery: $appState.history.searchQuery, searchFocused: $searchFocused) {
          HeaderView(
            searchFocused: $searchFocused,
            searchQuery: $appState.history.searchQuery
          )

          HistoryListView(
            searchQuery: $appState.history.searchQuery,
            searchFocused: $searchFocused
          )

          FooterView(footer: appState.footer)
        }
      }
      .animation(.default, value: appState.history.items)
      .padding([.bottom, .horizontal], 5)
      .task { try? await appState.history.load() }
    }
    .environment(appState)
    .environment(modifierFlags)
    .environment(\.scenePhase, scenePhase)
    // FloatingPanel is not a scene, so let's implement custom scenePhase..
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      if ($0.object as? NSWindow)?.title == Bundle.main.bundleIdentifier {
        scenePhase = .active
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      if ($0.object as? NSWindow)?.title == Bundle.main.bundleIdentifier {
        scenePhase = .background
      }
    }
  }
}

#Preview {
  let config = ModelConfiguration(
    url: URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")
  )
  let container = try! ModelContainer(for: HistoryItem.self, configurations: config)

  return ContentView()
    .modelContainer(container)
}
