import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusController: NSObject {
    private let model: WatchModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var observation: AnyCancellable?

    init(model: WatchModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: Dashboard(model: model) { [weak self] height in
            self?.resize(height: height)
        })
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
        }
        updateStatus()
        observation = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange 在赋值前发送，下一轮主队列再读取状态。
            DispatchQueue.main.async { self?.updateStatus() }
        }
    }

    private func updateStatus() {
        let label = "AI落地安全检测：\(model.title)"
        let image = NSImage(systemSymbolName: model.icon, accessibilityDescription: label)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }

    private func resize(height: CGFloat) {
        // 同步原生弹窗的真实尺寸，避免只缩小 SwiftUI 内容后留下透明外层。
        let size = NSSize(width: 420, height: height)
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
