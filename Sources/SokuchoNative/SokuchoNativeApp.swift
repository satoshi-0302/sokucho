import SwiftUI

@main
struct SokuchoNativeApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
        }
        .commands {
            SokuchoCommands(store: store)
        }
    }
}

struct SokuchoCommands: Commands {
    @ObservedObject var store: AppStore

    var body: some Commands {
        CommandMenu("そくちょう") {
            Button("新規プロジェクト") {
                store.newProject()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("プロジェクトを開く...") {
                store.openProjectPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("プロジェクトを保存...") {
                store.saveProjectPanel()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("画像を開く") {
                store.openImagePanel()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("フォルダを開く") {
                store.openImageFolderPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])

            Divider()

            Button(store.mode == .measure ? "測長終了" : "測長開始") {
                if store.mode == .measure {
                    store.setMode(.idle)
                } else {
                    store.setMode(.measure)
                }
            }
            .keyboardShortcut("m", modifiers: [])

            Button("スケール設定") {
                store.setMode(.scale)
            }
            .keyboardShortcut("s", modifiers: [])

            Button("表示リセット") {
                store.resetView()
            }
            .keyboardShortcut("r", modifiers: [])

            Button("前画像") {
                store.switchSession(delta: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])

            Button("次画像") {
                store.switchSession(delta: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])

            Button("キャンセル") {
                store.cancelAction()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Divider()

            Button("連続測長切替") {
                store.toggleContinuousMeasure()
            }
            .keyboardShortcut("c", modifiers: [])

            Button("点スナップ切替") {
                store.toggleEdgeSnap()
            }
            .keyboardShortcut("g", modifiers: [])

            Divider()

            Button("CSVコピー") {
                store.copyCurrentCSV()
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("CSVコピー全画面") {
                store.copyAllCSV()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}
