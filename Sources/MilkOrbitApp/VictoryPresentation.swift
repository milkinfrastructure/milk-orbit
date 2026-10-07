import UIKit
import OrbitCore

/// Keep both decision actions reachable while the warning scrolls.
@MainActor final class CampaignRestartConfirmation: UIViewController {
    private let cabinet = CabinetShell()
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let actions = UIStackView()
    private let heading = UILabel()
    private let cancel = ArcadeButton(type: .custom)
    private let restart = ArcadeButton(type: .custom)
    private let onDecision: (Bool) -> Void
    private var finishing = false
    private var cancelWidth: NSLayoutConstraint?

    init(onDecision: @escaping (Bool) -> Void) {
        self.onDecision = onDecision
        super.init(nibName: nil, bundle: nil)
        // Preserve the result beneath this opaque modal; presentation and Cancel
        // do not trigger a game disappearance/save or destroy its controls.
        modalPresentationStyle = .overFullScreen
        isModalInPresentation = true
    }
    required init?(coder: NSCoder) { fatalError("Use init(onDecision:)") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.black
        view.accessibilityIdentifier = "campaignRestartConfirmation"
        view.accessibilityViewIsModal = true
        view.addSubview(cabinet)
        view.addSubview(scroll)
        view.addSubview(actions)
        scroll.indicatorStyle = .white
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = false
        content.axis = .vertical; content.spacing = 16
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        heading.text = "Start over?"; heading.numberOfLines = 0
        heading.textColor = Palette.white; heading.accessibilityTraits = .header
        Palette.applyTypeface(to: heading, weight: .bold)
        content.addArrangedSubview(heading)
        let warning = UILabel()
        warning.text = "Clear progress, records and routes. Return to sector 1.\n\nPreferences and learned controls stay. This can’t be undone."
        warning.numberOfLines = 0; warning.textColor = Palette.white
        Palette.applyTypeface(to: warning)
        content.addArrangedSubview(warning)
        actions.spacing = 12; actions.distribution = .fillEqually
        for (button, title, identifier, confirmed) in [
            (cancel, "Cancel", "cancelCampaignRestart", false),
            (restart, "Start over", "confirmCampaignRestart", true)
        ] {
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = identifier
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            Palette.button(button, color: confirmed ? Palette.pink : Palette.white)
            button.addAction(UIAction { [weak self] _ in self?.finish(confirmed) }, for: .touchUpInside)
            actions.addArrangedSubview(button)
        }
        cancelWidth = cancel.widthAnchor.constraint(equalToConstant: 0)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (self: CampaignRestartConfirmation, _) in self.view.setNeedsLayout()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        cabinet.frame = view.bounds
        var safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 24, dy: 16)
        if #available(iOS 27.1, *) {
            let reserved = (view.reservedRegions(kind: .division) + view.reservedRegions(kind: .occlusion)).map(\.frame)
            safe = CabinetLayout.presentationArea(in: safe, avoiding: reserved)
        }
        let font = Palette.typeface(weight: .bold, compatibleWith: traitCollection)
        let titleWidths = ["Cancel", "Start over"].map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 32 }
        let requiredWidth = titleWidths.reduce(0, +) + actions.spacing
        // Unequal labels should not force a tall two-row footer. Give each its
        // measured width and half the spare space, preserving room to read.
        let horizontal = safe.width >= requiredWidth
        if !horizontal { cancelWidth?.isActive = false }
        actions.axis = horizontal ? .horizontal : .vertical
        actions.distribution = horizontal ? .fill : .fillEqually
        if horizontal {
            cancelWidth?.constant = titleWidths[0] + (safe.width - requiredWidth) / 2
            cancelWidth?.isActive = true
        }
        let buttonWidth = horizontal ? titleWidths[1] + (safe.width - requiredWidth) / 2 : safe.width
        let titleHeight = ("Start over" as NSString).boundingRect(
            with: CGSize(width: max(1, buttonWidth - 32), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
        let buttonHeight = max(48, ceil(titleHeight) + 24)
        let actionsHeight = horizontal ? buttonHeight : buttonHeight * 2 + actions.spacing
        actions.frame = CGRect(x: safe.minX, y: safe.maxY - actionsHeight, width: safe.width, height: actionsHeight)
        scroll.frame = CGRect(x: safe.minX, y: safe.minY, width: safe.width,
            height: max(0, actions.frame.minY - safe.minY - 16))
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: heading)
        if scroll.contentSize.height > scroll.bounds.height { scroll.flashScrollIndicators() }
    }
    override func accessibilityPerformEscape() -> Bool { finish(false); return true }
    private func finish(_ confirmed: Bool) {
        guard !finishing else { return }
        finishing = true; cancel.isEnabled = false; restart.isEnabled = false
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [onDecision] in onDecision(confirmed) }
    }
}

extension FlightRecord {
    var title: String { isFinalSector ? "Final sector complete" : "Sector complete" }
    var sectorText: String { "Sector \(sectorIndex + 1) of \(sectorCount) · \(sectorName)" }
    var layoutText: String {
        "\(holes) \(holes == 1 ? "hole" : "holes") · \(pull.formatted(.number.precision(.fractionLength(0...1)))) pull"
    }
    var attemptsText: String { "\(launches) \(launches == 1 ? "launch" : "launches") this visit" }
    var provenanceText: String { assisted ? "Solution used in this sector.\nIndependent bests unchanged." : "Independent flight" }
    var challengeText: String { assisted ? "Find your own route. Reset starts independent play." : "A new route. A little less pull. Go again." }
    var shareText: String { "Milk Orbit — \(title)\n\(sectorText)\n\(layoutText) · \(attemptsText)\n\(provenanceText)\n\(challengeText)" }
}

/// Cached trophy artwork with a finite, skippable celebration.
@MainActor final class VictoryContentView: UIView {
    private let stack = UIStackView()
    private let trophy = UIView()
    private let carton = UIImageView(image: Palette.carton)
    private let plinth = PaintedMaterial.surface(compact: true)
    private let line = UIView()
    private var reveal: UIViewPropertyAnimator?
    private let record: FlightRecord

    init(record: FlightRecord, records: String? = nil) {
        self.record = record
        super.init(frame: .zero)
        stack.axis = .vertical; stack.spacing = 8
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        if record.isFinalSector {
            trophy.heightAnchor.constraint(equalToConstant: 132).isActive = true
            stack.addArrangedSubview(trophy)
            trophy.addSubview(plinth); trophy.addSubview(line); trophy.addSubview(carton)
            for view in [carton, plinth, line] { view.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([
                carton.centerXAnchor.constraint(equalTo: trophy.centerXAnchor),
                carton.topAnchor.constraint(equalTo: trophy.topAnchor),
                carton.widthAnchor.constraint(equalToConstant: 120), carton.heightAnchor.constraint(equalToConstant: 116),
                plinth.centerXAnchor.constraint(equalTo: trophy.centerXAnchor),
                plinth.topAnchor.constraint(equalTo: trophy.topAnchor, constant: 114),
                plinth.widthAnchor.constraint(equalToConstant: 148), plinth.heightAnchor.constraint(equalToConstant: 16),
                line.centerXAnchor.constraint(equalTo: trophy.centerXAnchor),
                line.topAnchor.constraint(equalTo: trophy.topAnchor, constant: 115),
                line.widthAnchor.constraint(equalToConstant: 128), line.heightAnchor.constraint(equalToConstant: 3)
            ])
            carton.contentMode = .scaleAspectFit; carton.layer.magnificationFilter = .nearest
            line.backgroundColor = Palette.teal
            trophy.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(settle)))
            trophy.isAccessibilityElement = false
        }
        addLabel(record.sectorText, bold: true)
        addLabel(record.layoutText)
        addLabel(record.attemptsText)
        addLabel(record.provenanceText, bold: record.assisted)
        if let records { addLabel(records) }
        addLabel(record.challengeText)
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(record:)") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc nonisolated private func motionChanged() { Task { @MainActor [weak self] in self?.settle() } }
    private func addLabel(_ text: String, bold: Bool = false) {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        Palette.applyTypeface(to: label, weight: bold ? .bold : .medium)
        label.textColor = Palette.white; stack.addArrangedSubview(label)
    }
    func celebrate() {
        guard record.isFinalSector, !UIAccessibility.isReduceMotionEnabled,
              !UIAccessibility.isVoiceOverRunning, window != nil else { return }
        settle()
        carton.alpha = 0; carton.transform = CGAffineTransform(translationX: 0, y: 12)
        line.alpha = 0
        let animation = UIViewPropertyAnimator(duration: 0.8, dampingRatio: 1) { [weak self] in
            self?.carton.alpha = 1; self?.carton.transform = .identity; self?.line.alpha = 1
        }
        reveal = animation
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Skip celebration") { [weak self] _ in self?.settle(); return true }]
        animation.addCompletion { [weak self] _ in self?.reveal = nil; self?.accessibilityCustomActions = nil }
        animation.startAnimation()
    }
    @objc func settle() {
        reveal?.stopAnimation(true); reveal = nil
        carton.layer.removeAllAnimations(); line.layer.removeAllAnimations()
        carton.alpha = 1; carton.transform = .identity; line.alpha = 1
        accessibilityCustomActions = nil
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { settle() } }
}

/// One lazy, reusable image per immutable record; UIKit owns sharing and cancellation.
@MainActor final class VictoryShareItem {
    let record: FlightRecord
    private lazy var image: UIImage = render()
    // A single bounded PNG gives Files/AirDrop a useful filename and preserves
    // crisp artwork. Failure falls back to the in-memory native image item.
    private lazy var imageURL: URL? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MilkOrbit-Result.png")
        guard let data = image.pngData() else { return nil }
        do { try data.write(to: url, options: .atomic); return url }
        catch { return nil }
    }()
    init(record: FlightRecord) { self.record = record }
    var activityItems: [Any] {
        // UIKit may load providers off-main. Pass immutable native values, not
        // a main-actor UIActivityItemSource callback that can trap on that queue.
        if let imageURL { return [imageURL, record.shareText] }
        return [image, record.shareText]
    }
    private func render() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
        format.preferredRange = .standard
        let size = CGSize(width: 360, height: 450)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            Palette.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
            PaintedMaterial.panel?.draw(in: CGRect(x: 8, y: 8, width: 344, height: 434))
            let font = UIFont.monospacedSystemFont(ofSize: Palette.textSize, weight: .medium)
            let bold = UIFont.monospacedSystemFont(ofSize: Palette.textSize, weight: .bold)
            @MainActor func text(_ value: String, y: CGFloat, height: CGFloat, strong: Bool = false) {
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
                (value as NSString).draw(in: CGRect(x: 24, y: y, width: 312, height: height), withAttributes: [
                    .font: strong ? bold : font, .foregroundColor: Palette.white, .paragraphStyle: paragraph
                ])
            }
            text("MILK ORBIT", y: 28, height: 24, strong: true)
            Palette.carton?.draw(in: CGRect(x: 128, y: 63, width: 104, height: 104))
            PaintedMaterial.rim?.draw(in: CGRect(x: 118, y: 162, width: 124, height: 14))
            Palette.teal.setFill(); context.fill(CGRect(x: 124, y: 163, width: 112, height: 3))
            text(record.title.uppercased(), y: 194, height: 44, strong: true)
            text(record.sectorText, y: 232, height: 48)
            text(record.layoutText, y: 292, height: 24, strong: true)
            text(record.attemptsText, y: 320, height: 24)
            text(record.assisted ? "SOLUTION USED\nIndependent bests unchanged" : "INDEPENDENT FLIGHT", y: 359, height: 48)
            text(record.assisted ? "Find your own route." : "Can you use less pull?", y: 410, height: 24)
        }
    }
}
