import UIKit

@MainActor enum Palette {
    static let white = UIColor(hex: 0xFFFFFF)
    static let black = UIColor(hex: 0x000000)
    static let teal = UIColor(hex: 0x00A092)
    static let pink = UIColor(hex: 0xED2D6C)
    static let muted = UIColor(white: 0.55, alpha: 1)
    static let textSize: CGFloat = 18
    // The original PNG has one exterior-connected, exact-black background.
    // Color-key once; retain the original colored logo pixels and source asset.
    static let carton: UIImage? = {
        guard let original = UIImage(named: "MilkCarton"), let source = original.cgImage,
              let transparent = source.copy(maskingColorComponents: [0,0,0,0,0,0]) else {
            return UIImage(named: "MilkCarton")
        }
        return UIImage(cgImage: transparent, scale: original.scale, orientation: original.imageOrientation)
    }()
    static func typeface(weight: UIFont.Weight = .medium, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: textSize, weight: weight), compatibleWith: traits)
    }
    static func applyTypeface(to label: UILabel, weight: UIFont.Weight = .medium) {
        label.font = typeface(weight: weight, compatibleWith: label.traitCollection)
        label.adjustsFontForContentSizeCategory = true
    }
    static func titleTypeface(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: .monospacedSystemFont(ofSize: 32, weight: .bold), compatibleWith: traits)
    }
    static func instrumentTypeface(compatibleWith traits:UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle:.body).scaledFont(
            for:UIFont(name:"Silkscreen-Regular",size:textSize) ?? .monospacedSystemFont(ofSize:textSize,weight:.semibold),
            compatibleWith:traits)
    }
    // Callers still own wrapping and layout; never shrink an accessibility font to fit.
    static func minimumControlHeight(lines: Int = 1, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
        max(lines > 1 ? 48 : 44,
            ceil(typeface(weight: .bold, compatibleWith: traits).lineHeight * CGFloat(max(1, lines))) + 16)
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// One reusable feedback family. Strong actions are separate from edit detents.
@MainActor final class ArcadeFeedback {
    static let shared = ArcadeFeedback()
    private let placement = UIImpactFeedbackGenerator(style: .heavy)
    private let action = UIImpactFeedbackGenerator(style: .rigid)
    private let tick = UIImpactFeedbackGenerator(style: .rigid)
    var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "orbit.hapticsMuted") }
        set { UserDefaults.standard.set(newValue, forKey: "orbit.hapticsMuted") }
    }
    func prepare() { guard !muted else { return }; placement.prepare(); action.prepare(); tick.prepare() }
    func place() { guard !muted else { return }; placement.impactOccurred(intensity: 1); placement.prepare() }
    func button() { guard !muted else { return }; action.impactOccurred(intensity: 0.95); action.prepare() }
    func detent() { guard !muted else { return }; tick.impactOccurred(intensity: 1); tick.prepare() }
}

extension Palette {
    static func button(_ button: UIButton, color: UIColor, feedback: Bool = true) {
        button.isPointerInteractionEnabled = true
        if let label = button.titleLabel { applyTypeface(to: label, weight: .bold) }
        let face: PaintedMaterial.Face = color == pink ? .pink : color == teal ? .teal : .charcoal
        button.setTitleColor(PaintedMaterial.lettering(dark: face != .charcoal), for: .normal)
        button.setTitleColor(white, for: .highlighted)
        button.setTitleColor(white, for: .selected)
        button.setTitleColor(white, for: [.selected,.highlighted])
        button.setTitleColor(UIColor(white: 0.68, alpha: 1), for: .disabled)
        button.backgroundColor = .clear
        button.setBackgroundImage(PaintedMaterial.button(face, pressed:false), for:.normal)
        button.setBackgroundImage(PaintedMaterial.button(face, pressed:true), for:.highlighted)
        button.setBackgroundImage(PaintedMaterial.button(face, pressed:true), for:.selected)
        button.setBackgroundImage(PaintedMaterial.button(face, pressed:true), for:[.selected,.highlighted])
        button.setBackgroundImage(PaintedMaterial.button(face, pressed:true), for:.disabled)
        button.layer.cornerRadius = 0
        button.layer.borderWidth = 0
        button.layer.shadowOpacity = 0
        (button as? ArcadeButton)?.materialFace = face
        if feedback {
            button.addAction(UIAction { _ in ArcadeFeedback.shared.button() }, for: .touchDown)
        }
    }
}

/// Image wrappers are cached. Stretch only the calm faces and straight rails;
/// corner plates and bevel widths stay fixed at every control size.
@MainActor enum PaintedMaterial {
    enum Face: String, CaseIterable { case pink = "Pink", teal = "Teal", charcoal = "Charcoal" }
    // Tiny deterministic ink grain, cached once, is clipped by native glyphs.
    // UIKit still owns text, wrapping, Dynamic Type and accessibility.
    private static let darkInk = ink(base: 0.07, grain: 0.22)
    private static let lightInk = ink(base: 0.86, grain: 0.64)
    private static func ink(base: CGFloat, grain: CGFloat) -> UIColor {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor(white: base, alpha: 1).setFill(); context.fill(CGRect(x:0,y:0,width:8,height:8))
            UIColor(white: grain, alpha: 1).setFill()
            for point in [CGPoint(x:1,y:1), CGPoint(x:6,y:3), CGPoint(x:3,y:6)] {
                context.fill(CGRect(origin:point,size:CGSize(width:0.5,height:0.5)))
            }
        }
        return UIColor(patternImage: image)
    }
    static func lettering(dark: Bool) -> UIColor { dark ? darkInk : lightInk }
    private static let panelSource = UIImage(named:"GrungeCenter")?.cgImage
    // One opaque, fixed-texel paint shared by casing and inlaid dialogs. Sample
    // no frame/scars; composite once so underlying game text cannot bleed through.
    static let cabinetPaint: UIColor = {
        guard let source = panelSource?.cropping(to:CGRect(x:192,y:128,width:64,height:64))
            else { return UIColor(white:0.15,alpha:1) }
        let tile = UIImage(cgImage:source,scale:3,orientation:.up)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
        let opaque = UIGraphicsImageRenderer(size:tile.size,format:format).image { context in
            Palette.black.setFill(); context.fill(CGRect(origin:.zero,size:tile.size))
            tile.draw(at:.zero)
        }
        return UIColor(patternImage:opaque)
    }()
    static let panel = panelImage(scale:4)
    static let rim = panelImage(scale:8)
    private static func panelImage(scale:CGFloat) -> UIImage? {
        guard let source = panelSource else { return nil }
        return UIImage(cgImage:source,scale:scale,orientation:.up).resizableImage(
            withCapInsets:UIEdgeInsets(top:64/scale,left:64/scale,bottom:64/scale,right:64/scale),resizingMode:.stretch)
    }
    private static let buttons: [String:UIImage] = {
        var result = [String:UIImage]()
        for face in Face.allCases {
            for state in ["Raised","Pressed"] {
                let key = face.rawValue+state
                guard let source = UIImage(named:"Grunge"+key)?.cgImage else { continue }
                let scale:CGFloat = 3
                result[key] = UIImage(cgImage:source,scale:scale,orientation:.up).resizableImage(
                    withCapInsets:UIEdgeInsets(top:36/scale,left:48/scale,bottom:36/scale,right:48/scale),resizingMode:.stretch)
            }
        }
        return result
    }()
    static func button(_ face:Face,pressed:Bool) -> UIImage? { buttons[face.rawValue+(pressed ? "Pressed" : "Raised")] }
    static func surface(compact:Bool = false) -> UIImageView {
        let view = UIImageView(image:compact ? rim : panel)
        view.isUserInteractionEnabled = false
        view.contentMode = .scaleToFill
        view.layer.magnificationFilter = .nearest
        view.layer.minificationFilter = .nearest
        return view
    }
}

@MainActor final class ArcadeButton: UIButton {
    var materialFace: PaintedMaterial.Face = .charcoal { didSet { updateMaterial() } }
    private var temporarilyLocked = false
    private var wasEnabledBeforeLock = false
    /// Keep native hit testing and accessibility disabled during an edit without
    /// making untouched controls look pressed. A previously unavailable action
    /// stays unavailable-looking; ending the lock restores ordinary state styling.
    /// `enabled` is authoritative; the second argument only describes a false value.
    func setEnabled(_ enabled: Bool, temporarilyLocked: Bool) {
        let lock = temporarilyLocked && !enabled
        guard isEnabled != enabled || self.temporarilyLocked != lock else { return }
        if lock && !self.temporarilyLocked { wasEnabledBeforeLock = isEnabled }
        self.temporarilyLocked = lock
        if isEnabled != enabled { isEnabled = enabled }
        else { updateMaterial() }
    }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        let lines = max(1,titleLabel?.numberOfLines ?? 1)
        return CGSize(width:size.width,height:max(size.height,Palette.minimumControlHeight(lines:lines,compatibleWith:traitCollection)))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel?.frame = bounds.inset(by: UIEdgeInsets(top: 6, left: 10, bottom: 8, right: 10))
            .offsetBy(dx:0,dy:isHighlighted || isSelected ? 2 : 0)
        titleLabel?.textAlignment = .center
    }
    override var isHighlighted: Bool { didSet { if oldValue != isHighlighted { updateMaterial() } } }
    override var isEnabled: Bool { didSet { if oldValue != isEnabled { updateMaterial() } } }
    override var isSelected: Bool { didSet { if oldValue != isSelected { updateMaterial() } } }
    override func continueTracking(_ touch:UITouch, with event:UIEvent?) -> Bool {
        guard bounds.contains(touch.location(in:self)) else {
            sendActions(for:.touchDragExit)
            isHighlighted = false
            return false
        }
        return super.continueTracking(touch,with:event)
    }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for:.touchDown); sendActions(for:.touchUpInside); return true
    }
    private func updateMaterial() {
        // The authored state swap supplies the depth. No second shadow, whole-button
        // translation, display link, or idle animation is needed.
        let preservesAvailability = temporarilyLocked && wasEnabledBeforeLock
        let appearsEnabled = isEnabled || preservesAvailability
        // Disabled is a real action lock, not a press. Only a transient lock of
        // an eligible sibling preserves its raised (or selected) appearance.
        let restingState: UIControl.State = isSelected ? .selected : .normal
        let disabledFace = preservesAvailability ? backgroundImage(for: restingState)
            : PaintedMaterial.button(materialFace, pressed: true)
        let disabledInk = preservesAvailability
            ? titleColor(for: restingState)
            : UIColor(white: 0.68, alpha: 1)
        for state: UIControl.State in [.disabled, [.disabled, .selected], [.disabled, .highlighted], [.disabled, .selected, .highlighted]] {
            setBackgroundImage(disabledFace, for: state)
            // UIKit resolves disabled+highlighted title colors through the enabled
            // highlight slot. Keep disabled ink out of that slot.
            if !state.contains(.highlighted) { setTitleColor(disabledInk, for: state) }
        }
        alpha = appearsEnabled ? 1 : 0.8
        let lit = (isEnabled && isHighlighted) || (appearsEnabled && isSelected)
        titleLabel?.layer.shadowColor = Palette.white.cgColor
        titleLabel?.layer.shadowOffset = .zero
        titleLabel?.layer.shadowRadius = 2
        titleLabel?.layer.shadowOpacity = lit ? 0.55 : 0
        setNeedsLayout()
    }
}

/// One static recessed instrument: readable native text and two authored lamps.
/// Only event/state changes update it; there is no CRT or blinking idle timer.
@MainActor final class CabinetInstrument: UIView {
    private let display = UIView()
    private let primary = UILabel()
    private let secondary = UILabel()
    private let green = UIImageView()
    private let red = UIImageView()
    private let gauge = UIProgressView(progressViewStyle: .bar)
    private static let off = UIImage(named:"LampOff")
    private static let greenOn = UIImage(named:"LampGreen")
    private static let redOn = UIImage(named:"LampRed")
    override init(frame:CGRect) {
        super.init(frame:frame)
        isAccessibilityElement = true; accessibilityIdentifier = "statusLabel"
        display.backgroundColor = UIColor(white:0.025,alpha:1)
        display.layer.borderColor = UIColor(white:0.30,alpha:1).cgColor
        display.layer.borderWidth = 1; display.layer.cornerRadius = 3
        display.layer.shadowColor = Palette.black.cgColor
        display.layer.shadowOffset = CGSize(width:0,height:2)
        display.layer.shadowOpacity = 0.8; display.layer.shadowRadius = 0
        addSubview(display)
        for label in [primary,secondary] {
            label.font = Palette.instrumentTypeface(compatibleWith:traitCollection)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = Palette.white
            label.numberOfLines = 0
            label.layer.shadowColor = Palette.teal.cgColor
            label.layer.shadowRadius = 1; label.layer.shadowOpacity = 0.3
            label.layer.shadowOffset = .zero
            display.addSubview(label)
        }
        for lamp in [green,red] {
            lamp.image = Self.off; lamp.contentMode = .scaleAspectFit
            lamp.layer.magnificationFilter = .nearest; lamp.layer.minificationFilter = .nearest
            addSubview(lamp)
        }
        gauge.progressTintColor = Palette.teal
        gauge.trackTintColor = Palette.white.withAlphaComponent(0.13)
        display.addSubview(gauge)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(primary:String,secondary:String,accessibility:String,greenOn:Bool,redOn:Bool,budget:Float) {
        self.primary.text = primary; self.secondary.text = secondary
        accessibilityLabel = accessibility
        green.image = greenOn && !redOn ? Self.greenOn : Self.off
        red.image = redOn ? Self.redOn : Self.off
        gauge.progress = budget
        setNeedsLayout()
    }
    func updateTypography() {
        for label in [primary,secondary] { label.font = Palette.instrumentTypeface(compatibleWith:traitCollection) }
        setNeedsLayout()
    }
    func height(for width:CGFloat) -> CGFloat {
        let textWidth = max(1,width-34)
        return max(48,ceil(primary.sizeThatFits(CGSize(width:textWidth,height:1000)).height)
            + ceil(secondary.sizeThatFits(CGSize(width:textWidth,height:1000)).height)+10)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        display.frame = CGRect(x:0,y:0,width:max(0,bounds.width-22),height:bounds.height)
        let width = max(1,display.bounds.width-12)
        let h = ceil(primary.sizeThatFits(CGSize(width:width,height:1000)).height)
        primary.frame = CGRect(x:6,y:3,width:width,height:h)
        secondary.frame = CGRect(x:6,y:3+h,width:width,height:max(0,bounds.height-h-10))
        gauge.frame = CGRect(x:6,y:bounds.height-4,width:width,height:2)
        green.frame = CGRect(x:bounds.width-18,y:max(2,bounds.midY-20),width:18,height:18)
        red.frame = CGRect(x:bounds.width-18,y:bounds.midY+2,width:18,height:18)
    }
}

/// Decorative casing and aperture art never mask or change the physics field.
@MainActor final class CabinetShell: UIView {
    static func faceClearance(in size:CGSize) -> CGFloat {
        9 + min(56,max(0,min(size.width,size.height)-10)*0.15)/3
    }
    // Content constraints seat cards independently of the full-window decoration.
    static func panelContentFrame(in bounds:CGRect,safeInsets:UIEdgeInsets) -> CGRect {
        let contentAllowance: CGFloat = 32/3
        return bounds.inset(by:UIEdgeInsets(
            top:max(15,safeInsets.top-contentAllowance),left:max(15,safeInsets.left-contentAllowance),
            bottom:max(15,safeInsets.bottom-contentAllowance),right:max(15,safeInsets.right-contentAllowance)))
            .insetBy(dx:12,dy:12)
    }
    private var field = CGRect.zero
    private var surround = CGRect.zero
    private var header = CGRect.zero
    private var console = CGRect.zero
    private let body = UIView()
    private let bodyMask = CabinetShell.art()
    private static let housingSource = UIImage(named:"GrungeHousingV2")?.cgImage
    private static let wellSource = UIImage(named:"GrungeWellV2")?.cgImage
    // Fill the authored exterior silhouette once, retaining its antialiased edge.
    // Paint and frame share this geometry and the same logical-point scale.
    private static let silhouette: CGImage? = {
        guard let source = housingSource else { return nil }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating:0,count:width*height*4)
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data:buffer.baseAddress,width:width,height:height,
                bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info) else { return false }
            context.draw(source,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard rendered else { return nil }
        for y in 0..<height {
            let row = y*width*4
            let first = (0..<width).first { pixels[row+$0*4+3] >= 128 }
            let last = (0..<width).last { pixels[row+$0*4+3] >= 128 }
            for x in 0..<width {
                let i = row+x*4
                if let first, let last, x >= first && x <= last { pixels[i+3] = 255 }
                // Premultiplied white; only alpha is used by the view mask.
                pixels[i] = pixels[i+3]; pixels[i+1] = pixels[i+3]; pixels[i+2] = pixels[i+3]
            }
        }
        guard let provider = CGDataProvider(data:Data(pixels) as CFData) else { return nil }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:info),provider:provider,
            decode:nil,shouldInterpolate:false,intent:.defaultIntent)
    }()
    private let housing = CabinetShell.art()
    private let screen = CabinetShell.art()
    private let apertureMask = CAShapeLayer()
    private var frameScale: CGFloat = 0
    private var wellScale: CGFloat = 0
    private static func material(_ source:CGImage?,scale:CGFloat) -> UIImage? {
        guard let source else { return nil }
        let cap:CGFloat = 255/scale
        return UIImage(cgImage:source,scale:scale,orientation:.up).resizableImage(
            withCapInsets:UIEdgeInsets(top:cap,left:cap,bottom:cap,right:cap),resizingMode:.stretch)
    }
    private static func art() -> UIImageView {
        let view = UIImageView()
        view.isUserInteractionEnabled = false
        view.layer.magnificationFilter = .nearest
        view.layer.minificationFilter = .nearest
        return view
    }
    override init(frame:CGRect) {
        super.init(frame:frame)
        isOpaque = false; isUserInteractionEnabled = false
        backgroundColor = .clear
        body.backgroundColor = PaintedMaterial.cabinetPaint
        body.mask = bodyMask
        [body,housing,screen].forEach(addSubview)
        apertureMask.fillRule = .evenOdd
        screen.layer.mask = apertureMask
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }
    func configure(field:CGRect,surround:CGRect,header:CGRect,console:CGRect) {
        guard self.field != field || self.surround != surround || self.header != header || self.console != console else { return }
        self.field = field; self.surround = surround; self.header = header; self.console = console; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 10, bounds.height > 10 else { return }
        // One full-window casing follows the viewport, including beneath system
        // occlusions. Safe areas constrain content, not this outer decoration.
        // Extend only straight spans; preserve isotropic corner art and shrink
        // continuously only when a compact window cannot fit its protected caps.
        body.frame = bounds
        housing.frame = bounds
        bodyMask.frame = body.bounds
        let scale = max(1.5,512/min(bounds.width,bounds.height))
        if frameScale != scale {
            frameScale = scale
            bodyMask.image = Self.material(Self.silhouette,scale:scale)
            housing.image = Self.material(Self.housingSource,scale:scale)
            body.isHidden = bodyMask.image == nil
        }
        // The actual gutter, not a hard clip, determines the recess's scale.
        // 38 source pixels encompass all ink with alpha >= 8 (of 255); the
        // isolated alpha-1 noise must not shrink the visible bevel fourfold.
        let gutter = min(8,field.minX-surround.minX,surround.maxX-field.maxX,
            field.minY-surround.minY,surround.maxY-field.maxY)
        screen.isHidden = field.isEmpty || surround.isEmpty || gutter <= 0
        guard !screen.isHidden else { return }
        let expanded = field.insetBy(dx:-gutter,dy:-gutter)
        screen.frame = expanded
        let apertureScale = max(38/gutter,512/min(expanded.width,expanded.height))
        if wellScale != apertureScale {
            wellScale = apertureScale
            screen.image = Self.material(Self.wellSource,scale:apertureScale)
        }
        // Remove only faint source noise inside the legal world. No artwork,
        // touch region or physics coordinate is moved to accommodate the rim.
        let ring = UIBezierPath(rect:screen.bounds)
        ring.append(UIBezierPath(rect:field.offsetBy(dx:-expanded.minX,dy:-expanded.minY)))
        apertureMask.frame = screen.bounds
        apertureMask.path = ring.cgPath
    }
}
