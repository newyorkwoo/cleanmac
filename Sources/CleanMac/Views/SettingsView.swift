import CleanMacCore
import SwiftUI

struct SettingsView: View {
    /// Unused in the body except to rebuild it, so a language change retranslates the window.
    let language: AppLanguage

    var body: some View {
        TabView {
            MemorySettingsView()
                .tabItem { Label(L("記憶體"), systemImage: "memorychip") }
        }
        .id(language)
        .frame(width: 560)
    }
}

private struct MemorySettingsView: View {
    @AppStorage(MemorySetting.showInMenuBar) private var showInMenuBar = true
    @AppStorage(MemorySetting.showPercent) private var showPercent = true
    @AppStorage(MemorySetting.purgeOnAppQuit) private var purgeOnAppQuit = false
    @AppStorage(MemorySetting.purgeWhenLow) private var purgeWhenLow = false
    @AppStorage(MemorySetting.lowThresholdMB) private var thresholdMB = MemorySetting.defaultThresholdMB
    @AppStorage(MemorySetting.purgeOnWake) private var purgeOnWake = false
    @State private var controller = AutoPurgeController.shared
    @State private var isAuthorizing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            option(L("在選單列顯示記憶體用量"), isOn: $showInMenuBar, detail: L("在選單列圖示旁顯示目前的記憶體用量。"))
            option(L("顯示已使用的記憶體（以百分比表示）"), isOn: $showPercent, detail: L("取消勾選可顯示目前使用的記憶體容量。"))
                .disabled(!showInMenuBar)

            Divider()

            automatic(L("在應用程式關閉時自動清除記憶體"), isOn: $purgeOnAppQuit,
                      detail: L("關閉使用大量記憶體（超過 1 GB）的應用程式時，自動清除記憶體。自動清除限制為每隔三分鐘執行一次。"))
            automatic(L("可用記憶體過少時，自動清除記憶體"), isOn: $purgeWhenLow,
                      detail: L("可用記憶體低於閾值時自動清除。自動清除限制為每隔三分鐘執行一次。"))
            HStack(spacing: 6) {
                Text(L("閾值："))
                TextField(L("閾值："), value: $thresholdMB, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .onChange(of: thresholdMB) { _, value in
                        if clampedThreshold(value) != value { thresholdMB = clampedThreshold(value) }
                    }
                Text(L("MB（上限：%@ MB）", MemorySetting.thresholdRange.upperBound))
            }
            .padding(.leading, 20)
            .disabled(!purgeWhenLow)
            automatic(L("電腦喚醒後自動清除記憶體"), isOn: $purgeOnWake,
                      detail: L("電腦喚醒後立即清除記憶體。自動清除限制為每隔三分鐘執行一次。"))

            Divider()
            authorization
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { controller.refreshAuthorization() }
    }

    private func option(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            Text(detail).font(.callout).foregroundStyle(.secondary).padding(.leading, 20)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Turning on an automatic purge needs the one-time authorization; cancelling it leaves the option off.
    private func automatic(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        option(title, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { newValue in
                guard newValue, !controller.isAuthorized else { isOn.wrappedValue = newValue; return }
                Task {
                    isAuthorizing = true
                    if await controller.authorize() { isOn.wrappedValue = true }
                    isAuthorizing = false
                }
            }
        ), detail: detail)
        .disabled(isAuthorizing)
    }

    @ViewBuilder private var authorization: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: controller.isAuthorized ? "checkmark.shield" : "lock.shield")
                    .foregroundStyle(controller.isAuthorized ? .green : .secondary)
                Text(controller.isAuthorized ? L("已授權自動清除") : L("尚未授權自動清除")).fontWeight(.medium)
                Spacer()
                if controller.isAuthorized {
                    Button(L("移除授權")) {
                        Task {
                            await controller.revoke()
                            if !controller.isAuthorized { purgeOnAppQuit = false; purgeWhenLow = false; purgeOnWake = false }
                        }
                    }
                }
            }
            Text(L("清除記憶體需要管理者權限。第一次開啟自動清除時會詢問一次密碼，之後只允許 CleanMac 不需密碼執行 macOS 的 purge 指令，不包含其他權限。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let last = controller.lastPurge {
                Text(L("上次自動清除：%@", last.formatted(date: .omitted, time: .shortened)))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
