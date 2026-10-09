import SwiftUI
import AppKit

enum AppIdentity {
    static let repository = URL(string: "https://github.com/polo-aoi/AoiStitcher-Mac")!
    static let authorPage = URL(string: "https://github.com/polo-aoi")!
    static let wechatID = "Mallooooooooy"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
    }
}

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text("AoiStitcher").font(.title.weight(.semibold))
                    Text("版本 \(AppIdentity.version)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("为照片创作而做的 Mac 拼图工具。用长图拼接整理一组照片，也能在自由画布上搭配纸张、调整构图与留白。")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("免费 · 开源").font(.callout.weight(.medium))
                Spacer()
                Link(destination: AppIdentity.repository) { Label("GitHub 仓库", systemImage: "arrow.up.right.square") }
            }
            Divider()
            EditorSection("作者 · Aoi") {
                Text("我是 Aoi，一个在 AI 时代尝试用 AI 解决身边困难的人。我生活在小县城，在化工厂倒班，工作之外会抽时间学习拍摄、AI 编程，慢慢提升自己。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("我非科班出身，凭着一腔热血和热爱，自费开发一些应用，希望能给大家带来帮助。现在使用 AoiStitcher 的人还不多，但每一条建议，我都会认真思考，再利用业余时间把更新做出来。")
                    .fixedSize(horizontal: false, vertical: true)
                Text("我想把这个拼图软件一点点打磨好。使用中遇到问题，或有任何建议，欢迎联系我。")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("微信：\(AppIdentity.wechatID)").textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AppIdentity.wechatID, forType: .string)
                        copied = true
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(.borderless).help(copied ? "已复制微信号" : "复制微信号")
                        .accessibilityLabel("复制微信号")
                    Spacer()
                    Link(destination: AppIdentity.authorPage) { Image(systemName: "arrow.up.right.square") }
                        .help("作者 GitHub 主页").accessibilityLabel("作者 GitHub 主页")
                }.font(.callout)
            }
            Divider()
            HStack {
                Text("为爱发电，感谢支持。").foregroundStyle(.secondary)
                Spacer()
                Button { openWindow(id: "support-author") } label: { Label("支持作者", systemImage: "heart") }
                    .buttonStyle(.borderedProminent)
            }
        }.font(.body).padding(28).frame(width: 520)
            .background(Color(NSColor.windowBackgroundColor))
            .preferredColorScheme(theme == 2 ? .dark : .light)
    }
}

enum SupportMethod: String, CaseIterable, Identifiable {
    case wechat = "微信", alipay = "支付宝"
    var id: String { rawValue }
    var assetName: String { self == .wechat ? "WeChatSupport" : "AlipaySupport" }
}

struct SupportAuthorView: View {
    @State private var method: SupportMethod = .wechat
    @AppStorage("colorSchemeStyle") private var theme = AppPreferences.defaultTheme

    init(method: SupportMethod = .wechat) {
        _method = State(initialValue: method)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("支持作者").font(.title2.weight(.semibold))
            Text("AoiStitcher 免费开源。如果它帮到了你，欢迎打赏支持后续开发。")
                .fixedSize(horizontal: false, vertical: true)
            Picker("打赏方式", selection: $method) {
                ForEach(SupportMethod.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Image(method.assetName).resizable().interpolation(.none).scaledToFit()
                .frame(maxWidth: .infinity).frame(height: 380)
                .accessibilityLabel("\(method.rawValue)收款二维码")
            Text("用手机\(method.rawValue)扫码，金额由你决定。")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }.padding(24).frame(width: 400)
            .background(Color(NSColor.windowBackgroundColor))
            .preferredColorScheme(theme == 2 ? .dark : .light)
    }
}
