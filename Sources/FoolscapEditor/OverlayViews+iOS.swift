#if canImport(UIKit) && !canImport(AppKit)
import UIKit
import LinkPresentation

/// The picture under an image line on the phone, the twin of the Mac's: a tap
/// selects it (outlined in the accent colour), a long press offers Copy Image and
/// Show Markdown. Resizing by drag is the Mac's; the markdown's `|width` is honoured.
final class ResizableImageView: UIView, UIContextMenuInteractionDelegate {
    let imageView = UIImageView()
    let path: String
    var onResize: ((CGFloat) -> Void)?
    var onReveal: (() -> Void)?
    /// Copies the picture to the pasteboard; false when the file could not be read.
    var onCopy: (() -> Bool)?
    var onSelect: (() -> Void)?
    var selectionColor: UIColor = .tintColor
    /// The longest side, in pixels, the bitmap shown covers; 0 while decoding.
    var decodedPixels: CGFloat = 0
    /// Outlined in the accent colour while selected (set by the overlay controller).
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            layer.borderWidth = isSelected ? 2 : 0.5
            layer.borderColor = isSelected ? selectionColor.cgColor : UIColor.black.withAlphaComponent(0.15).cgColor
        }
    }

    /// `image` may be nil while the picture is decoded; `size` reserves its frame.
    init(image: UIImage?, size: CGSize, path: String) {
        self.path = path
        super.init(frame: CGRect(origin: .zero, size: size))
        layer.cornerRadius = 6
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onSelect?() }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        onSelect?()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.doc")) { _ in _ = self?.onCopy?() },
                UIAction(title: "Show Markdown", image: UIImage(systemName: "doc.text")) { _ in self?.onReveal?() },
            ])
        }
    }
}

/// A LinkPresentation card; the card itself opens the link on a tap, a long press
/// offers Copy Link and Show Markdown.
final class LinkCardView: UIView, UIContextMenuInteractionDelegate {
    let linkView: LPLinkView
    private let url: URL
    var onReveal: (() -> Void)?

    init(url: URL) {
        self.url = url
        linkView = LPLinkView(url: url)
        super.init(frame: CGRect(x: 0, y: 0, width: OverlayController.linkCardMaxWidth, height: OverlayController.linkCardHeight))
        linkView.frame = bounds
        linkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(linkView)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                    guard let self else { return }
                    UIPasteboard.general.url = self.url
                },
                UIAction(title: "Show Markdown", image: UIImage(systemName: "doc.text")) { _ in self?.onReveal?() },
            ])
        }
    }
}
#endif
