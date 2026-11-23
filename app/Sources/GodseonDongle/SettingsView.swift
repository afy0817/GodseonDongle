// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var dongleText = ""
    @State private var countryText = ""
    @State private var routesText = ""
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(t("동글과 폰은 왼쪽 장치 목록에서 장치마다 켜고 꺼요. 동글의 Trigger 프레임 거르기와 폰의 맥 인터넷도 거기서 정해요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(t("목록에 없는 동글"), text: $dongleText, prompt: Text("0bda:b812"))
                    Text(t("VM의 드라이버 목록에 없는 USB ID라도 동글로 보여 줘요. vendor:product 형식이고, 비워 둬도 돼요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(t("장치"))
                }

                Section {
                    TextField(t("국가 코드"), text: $countryText, prompt: Text("KR"))
                    Text(t("쓸 수 있는 채널이 정해져요. 바꾸면 다음 VM 시작부터 적용돼요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Wi-Fi")
                }

                Section {
                    TextField(t("추가로 보낼 대역"), text: $routesText, prompt: Text(t("예: 10.20.0.0/16, 172.16.5.0/24")))
                    Text(t("연결한 Wi-Fi의 대역과 네트워크별 추가 경로는 저절로 보내요. 그 밖에 동글 쪽으로 보낼 대역을 쉼표로 적어요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(t("맥 경로"))
                }

                Section {
                    Picker(t("언어"), selection: Binding(get: { AppLanguage.shared.choice },
                                                       set: { AppLanguage.shared.select($0) })) {
                        Text(t("시스템 설정 따름")).tag(AppLanguage.Choice.system)
                        Text(verbatim: "한국어").tag(AppLanguage.Choice.korean)
                        Text(verbatim: "English").tag(AppLanguage.Choice.english)
                    }
                    Text(t("바로 바뀌어요. 앱 메뉴처럼 macOS가 그리는 메뉴는 앱을 다시 열면 바뀌어요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(t("로그인할 때 열기"), isOn: Binding(get: { model.launchAtLogin },
                                                        set: { model.setLaunchAtLogin($0) }))
                } header: {
                    Text(t("앱"))
                }

                Section {
                    LabeledContent(t("상태"), value: helperState)
                    HStack {
                        if model.helperInstalled && model.helperOutdated {
                            Button(t("도우미 업데이트")) { Task { await model.installHelper() } }
                        }
                        if !model.helperInstalled {
                            Button(t("도우미 설치")) { Task { await model.installHelper() } }
                        }
                        Button(t("도우미 로그")) { open(Helper.logPath) }
                            .disabled(!FileManager.default.fileExists(atPath: Helper.logPath))
                        Button(t("VM 콘솔 로그")) { open(GuestVM.consoleLogURL.path) }
                        Button(t("VM 진단 정보")) { Task { await model.saveDiagnostics() } }
                            .disabled(model.vmState != .running)
                        Spacer()
                        if model.helperInstalled {
                            Button(t("도우미 제거"), role: .destructive) { confirmUninstall = true }
                        }
                    }
                } header: {
                    Text(t("도우미"))
                }

                Section {
                    LabeledContent(t("버전")) { Text(AppInfo.versionText).textSelection(.enabled) }
                    if let image = AppInfo.vmImageText {
                        LabeledContent(t("VM 이미지")) { Text(image).textSelection(.enabled) }
                    }
                } header: {
                    Text(t("정보"))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let problem = validationProblem {
                    Text(problem).font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button(t("취소")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t("저장")) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationProblem != nil)
            }
            .padding(16)
        }
        .frame(width: 540, height: 520)   // fits the smallest window (560); the form scrolls
        .onAppear {
            dongleText = model.dongleID
            countryText = model.country
            routesText = model.extraRoutesText
        }
        .confirmationDialog(t("도우미를 지울까요?"), isPresented: $confirmUninstall) {
            Button(t("도우미 제거"), role: .destructive) { Task { await model.uninstallHelper() } }
        } message: {
            Text(t("동글과 폰을 macOS에 돌려주고 맥 경로를 지워요. 다시 쓰려면 다시 설치해야 해요. macOS가 관리자 암호를 물어요."))
        }
    }

    private var helperState: String {
        guard model.helperInstalled else { return t("설치되지 않음") }
        if model.helperOutdated { return t("업데이트 필요") }
        return model.helperStatus == nil ? t("설치됨 · 응답 없음") : t("설치됨 · 실행 중")
    }

    /// "" for an empty field; nil when it holds something other than vendor:product.
    private var normalizedDongle: String? {
        let text = dongleText.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return "" }
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return text
    }

    private var validationProblem: String? {
        if normalizedDongle == nil { return t("USB ID는 0bda:b812처럼 적어 주세요.") }
        let country = countryText.trimmingCharacters(in: .whitespaces)
        if country.count != 2 || !country.allSatisfy({ $0.isASCII && $0.isLetter }) { return t("국가 코드는 KR처럼 두 글자예요.") }
        if IPv4.parseCIDRList(routesText) == nil { return t("대역은 10.20.0.0/16처럼 적어 주세요.") }
        return nil
    }

    private func apply() {
        guard validationProblem == nil, let dongle = normalizedDongle else { return }
        if model.dongleID != dongle { model.dongleID = dongle }
        let country = countryText.trimmingCharacters(in: .whitespaces).uppercased()
        if model.country != country { model.country = country }
        let routes = (IPv4.parseCIDRList(routesText) ?? []).joined(separator: ", ")
        if model.extraRoutesText != routes { model.extraRoutesText = routes }
        dismiss()
    }

    private func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
