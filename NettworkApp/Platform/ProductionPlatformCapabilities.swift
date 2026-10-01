import Foundation

#if os(iOS)
    import SwiftUI
    import UIKit

    /// A per-scene bridge from SwiftUI to UIKit presentation. The context retains
    /// no window or controller, so closing a scene cannot keep its UIKit hierarchy
    /// alive or accidentally route a sheet to another scene.
    @MainActor
    final class IOSPresentationContext {
        private weak var anchor: UIViewController?

        var presentingViewController: UIViewController? {
            guard let anchor, anchor.viewIfLoaded?.window != nil else { return nil }
            return anchor.sceneRootController.topmostPresentedController
        }

        func bind(anchor: UIViewController) {
            self.anchor = anchor
        }

        func unbind(anchor: UIViewController) {
            guard self.anchor === anchor else { return }
            self.anchor = nil
        }
    }

    /// Install this in the SwiftUI hierarchy for the scene that owns an
    /// `IOSPresentationContext`. It never searches `UIApplication` windows.
    struct IOSPresentationContextAnchor: UIViewControllerRepresentable {
        let context: IOSPresentationContext

        func makeUIViewController(context _: Context) -> AnchorController {
            AnchorController(presentationContext: context)
        }

        func updateUIViewController(_ controller: AnchorController, context _: Context) {
            controller.presentationContext = context
            context.bind(anchor: controller)
        }

        static func dismantleUIViewController(_ controller: AnchorController, coordinator _: ()) {
            controller.presentationContext?.unbind(anchor: controller)
        }

        @MainActor
        final class AnchorController: UIViewController {
            weak var presentationContext: IOSPresentationContext?

            init(presentationContext: IOSPresentationContext) {
                self.presentationContext = presentationContext
                super.init(nibName: nil, bundle: nil)
            }

            required init?(coder: NSCoder) { nil }

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                presentationContext?.bind(anchor: self)
            }

            override func viewDidDisappear(_ animated: Bool) {
                super.viewDidDisappear(animated)
                if view.window == nil {
                    presentationContext?.unbind(anchor: self)
                }
            }
        }
    }

    private extension UIViewController {
        var sceneRootController: UIViewController {
            var controller = self
            while let parent = controller.parent {
                controller = parent
            }
            return controller
        }

        var topmostPresentedController: UIViewController {
            if let presentedViewController, !presentedViewController.isBeingDismissed {
                return presentedViewController.topmostPresentedController
            }
            if let navigation = self as? UINavigationController, let visible = navigation.visibleViewController {
                return visible.topmostPresentedController
            }
            if let tab = self as? UITabBarController, let selected = tab.selectedViewController {
                return selected.topmostPresentedController
            }
            return self
        }
    }
#endif
