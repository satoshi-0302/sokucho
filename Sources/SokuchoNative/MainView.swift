import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.undoManager) private var undoManager

    @State private var showDeleteConfirm = false
    @State private var showHelpSheet = false

    var body: some View {
        HStack(spacing: 0) {
            CanvasAreaView(store: store)

            Divider()

            SidePanelView(store: store,
                          showDeleteConfirm: $showDeleteConfirm,
                          showHelpSheet: $showHelpSheet)
                .frame(width: 320)
                .background(Color(nsColor: NSColor(calibratedWhite: 0.08, alpha: 1)))
        }
        .frame(minWidth: 1180, minHeight: 760)
        .sheet(isPresented: $store.showScaleSheet) {
            ScaleInputSheet(store: store)
        }
        .sheet(isPresented: $showHelpSheet) {
            HelpSheet()
        }
        .onAppear {
            store.undoManager = undoManager
        }
    }
}

private struct CanvasAreaView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        ZStack(alignment: .top) {
            MeasurementCanvasRepresentable(store: store)
                .background(Color.black)

            VStack(spacing: 8) {
                MainTopToolbar(store: store)
                Spacer()
                StatusChip(text: store.statusText)
            }
            .padding(12)
        }
    }
}

private struct MainTopToolbar: View {
    @ObservedObject var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            Button("新規") {
                store.newProject()
            }

            Button("保存") {
                store.saveProjectPanel()
            }
            .disabled(store.sessions.isEmpty)

            Button("読込") {
                store.openProjectPanel()
            }

            Divider()
                .frame(height: 18)

            Button("画像を開く") {
                store.openImagePanel()
            }

            Button("フォルダを開く") {
                store.openImageFolderPanel()
            }

            Button("前画像") {
                store.switchSession(delta: -1)
            }
            .disabled(store.activeSession == nil)

            Button("次画像") {
                store.switchSession(delta: 1)
            }
            .disabled(store.activeSession == nil)

            Divider()
                .frame(height: 18)

            Button(store.mode == .measure ? "測長終了" : "測長開始") {
                if store.mode == .measure {
                    store.setMode(.idle)
                    store.statusText = "通常モードに戻しました。"
                } else {
                    store.setMode(.measure)
                    store.statusText = "測長中: 左クリック2点で確定 / 右クリックorESCで1つ戻る"
                }
            }

            Button("スケール設定") {
                store.setMode(.scale)
                store.statusText = "スケール: 2点クリック → 実長入力"
            }
            .disabled(store.activeSession == nil)

            Button("表示リセット") {
                store.resetView()
            }
            .disabled(store.activeSession == nil)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StatusChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Color(red: 0.86, green: 0.91, blue: 1.0))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .clipShape(Capsule())
    }
}

private struct SidePanelView: View {
    @ObservedObject var store: AppStore
    @Binding var showDeleteConfirm: Bool
    @Binding var showHelpSheet: Bool

    var body: some View {
        VStack(spacing: 12) {
            SideInfoCard(store: store)
                .padding(12)
                .background(panelBlock)

            SideOutputCard(store: store)
                .padding(12)
                .background(panelBlock)

            SideControlCard(store: store,
                            showDeleteConfirm: $showDeleteConfirm,
                            showHelpSheet: $showHelpSheet)
                .padding(12)
                .background(panelBlock)

            SideSummaryCard(store: store)
                .padding(12)
                .background(panelBlock)

            Divider()

            SideResultList(store: store)
        }
        .padding(12)
    }

    private var panelBlock: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct SideInfoCard: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("そくちょうくん Native")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Text("\(store.currentResults.count)件")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .clipShape(Capsule())
            }

            SideMetaLine(title: "モード", value: store.modeText)
            SideMetaLine(title: "スケール", value: store.scaleText)
            SideMetaLine(title: "丸め", value: store.roundingMode.label)
            SideMetaLine(title: "画像", value: store.imageChipText)

            if !store.sessions.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                SessionThumbnailStrip(store: store)
            }
        }
    }
}

private struct SessionThumbnailStrip: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("サムネイル")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                        thumbnailCell(index: index, session: session)
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(height: 88)
        }
    }

    private func thumbnailCell(index: Int, session: ImageSession) -> some View {
        let selected = index == store.activeIndex
        return Button {
            store.activateSession(index: index)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.45))

                Image(nsImage: session.thumbnail)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 74, height: 74)

                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.62))
                    .clipShape(Capsule())
                    .padding(4)
            }
            .frame(width: 82, height: 82)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.blue.opacity(0.95) : Color.white.opacity(0.14), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SideMetaLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
        }
    }
}

private struct SideOutputCard: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("出力")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Button("CSVコピー") { store.copyCurrentCSV() }
                    Button("CSVコピー全画面") { store.copyAllCSV() }
                }
                GridRow {
                    Button("画面保存") { store.saveAnnotatedCurrent() }
                    Button("画面保存全画面") { store.saveAnnotatedAll() }
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct SideControlCard: View {
    @ObservedObject var store: AppStore
    @Binding var showDeleteConfirm: Bool
    @Binding var showHelpSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("表示・管理")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("連続測長", isOn: Binding(get: {
                store.continuousMeasure
            }, set: { newValue in
                store.setContinuousMeasure(newValue)
            }))

            Toggle("点スナップ", isOn: Binding(get: {
                store.edgeSnap
            }, set: { newValue in
                store.setEdgeSnap(newValue)
            }))

            Button("丸め規則: \(store.roundingMode.label)") {
                store.toggleRounding()
            }
            .buttonStyle(.bordered)

            Button("操作ヘルプ") {
                showHelpSheet = true
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Text("測定結果を削除")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .alert("現在画像の測定結果を削除しますか？", isPresented: $showDeleteConfirm) {
                Button("削除", role: .destructive) {
                    store.clearMeasurements()
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }
}

private struct SideSummaryCard: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("平均")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(store.avgText)
                    .font(.system(size: 15, weight: .bold))
            }

            if let note = store.drawLimitNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.yellow.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct SideResultList: View {
    @ObservedObject var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if store.currentResults.isEmpty {
                    Text("まだ結果はありません。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    ForEach(store.currentResults) { result in
                        SideResultRow(store: store, result: result)
                    }
                }
            }
        }
    }
}

private struct SideResultRow: View {
    @ObservedObject var store: AppStore
    let result: Measurement

    var body: some View {
        let selected = store.highlightedMeasurementID == result.id

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(result.id)")
                    .font(.system(size: 11, weight: .semibold))
                Text(store.formattedLength(pixelLength: result.pixelLength))
                    .font(.system(size: 13, weight: .bold))
            }
            Spacer()
            Button {
                store.deleteMeasurement(id: result.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(selected ? Color.green.opacity(0.22) : Color.black.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.green.opacity(0.78) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            store.toggleHighlight(result.id)
        }
    }
}

struct ScaleInputSheet: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スケール設定")
                .font(.system(size: 16, weight: .bold))

            Text("単位")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("µm", text: $store.scaleInputUnit)
                .textFieldStyle(.roundedBorder)

            Text("2点間の実長")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("例: 12.5", text: $store.scaleInputLength)
                .textFieldStyle(.roundedBorder)

            Text("0より大きい数値を入力してください。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("キャンセル") {
                    store.cancelScaleInput()
                }
                Button("適用") {
                    store.applyScaleInput()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct HelpSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("操作ヘルプ")
                .font(.system(size: 16, weight: .bold))

            Group {
                Text("・左クリック2点: 測長確定")
                Text("・右クリック or ESC: キャンセル")
                Text("・トラックパッド 2本指: パン")
                Text("・トラックパッド左右スワイプ: 前後画像へ切替")
                Text("・ピンチ: ズーム")
                Text("・Option+2本指上下: スムーズズーム")
                Text("・M: 測長モード / S: スケール設定 / R: 表示リセット")
                Text("・C: 連続測長切替 / G: 点スナップ切替 / ?: ヘルプ")
                Text("・結果行クリック: 線ハイライト")
                Text("・Cmd+Shift+S/O: プロジェクト保存/読込")
            }
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(16)
        .frame(width: 480, height: 260)
    }
}
