import SwiftUI
import UIKit

@MainActor @Observable
final class ItemPanelPresentation {
    let id = UUID()
    var closing = false
    @ObservationIgnored private var onClosed: (() -> Void)?

    func dismiss(_ onClosed: @escaping () -> Void) {
        guard !closing else { return }
        self.onClosed = onClosed
        closing = true
    }

    func complete() {
        let completion = onClosed
        onClosed = nil
        completion?()
    }
}

private struct NativeItemSheet<SheetContent: View>: UIViewControllerRepresentable {
    let presentation: ItemPanelPresentation?
    let expanded: Bool
    let onDismissed: () -> Void
    let content: SheetContent
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.attachmentTransfers) private var transfers
    @Environment(\.notices) private var notices

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        // Reading it here makes SwiftUI call this update when a close starts.
        _ = presentation?.closing
        controller.update = { [weak controller] in
            guard let controller else { return }
            controller.apply(presentation: presentation, expanded: expanded,
                             background: UIColor(palette.surface), style: colorScheme == .dark ? .dark : .light,
                             content: AnyView(content.environment(\.palette, palette).environment(\.colorScheme, colorScheme).environment(\.attachmentTransfers, transfers).environment(\.notices, notices)),
                             onDismissed: onDismissed)
        }
        // Creating the hosting graph during a Feed update hoists its toolbar into Feed.
        DispatchQueue.main.async { [weak controller] in controller?.update?() }
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var update: (() -> Void)?
        private var session: ItemPanelPresentation?
        private var sheet: UIViewController?
        private var host: UIHostingController<AnyView>?
        private var presenting = false
        private var dismissing = false
        private var onDismissed: () -> Void = {}

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            update?()
        }

        func apply(presentation: ItemPanelPresentation?, expanded: Bool,
                   background: UIColor, style: UIUserInterfaceStyle, content: AnyView,
                   onDismissed: @escaping () -> Void) {
            self.onDismissed = onDismissed
            guard let presentation, view.window != nil else { return }
            if session == nil {
                guard !presentation.closing else { presentation.complete(); return }
                let outer = UIViewController()
                outer.modalPresentationStyle = .pageSheet
                let hosting = UIHostingController(rootView: content)
                outer.addChild(hosting)
                outer.view.addSubview(hosting.view)
                hosting.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    hosting.view.leadingAnchor.constraint(equalTo: outer.view.leadingAnchor),
                    hosting.view.trailingAnchor.constraint(equalTo: outer.view.trailingAnchor),
                    hosting.view.topAnchor.constraint(equalTo: outer.view.topAnchor),
                    hosting.view.bottomAnchor.constraint(equalTo: outer.view.bottomAnchor)
                ])
                hosting.didMove(toParent: outer)
                outer.sheetPresentationController?.detents = [.medium(), .large()]
                outer.sheetPresentationController?.prefersGrabberVisible = true
                outer.presentationController?.delegate = self
                session = presentation
                sheet = outer
                host = hosting
                presenting = true
                configure(expanded: expanded, background: background, style: style)
                present(outer, animated: true) { [weak self] in
                    self?.presenting = false
                    self?.update?()
                }
            } else {
                guard session?.id == presentation.id else { return }
                if sheet?.view.backgroundColor != background || sheet?.overrideUserInterfaceStyle != style {
                    host?.rootView = content
                }
                configure(expanded: expanded, background: background, style: style)
            }
            if presentation.closing && !presenting && !dismissing, let sheet {
                dismissing = true
                sheet.dismiss(animated: true) { [weak self] in self?.finished(presentation) }
            }
        }

        private func configure(expanded: Bool, background: UIColor, style: UIUserInterfaceStyle) {
            if sheet?.view.backgroundColor != background { sheet?.view.backgroundColor = background }
            if host?.view.backgroundColor != background { host?.view.backgroundColor = background }
            if sheet?.overrideUserInterfaceStyle != style { sheet?.overrideUserInterfaceStyle = style }
            guard expanded, let native = sheet?.sheetPresentationController, native.selectedDetentIdentifier != .large else { return }
            native.animateChanges { native.selectedDetentIdentifier = .large }
        }

        private func finished(_ presentation: ItemPanelPresentation) {
            guard session?.id == presentation.id else { return }
            session = nil
            sheet = nil
            host = nil
            dismissing = false
            presentation.complete()
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === sheet else { return }
            dismissing = true
            presentationController.presentedViewController.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
                guard context.isCancelled else { return }
                self?.dismissing = false
                self?.update?()
            }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === sheet, let session else { return }
            onDismissed()
            finished(session)
        }
    }
}

struct ItemPanel<PanelContent: View>: ViewModifier {
    let presentation: ItemPanelPresentation?
    let expanded: Bool
    let onDismissed: () -> Void
    @ViewBuilder let panelContent: () -> PanelContent

    func body(content: Content) -> some View {
        content.background(NativeItemSheet(presentation: presentation, expanded: expanded, onDismissed: onDismissed, content: panelContent()))
    }
}
