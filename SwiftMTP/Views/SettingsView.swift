import SwiftUI

struct SettingsView: View {
    @AppStorage("fileListFontSize") private var fileListFontSize: Int = 12
    @AppStorage("doubleClickToOpenFile") private var doubleClickToOpenFile: Bool = true
    @AppStorage("fileIconSize") private var fileIconSizeRaw: String = FileIconSize.medium.rawValue
    @AppStorage("aiMode") private var aiMode: String = "none"
    @AppStorage("aiApiUrl") private var aiApiUrl: String = ""
    @AppStorage("aiModelName") private var aiModelName: String = ""
    @AppStorage("aiApiKey") private var aiApiKey: String = ""
    @AppStorage("aiApiFormat") private var aiApiFormat: String = "openai"
    @AppStorage("aiEnableAdvanced") private var aiEnableAdvanced: Bool = false
    @AppStorage("aiMaxTokens") private var aiMaxTokens: Int = 4096
    @AppStorage("aiThinkingMode") private var aiThinkingMode: Bool = true
    @AppStorage("aiReasoningLevel") private var aiReasoningLevel: String = "low"
    @AppStorage("hasAcceptedAIDisclaimer") private var hasAcceptedAIDisclaimer: Bool = false
    @State private var isShowingAIDisclaimer: Bool = false
    @State private var isShowingAIFeaturesIntro: Bool = false
    @State private var previousAIMode: String = "none"
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedTab: Int = 0
    
    private var currentHeight: CGFloat {
        switch selectedTab {
        case 0:
            return 220
        case 1:
            if aiMode == "api" {
                return aiEnableAdvanced ? 370 : 260
            } else {
                return 220
            }
        case 2:
            return 220
        default:
            return 220
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(String(localized: "Font Size"), selection: $fileListFontSize) {
                        ForEach(10...16, id: \.self) { size in
                            Text("\(size)").tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300)

                    Picker(String(localized: "Icon Size"), selection: $fileIconSizeRaw) {
                        Text(String(localized: "Small")).tag(FileIconSize.small.rawValue)
                        Text(String(localized: "Medium")).tag(FileIconSize.medium.rawValue)
                        Text(String(localized: "Large")).tag(FileIconSize.large.rawValue)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300)
                    .help(String(localized: "Icon size used in the icon view.", comment: "Tooltip for icon size setting"))

                    HStack {
                        Text(String(localized: "List Action"))
                        Toggle(String(localized: "Double-click to open files", comment: "Setting to open files on double click"), isOn: $doubleClickToOpenFile)
                            .help(String(localized: "When enabled, double-clicking a file exports it to a local cache (if not already cached) and opens it with the default application.", comment: "Tooltip for double-click to open file setting"))
                    }
                }
            }
            .padding(20)
            .tabItem {
                Label(String(localized: "General", comment: "Tab showing general settings"), systemImage: "gear")
            }
            .tag(0)

            Form {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(String(localized: "AI Mode"), selection: $aiMode) {
                        Text("API").tag("api")
                        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
                            Text(String(localized: "Apple Foundation Models")).tag("apple")
                        }
                        Text(String(localized: "None")).tag("none")
                    }
                    .pickerStyle(.menu)

                    if aiMode == "api" {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("API Format", selection: $aiApiFormat) {
                                Text("OpenAI").tag("openai")
                                Text("Anthropic").tag("anthropic")
                            }
                            .pickerStyle(.segmented)
                            .padding(.bottom, 4)

                            TextField(String(localized: "API Endpoint"), text: $aiApiUrl)
                            TextField(String(localized: "Model Name"), text: $aiModelName)
                            SecureField("API Key", text: $aiApiKey)
                            
                            Toggle(String(localized: "Enable Advanced Settings"), isOn: $aiEnableAdvanced)
                                .padding(.top, 4)
                            
                            if aiEnableAdvanced {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(String(localized: "Max Output Tokens"))
                                        TextField("", value: $aiMaxTokens, format: .number)
                                            .frame(width: 120)
                                            .disabled(aiApiFormat=="openai")
                                    }
                                    
                                    Picker(String(localized: "Thinking Mode"), selection: $aiThinkingMode) {
                                        Text(String(localized: "Enabled")).tag(true)
                                        Text(String(localized: "Disabled")).tag(false)
                                    }
                                    .pickerStyle(.radioGroup)
                                    
                                    Picker(String(localized: "Reasoning Level"), selection: $aiReasoningLevel) {
                                        Text(String(localized: "None")).tag("none")
                                        Text(String(localized: "Low")).tag("low")
                                        Text(String(localized: "Medium")).tag("medium")
                                    }
                                    .pickerStyle(.segmented)
                                    .disabled(!aiThinkingMode)
                                }
                                .padding(.leading, 20)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 20)
                    }
                }
            }
            .padding(20)
            .tabItem {
                Label("AI", systemImage: "sparkles")
            }
            .tag(1)
            .onChange(of: aiMode) { newValue in
                if newValue != "none" && !hasAcceptedAIDisclaimer {
                    isShowingAIDisclaimer = true
                } else {
                    previousAIMode = newValue
                }
            }
            .sheet(isPresented: $isShowingAIDisclaimer) {
                AIDisclaimerView(
                    onAccept: {
                        hasAcceptedAIDisclaimer = true
                        previousAIMode = aiMode
                        // Delay slightly to ensure first sheet is fully dismissed
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isShowingAIFeaturesIntro = true
                        }
                    },
                    onCancel: {
                        aiMode = "none"
                        previousAIMode = "none"
                    }
                )
            }
            .sheet(isPresented: $isShowingAIFeaturesIntro) {
                AIFeaturesIntroView()
            }
            .onAppear {
                previousAIMode = aiMode
            }
            
            Form {
                VStack(alignment: .leading, spacing: 12) {
                    Image(colorScheme == .dark ? "favicon-32x32-dark" : "favicon-32x32")
                    Text("SwiftMTP")
                        .font(.system(size: 20, weight: .semibold))
                    Text(String(localized: "A modern MTP device management tool for macOS.", comment: "Settings App Description"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 16) {
                        Button {
                            if let url = URL(string: "https://neighbor-z.github.io/swiftmtp-website") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "globe")
                        }
                        .help(String(localized: "Website", comment: "Website link tooltip"))
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Button {
                            if let url = URL(string: "https://github.com/Neighbor-Z/SwiftMTP") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }
                        .help("GitHub")
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        
                        Button {
                            if let url = URL(string: "https://buymeacoffee.com/neighbor_z") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "cup.and.saucer.fill")
                        }
                        .help(String(localized: "Buy Me a Coffee", comment: "Donation link tooltip"))
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    
                    Divider()
                        .padding(.vertical, 4)
                        
                    HStack {
                        Text("v\(UpdateChecker.composedAppVersion())")
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        UpdateButtonRow()
                    }
                }
            }
            .padding(20)
            .tabItem {
                Label(String(localized: "Info & Update", comment: "Tab showing info and update"), systemImage: "info.circle")
            }
            .tag(2)
        }
        .frame(width: 400, height: currentHeight)
        .animation(.spring(duration: 0.3), value: selectedTab)
        .animation(.spring(duration: 0.3), value: aiMode)
        .animation(.spring(duration: 0.3), value: aiEnableAdvanced)
        .navigationTitle(String(localized: "Settings"))
    }
}

// MARK: - Update Button Row

private struct UpdateButtonRow: View {
    @StateObject private var checker = UpdateChecker.shared

    var body: some View {
        HStack(spacing: 6) {
            // Left-side status indicator
            Group {
                switch checker.state {
                case .checking:
                    ProgressView()
                        .controlSize(.small)
                case .updateAvailable:
                    Text(String(localized: "Update available", comment: "Update available status"))
                        .foregroundStyle(.green)
                        .font(.callout)
                        .help(String(localized: "Update available"))
                case .upToDate:
                    Text(String(localized: "App is up to date.", comment: "App is up to date status"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .help(String(localized: "App is up to date."))
                case .failed:
                    Text(String(localized: "Check failed", comment: "Update check failed status"))
                        .foregroundStyle(.red)
                        .font(.callout)
                        .help(String(localized: "Check failed"))
                case .idle:
                    EmptyView()
                }
            }

            // Action button
            switch checker.state {
            case .updateAvailable(let version, let url):
                Button(String(format: String(localized: "Download %@", comment: "Download update button"), version)) {
                    NSWorkspace.shared.open(url)
                }
                .id("download-update-button")

            case .checking:
                Button(String(localized: "Check for Updates...", comment: "Settings Update Button")) {}
                    .disabled(true)
                    .id("check-updates-button-checking")

            default:
                Button(String(localized: "Check for Updates...", comment: "Settings Update Button")) {
                    Task { await checker.checkForUpdates() }
                }
                .id("check-updates-button")
            }
        }
    }
}

// MARK: - AI Disclaimer View

struct AIDisclaimerView: View {
    let onAccept: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.purple)
            
            Text("AI Features Notice")
                .font(.title2)
                .bold()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DisclaimerRow(icon: "exclamationmark.triangle", title: String(localized: "Accuracy"), description: String(localized: "AI can make mistakes. Always verify results before performing critical file operations."))
                    DisclaimerRow(icon: "apple.intelligence", title: String(localized: "Apple Foundation Models"), description: String(localized: "Apple Foundation Models are on-device models that will process all information locally on your Mac. Requires macOS 26 or later with Apple Intelligence enabled."))
                    DisclaimerRow(icon: "lock.shield", title: String(localized: "Data Privacy"), description: String(localized: "In API mode, your item metadata such as names, types, and sizes will be sent to the provider. The contents of your files are never uploaded or shared."))
                    DisclaimerRow(icon: "creditcard", title: String(localized: "API Costs"), description: String(localized: "In API mode, you are responsible for any usage costs from your AI provider."))
                    DisclaimerRow(icon: "hammer", title: String(localized: "Developing"), description: String(localized: "These features are still under development and subject to change in future updates."))
                }
                .padding(.vertical, 8)
            }
            .frame(height: 320)
            
            HStack(spacing: 12) {
                Button(String(localized: "Cancel")) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .controlSize(.large)
                
                Spacer()
                
                Button(String(localized: "Agree & Enable")) {
                    onAccept()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 440)
    }
}

// MARK: - AI Features Intro View

struct AIFeaturesIntroView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.purple)
                Text("Meet AI Features")
                    .font(.title)
                    .bold()
                Text("Unlock powerful new ways to manage your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FeatureRow(
                        icon: "sparkle.magnifyingglass",
                        title: String(localized: "Natural Language Search"),
                        description: String(localized: "Find your files naturally. Just type what you're looking for, like 'Photos of last week' or 'Work documents from 2024'.")
                    )
                    
                    FeatureRow(
                        icon: "info.circle.fill",
                        title: String(localized: "Device Info Analysis"),
                        description: String(localized: "Get smart insights about your device hardware, connectivity status, and potential performance optimizations.")
                    )
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .frame(height: 160)
            
            Button(String(localized: "Get Started")) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(width: 440, height: 400)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.purple)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
    }
}

private struct DisclaimerRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
