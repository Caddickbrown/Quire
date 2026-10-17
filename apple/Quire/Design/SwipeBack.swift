//
//  SwipeBack.swift
//  Quire
//
//  Quire draws its own top bar, so the system one is hidden, and hiding it also
//  switches off the swipe-from-the-edge gesture that goes back. This puts the
//  gesture back, for any screen that isn't the root of its stack.
//

#if os(iOS)

import UIKit

extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    open override func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

#endif
