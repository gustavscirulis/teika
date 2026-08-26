import SwiftUI

@main
struct TeikaWatchApp: App {
    @State private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            WatchContentView(link: link)
        }
    }
}
