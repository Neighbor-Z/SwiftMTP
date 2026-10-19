import Cocoa
import UniformTypeIdentifiers

class ShareViewController: NSViewController {

    private let statusLabel = NSTextField(labelWithString: String(localized: "Opening SwiftMTP…"))
    private var hasStartedShare = false

    override func loadView() {
        // Create a small visible view so we can confirm the extension actually loads.
        // This also prevents the system from discarding a zero-size invisible extension.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasStartedShare else { return }
        hasStartedShare = true
        processShare()
    }

    private func processShare() {
        guard let context = self.extensionContext else {
            dismiss()
            return
        }

        let providers = context.inputItems.compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        // NSItemProvider callbacks may run concurrently. Collect results on the
        // main queue and keep Finder's selection order.
        var fileURLs = Array<URL?>(repeating: nil, count: providers.count)
        var scopedURLs: [URL] = []
        var loadError: Error?
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            let type: String
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                type = UTType.fileURL.identifier
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                type = UTType.url.identifier
            } else {
                loadError = shareError(String(localized: "The selection contains an unsupported item."))
                continue
            }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                // Keep the provider's original URL and its access grant alive
                // until Launch Services has delivered the open-documents event.
                let scoped: Bool
                if let url, url.isFileURL {
                    scoped = url.startAccessingSecurityScopedResource()
                } else {
                    scoped = false
                }
                DispatchQueue.main.async {
                    defer { group.leave() }
                    if scoped, let url { scopedURLs.append(url) }
                    if let error {
                        loadError = error
                    } else if let url, url.isFileURL {
                        fileURLs[index] = url
                    } else {
                        loadError = self.shareError(String(localized: "The selection does not contain a file URL."))
                    }
                }
            }
        }

        group.notify(queue: .main) {
            let urls = fileURLs.compactMap { $0 }
            guard loadError == nil, !urls.isEmpty else {
                scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                context.cancelRequest(withError: loadError ?? self.shareError(String(localized: "No files found.")))
                return
            }

            // Launch Services transfers the user-selected file URLs and their
            // sandbox access to the containing app, launching it if necessary.
            // A path string or a custom URL containing a path cannot do that.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            NSWorkspace.shared.open(urls, withApplicationAt: self.getParentAppURL(), configuration: config) { _, error in
                DispatchQueue.main.async {
                    scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                    if let error {
                        context.cancelRequest(withError: error)
                    } else {
                        context.completeRequest(returningItems: nil, completionHandler: nil)
                    }
                }
            }
        }
    }

    private func dismiss() {
        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func shareError(_ message: String) -> NSError {
        NSError(domain: "SwiftMTP.ShareExtension", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Helpers

    /// Resolve the containing app bundle path.
    /// Extension lives at: SwiftMTP.app/Contents/PlugIns/SendToSwiftMTPExtension.appex
    /// So the app bundle is 3 levels up from the extension's own bundle.
    private func getParentAppURL() -> URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent() // PlugIns/
            .deletingLastPathComponent() // Contents/
            .deletingLastPathComponent() // SwiftMTP.app
    }

}
