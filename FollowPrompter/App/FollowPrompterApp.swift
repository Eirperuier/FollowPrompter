import SwiftUI

@main
struct FollowPrompterApp: App {
    @State private var store = ScriptStore()
    @Environment(\.scenePhase) private var scenePhase


    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.orange)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.syncAllLinked() }   // 回到前台时拉取飞书最新稿
            } else {
                store.saveNow()
            }
        }
    }
}

/// iPad：稿件库 + 提词；iPhone：默认是遥控器，也能当小号提词器用
struct RootView: View {
    @State private var remoteClient = RemoteClient()

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            TabView {
                RemoteView(client: remoteClient)
                    .tabItem { Label("遥控器", systemImage: "appletvremote.gen4") }
                LibraryView()
                    .tabItem { Label("稿件", systemImage: "doc.text") }
            }
        } else {
            LibraryView()
        }
    }
}
