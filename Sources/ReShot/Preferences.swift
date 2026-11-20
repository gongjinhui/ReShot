import AppKit
import Carbon
import ServiceManagement

struct CaptureShortcut: Codable, Equatable {
    let key: String
    let code: UInt32
    let modifiers: UInt

    init(_ key: String, _ code: Int, _ flags: NSEvent.ModifierFlags) {
        self.key = key
        self.code = UInt32(code)
        modifiers = flags.rawValue
    }

    var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    var carbonFlags: UInt32 {
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }
    var label: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control,"⌃"),(.option,"⌥"),(.shift,"⇧"),(.command,"⌘")]
        return symbols.filter { flags.contains($0.0) }.map { $0.1 }.joined() + key.uppercased()
    }
}

private final class ShortcutButton: NSButton {
    var binding: CaptureShortcut
    var onChange: ((CaptureShortcut) throws -> Void)?
    private(set) var listening = false

    init(_ binding: CaptureShortcut) {
        self.binding = binding
        super.init(frame: .zero)
        title = binding.label
        bezelStyle = .rounded
        target = self
        action = #selector(listen)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    @objc private func listen() {
        guard window?.makeFirstResponder(self) == true else { return }
        listening = true
        title = "请按组合键（Esc 取消）"
    }
    override func resignFirstResponder() -> Bool {
        listening = false
        title = binding.label
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard listening else { super.keyDown(with: event); return }
        if event.keyCode == kVK_Escape {
            listening = false; title = binding.label
            return
        }
        let flags = event.modifierFlags.intersection([.control,.option,.shift,.command])
        guard !flags.intersection([.control,.option,.command]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              key.utf8.count == 1, let byte = key.utf8.first,
              (97...122).contains(byte) || (48...57).contains(byte) else {
            NSSound.beep(); return
        }
        apply(CaptureShortcut(key, Int(event.keyCode), flags))
    }
    func apply(_ candidate: CaptureShortcut) {
        listening = false
        do {
            try onChange?(candidate)
            binding = candidate
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
        title = binding.label
    }
}

private final class PreferencesPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let button = firstResponder as? ShortcutButton, button.listening {
            button.keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum CaptureFolders {
    static let imageKey = "captureSaveFolder"
    static let videoKey = "recordingSaveFolder"

    static func url(_ key: String, in defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: key) ?? defaults.string(forKey: imageKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReShot", isDirectory: true)
    }

    static func set(_ url: URL, for key: String, in defaults: UserDefaults = .standard) {
        if key == imageKey, defaults.string(forKey: videoKey) == nil {
            defaults.set(self.url(videoKey, in: defaults).path, forKey: videoKey)
        }
        defaults.set(url.path, forKey: key)
    }
}

final class PreferencesController: NSWindowController {
    private let rows = NSStackView()
    private weak var app: AppDelegate?
    private let radius = NSSlider(value: Double(CaptureAppearance.radius()), minValue: 0, maxValue: 100, target: nil, action: nil)
    private let radiusValue = NSTextField(labelWithString: "")
    private let login = NSButton(checkboxWithTitle: "登录时打开 ReShot", target: nil, action: nil)
    private let loginStatus = NSTextField(labelWithString: "")

    init(app: AppDelegate) {
        let panel = PreferencesPanel(contentRect: NSRect(x: 0,y: 0,width: 560,height: 660),
                            styleMask: [.titled,.closable], backing: .buffered, defer: false)
        super.init(window: panel)
        self.app = app
        panel.title = "ReShot 偏好设置"
        panel.hidesOnDeactivate = false
        panel.center()
        let root = NSView()
        panel.contentView = root
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 24),
            rows.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -24),
            rows.topAnchor.constraint(equalTo: root.topAnchor,constant: 20),
            rows.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor,constant: -20)
        ])

        heading("快捷键")
        for (index, title) in AppDelegate.shortcutTitles.enumerated() {
            let button = ShortcutButton(app.shortcut(at: index))
            button.setAccessibilityLabel(title)
            button.onChange = { [weak app] shortcut in try app?.changeShortcut(at: index, to: shortcut) }
            row(title, button)
        }

        heading("保存与外观")
        folderRow("图片保存目录", key: CaptureFolders.imageKey)
        folderRow("视频保存目录", key: CaptureFolders.videoKey)
        let format = NSPopUpButton()
        format.addItems(withTitles: ["PNG（透明）", "JPEG（白底）", "TIFF（透明）"])
        format.selectItem(at: CaptureFormat.allCases.firstIndex(of: .selected()) ?? 0)
        format.target = self; format.action = #selector(changeFormat(_:))
        format.setAccessibilityLabel("保存图片格式")
        row("保存图片格式", format)
        radius.target = self; radius.action = #selector(changeRadius(_:))
        radius.isContinuous = true
        radius.setAccessibilityLabel("截图圆角")
        radius.widthAnchor.constraint(equalToConstant: 175).isActive = true
        radiusValue.widthAnchor.constraint(equalToConstant: 55).isActive = true
        refreshRadius()
        row("截图圆角", radius, radiusValue)
        let fitWhole = NSButton(checkboxWithTitle: "显示整图", target: self, action: #selector(changePreviewMode(_:)))
        fitWhole.state = app.fitsWholeImage ? .on : .off
        rows.addArrangedSubview(fitWhole)

        heading("启动")
        login.target = self; login.action = #selector(changeLogin)
        rows.addArrangedSubview(login)
        rows.addArrangedSubview(loginStatus)
        refreshLogin()
    }
    required init?(coder: NSCoder) { nil }

    func receiveRegisteredShortcut(_ binding: CaptureShortcut) -> Bool {
        guard let window, window.isKeyWindow,
              let button = window.firstResponder as? ShortcutButton, button.listening else { return false }
        button.apply(binding)
        return true
    }

    private func heading(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 15)
        rows.addArrangedSubview(label)
    }

    private func row(_ title: String, _ controls: NSView...) {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 108).isActive = true
        let row = NSStackView(views: [label] + controls)
        row.spacing = 8
        row.alignment = .centerY
        rows.addArrangedSubview(row)
    }

    private func folderRow(_ title: String, key: String) {
        let path = NSTextField(labelWithString: CaptureFolders.url(key).path)
        path.lineBreakMode = .byTruncatingMiddle
        path.widthAnchor.constraint(equalToConstant: 305).isActive = true
        path.toolTip = path.stringValue
        let choose = NSButton(title: "选择…", target: self, action: #selector(chooseFolder(_:)))
        choose.identifier = NSUserInterfaceItemIdentifier(key)
        choose.setAccessibilityLabel("选择" + title)
        row(title, path, choose)
    }

    @objc private func chooseFolder(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let window,
              let row = rows.arrangedSubviews.compactMap({ $0 as? NSStackView })
                .first(where: { $0.arrangedSubviews.contains(sender) }),
              let path = row.arrangedSubviews.dropFirst().first as? NSTextField else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = CaptureFolders.url(key)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            CaptureFolders.set(url, for: key)
            path.stringValue = url.path
            path.toolTip = url.path
        }
    }

    @objc private func changePreviewMode(_ sender: NSButton) {
        app?.fitsWholeImage = sender.state == .on
    }

    @objc private func changeFormat(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(CaptureFormat.allCases[sender.indexOfSelectedItem].rawValue, forKey: "captureImageFormat")
    }
    @objc private func changeRadius(_ sender: NSSlider) {
        CaptureAppearance.setRadius(CGFloat(sender.intValue))
        refreshRadius()
    }
    private func refreshRadius() { radiusValue.stringValue = "\(CaptureAppearance.radius().formatted()) pt" }

    override func showWindow(_ sender: Any?) {
        refreshLogin()
        super.showWindow(sender)
    }

    private func refreshLogin() {
        let status = SMAppService.mainApp.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginStatus.stringValue = status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许 ReShot。" : ""
    }

    @objc private func changeLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
        refreshLogin()
    }
}
