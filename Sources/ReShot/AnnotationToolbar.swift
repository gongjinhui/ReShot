import AppKit

/// Shared controls for screenshot and recording annotations.
private final class AnnotationButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AnnotationToolbar: NSVisualEffectView {
    private let document: AnnotationDocument
    private let refresh: () -> Void
    var toolChanged: ((MarkTool) -> Void)?
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    private let color = NSColorWell()
    private let width = NSSlider(value: 4,minValue: 2,maxValue: 16,target: nil,action: nil)
    private var tools: [NSButton] = []
    private let widthPopover = NSPopover()
    private let widthValue = NSTextField(labelWithString: "4 px")
    private(set) var preferredSize = NSSize(width: 473,height: 32)
    convenience init(preview: ImagePreview) {
        self.init(document: preview.annotations,refresh: { [weak preview] in preview?.refreshAnnotations() })
    }
    init(document: AnnotationDocument,recording: Bool = false,refresh: @escaping () -> Void) {
        self.document = document
        self.refresh = refresh
        super.init(frame: .zero)
        material = .menu; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 8
        let symbols = ["cursorarrow", "rectangle", "circle", "line.diagonal", "arrow.up.right", "pencil.tip", "square.grid.3x3.fill", "textformat", "1.circle", "highlighter"]
        var controls: [NSView] = []
        for (index, tool) in MarkTool.allCases.enumerated() {
            if recording && tool == .mosaic { continue }
            let title = recording && tool == .select ? "操作桌面" : tool.rawValue
            let b = AnnotationButton(image: NSImage(systemSymbolName: symbols[index],accessibilityDescription: title)!, target: self, action: #selector(selectTool(_:)))
            b.tag = index; b.bezelStyle = .texturedRounded; b.setButtonType(.toggle); b.toolTip = title
            b.setAccessibilityLabel(title); b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            tools.append(b); controls.append(b)
        }
        tools[0].state = .on
        color.colorWellStyle = .default; color.controlSize = .small
        color.heightAnchor.constraint(equalToConstant: 24).isActive = true
        color.color = .systemRed; color.target = self; color.action = #selector(settings)
        color.toolTip = "颜色与透明度"; color.widthAnchor.constraint(equalToConstant: 26).isActive = true
        NSColorPanel.shared.showsAlpha = true
        width.target = self; width.action = #selector(settings); width.isContinuous = true; width.setAccessibilityLabel("标注粗细")
        let thickness = AnnotationButton(image: NSImage(systemSymbolName: "slider.horizontal.3",accessibilityDescription: "标注粗细")!,target: self,action: #selector(showWidth(_:)))
        thickness.bezelStyle = .texturedRounded; thickness.toolTip = "标注粗细"; thickness.setAccessibilityLabel("标注粗细")
        thickness.widthAnchor.constraint(equalToConstant: 26).isActive = true
        controls += [color,thickness]
        let options = NSView(frame: CGRect(x: 0,y: 0,width: 184,height: 44))
        width.frame = CGRect(x: 10,y: 10,width: 112,height: 24); widthValue.frame = CGRect(x: 130,y: 12,width: 48,height: 20)
        options.addSubview(width); options.addSubview(widthValue)
        let controller = NSViewController(); controller.view = options
        widthPopover.contentViewController = controller; widthPopover.contentSize = options.frame.size; widthPopover.behavior = .transient
        let history = [("撤销","arrow.uturn.backward",#selector(undo)),("重做","arrow.uturn.forward",#selector(redo))]
        let actions = recording ? [("清空标注","trash",#selector(clearMarks))] : [("取消 Esc","xmark",#selector(abandon)),("确认保存 ↵","checkmark",#selector(accept))]
        for (title, symbol, action) in history + actions {
            let b = AnnotationButton(image: NSImage(systemSymbolName: symbol,accessibilityDescription: title)!,target: self,action: action)
            b.bezelStyle = .texturedRounded; b.toolTip = title; b.setAccessibilityLabel(title)
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            if action == #selector(accept) { b.keyEquivalent = "\r" }
            if action == #selector(abandon) { b.keyEquivalent = "\u{1b}" }
            controls.append(b)
        }
        for button in tools { button.controlSize = .small; button.heightAnchor.constraint(equalToConstant: 24).isActive = true }
        for button in controls.compactMap({ $0 as? NSButton }) where !tools.contains(button) { button.controlSize = .small; button.heightAnchor.constraint(equalToConstant: 24).isActive = true }
        preferredSize.width = CGFloat(controls.count*26+(controls.count-1)*3+12)
        let row = NSStackView(views: controls); row.spacing = 3; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 6),row.trailingAnchor.constraint(equalTo: trailingAnchor,constant: -6),row.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { }
    override func mouseDragged(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func selectTool(_ sender: NSButton) {
        tools.forEach { $0.state = $0 === sender ? .on : .off }
        document.tool = MarkTool.allCases[sender.tag]
        toolChanged?(document.tool)
    }
    @objc private func showWidth(_ sender: NSButton) {
        if widthPopover.isShown { widthPopover.close() }
        else { widthPopover.show(relativeTo: sender.bounds,of: sender,preferredEdge: .minY) }
    }
    @objc private func settings() {
        document.color = color.color; document.width = CGFloat(width.doubleValue)
        widthValue.stringValue = "\(Int(width.doubleValue.rounded())) px"
    }
    @objc private func undo() { document.undo(); refresh() }
    @objc private func redo() { document.redo(); refresh() }
    @objc private func clearMarks() {
        guard !document.marks.isEmpty else { return }
        document.checkpoint(); document.marks.removeAll(); refresh()
    }
    func dismissOptions() { widthPopover.close(); NSColorPanel.shared.orderOut(nil) }
    @objc private func accept() { widthPopover.close(); confirm?() }
    @objc private func abandon() { widthPopover.close(); cancel?() }
}
