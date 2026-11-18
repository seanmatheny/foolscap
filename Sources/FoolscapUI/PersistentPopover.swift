import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public extension View {
    /// A popover that stays up while Foolscap is in the background: SwiftUI's `.popover` on the
    /// Mac is a transient `NSPopover`, which closed the moment another app came to the front, and
    /// a task's half-written notes went with it when something was looked up elsewhere to copy.
    /// This one closes on a click elsewhere in its own window, on ⎋, or when `isPresented` is set
    /// false (Save). On the phone it is the system popover.
    func persistentPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .bottom,
                                          @ViewBuilder content: @escaping () -> Content) -> some View {
        #if canImport(AppKit)
        background(PopoverAnchor(isPresented: isPresented, arrowEdge: arrowEdge, content: content))
        #else
        popover(isPresented: isPresented, arrowEdge: arrowEdge, content: content)
        #endif
    }
}

#if canImport(AppKit)
/// An invisible view the popover is shown relative to; the coordinator owns the `NSPopover`.
private struct PopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        if isPresented {
            if let popover = coordinator.popover, popover.isShown {
                (popover.contentViewController as? NSHostingController<Content>)?.rootView = content()
            } else {
                coordinator.show(content(), relativeTo: view, edge: arrowEdge)
            }
        } else {
            coordinator.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>?
        var popover: NSPopover?
        private var monitor: Any?

        func show(_ content: Content, relativeTo view: NSView, edge: Edge) {
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.contentViewController = hosting
            popover.delegate = self
            self.popover = popover
            let rectEdge: NSRectEdge = switch edge {
            case .top: .minY
            case .leading: .minX
            case .trailing: .maxX
            case .bottom: .maxY
            }
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: rectEdge)
            // A click elsewhere in the window it belongs to closes it (as a semi-transient popover
            // would); a click in another app or window leaves it. ⎋ closes it from either window.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self, weak view] event in
                guard let self, let popover = self.popover, popover.isShown else { return event }
                let own = popover.contentViewController?.view.window
                if event.type == .keyDown {
                    if event.keyCode == 53, event.window === own || event.window === view?.window {
                        self.close()
                        return nil
                    }
                } else if event.window !== own, event.window === view?.window {
                    self.close()
                }
                return event
            }
        }

        func close() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let popover, popover.isShown else { return }
            popover.close()
        }

        func popoverDidClose(_ notification: Notification) {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            popover = nil
            if isPresented?.wrappedValue == true { isPresented?.wrappedValue = false }
        }
    }
}
#endif
