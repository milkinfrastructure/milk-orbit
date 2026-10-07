import UIKit
import OrbitCore

@MainActor final class GameFieldView: UIView {
    let session: GameSession
    var onChange: (() -> Void)?
    var onDismiss: (() -> Void)?
    var hasContextualOverlay: (() -> Bool)?
    private let removeButton = ArcadeButton(type: .custom)
    private let defaults: UserDefaults
    let controlDock = UIView()
    private let editor = UIView()
    private var repeatTimer: Timer?
    private var repeatTransaction = false
    var isRepeatingStrength: Bool { repeatTransaction }
    private var strengthRepeat = StrengthRepeat()
    private let strengthLabel = UILabel()
    private let gestureHint = UILabel()
    private let magnitude = UIView()
    private let magnitudeTrack = UIView()
    private let magnitudeFill = UIView()
    private var gaugeHoleID: UUID?
    private var gaugeCorner = 0
    private let lessButton = ArcadeButton(type: .custom)
    private let moreButton = ArcadeButton(type: .custom)
    private let moveButton = ArcadeButton(type: .custom)
    private var moveHasDisplacement = false
    private var moveArmed = false
    private enum DragMode { case strength, move }
    private var dragMode: DragMode?
    private var firstModeUse = false
    private var placementHintVisible = false
    private var tutorialGeneration = 0
    private var modeCueVisibleSince: CFTimeInterval?
    // Version the tutorial key so players whose earlier cue was hidden see it once.
    private let placementTutorialKey = "orbit.editTutorialShown.v2"
    private var touchOrigin = CGPoint.zero
    private var holeOrigin = Vec2.zero
    private var touchStarted = 0.0
    private var lastEditTime = 0.0
    private var lastMoveCell = Vec2.zero
    private var trackedTouch: UITouch?
    private var lastMassBand = 0
    private var lastSize = CGSize.zero
    private var screenBacking: UIImage?
    // Pre-cropped, sized assets: no atlas decoding/resampling on the first frame.
    private static let sprites = ["ArcadeShip","ArcadePlanet","ArcadeAsteroid","ArcadeHole"].map { UIImage(named:$0) }
    private var cursor = Vec2(x: 800, y: 450)
    // Preserve accessibility identities across board edits.
    private var boardAXElements: [String: UIAccessibilityElement] = [:]
    private var portalLevelName: String?
    private var portalPairs: [String: (number: Int, exit: Body)] = [:]

    init(session: GameSession, defaults: UserDefaults) {
        self.session = session
        self.defaults = defaults
        super.init(frame: .zero)
        accessibilityIdentifier = "gameField"
        backgroundColor = Palette.black
        isOpaque = true
        isMultipleTouchEnabled = true
        layer.cornerRadius = 2
        layer.borderWidth = 0
        layer.borderColor = Palette.white.cgColor
        clipsToBounds = true
        editor.backgroundColor = .clear
        editor.accessibilityIdentifier = "holeEditor"
        editor.layer.cornerRadius = 0
        editor.layer.borderWidth = 0
        editor.layer.borderColor = Palette.teal.cgColor
        strengthLabel.font = Palette.typeface(weight: .bold)
        strengthLabel.textColor = Palette.white
        strengthLabel.accessibilityIdentifier = "strengthLabel"
        gestureHint.font = Palette.typeface(weight: .medium)
        gestureHint.textColor = Palette.white
        gestureHint.numberOfLines = 0
        gestureHint.textAlignment = .center
        gestureHint.isAccessibilityElement = false // Hole actions already describe accessible editing.
        gestureHint.isHidden = true
        gestureHint.backgroundColor = .clear
        gestureHint.accessibilityIdentifier = "modeCue"
        gestureHint.text = "Hold ↑↓ · ↔ Move"
        magnitude.isUserInteractionEnabled = false
        magnitude.accessibilityElementsHidden = true // The adjustable hole exposes the same value.
        magnitude.isHidden = true
        magnitudeTrack.backgroundColor = Palette.teal.withAlphaComponent(0.25)
        magnitudeFill.backgroundColor = Palette.teal
        for label in [strengthLabel, gestureHint] {
            label.layer.shadowColor = Palette.black.cgColor
            label.layer.shadowOpacity = 1
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = .zero
        }
        for (button, title, action) in [(lessButton, "−", #selector(decreaseStrength)),
                                        (moreButton, "+", #selector(increaseStrength))] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = Palette.typeface(weight: .semibold)
            button.backgroundColor = Palette.white
            button.isExclusiveTouch = true
            button.setTitleColor(Palette.black, for: .normal)
            button.addTarget(self, action: action, for: .touchDown)
            button.addTarget(self, action: #selector(stopRepeating), for: [.touchUpInside, .touchUpOutside])
            button.addTarget(self, action: #selector(cancelRepeating), for: [.touchCancel, .touchDragExit])
            Palette.button(button, color: Palette.white, feedback: false)
            editor.addSubview(button)
        }
        lessButton.accessibilityIdentifier = "decreaseStrength"
        moreButton.accessibilityIdentifier = "increaseStrength"
        lessButton.accessibilityLabel = "Decrease strength by 0.5"
        moreButton.accessibilityLabel = "Increase strength by 0.5"
        moveButton.setTitle("Move", for: .normal)
        moveButton.titleLabel?.font = Palette.typeface(weight: .semibold)
        moveButton.backgroundColor = Palette.teal
        moveButton.setTitleColor(Palette.black, for: .normal)
        moveButton.accessibilityIdentifier = "moveHoleButton"
        moveButton.accessibilityLabel = "Move hole"
        moveButton.addTarget(self, action: #selector(armMove), for: .touchUpInside)
        Palette.button(moveButton, color: Palette.teal)
        editor.addSubview(moveButton)
        removeButton.setTitle("Remove", for: .normal)
        removeButton.titleLabel?.font = Palette.typeface(weight: .semibold)
        removeButton.setTitleColor(Palette.black, for: .normal)
        removeButton.backgroundColor = Palette.pink
        removeButton.layer.cornerRadius = 0
        removeButton.accessibilityIdentifier = "deleteHoleButton"
        removeButton.accessibilityLabel = "Remove black hole"
        removeButton.accessibilityHint = "Returns its strength. You can undo this."
        removeButton.addTarget(self, action: #selector(deleteHole), for: .touchUpInside)
        Palette.button(removeButton, color: Palette.pink)
        magnitude.addSubview(strengthLabel)
        magnitude.addSubview(magnitudeTrack)
        magnitudeTrack.addSubview(magnitudeFill)
        addSubview(magnitude)
        editor.addSubview(removeButton)
        controlDock.addSubview(editor)
        controlDock.addSubview(gestureHint)
        editor.isHidden = true
        updateTypography()
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:)") }

    var presentationPortrait = false
    private var boardTransform: BoardTransform { BoardTransform(width: bounds.width, height: bounds.height, portrait: presentationPortrait) }
    private var portrait: Bool { boardTransform.portrait }
    private var scaleX: CGFloat { portrait ? bounds.height / 1600 : bounds.width / 1600 }
    private var scaleY: CGFloat { portrait ? bounds.width / 900 : bounds.height / 900 }
    private var scale: CGFloat {
        max(0.01, min(scaleX, scaleY))
    }
    func screenPoint(_ p: Vec2) -> CGPoint {
        let p = boardTransform.screenPoint(p)
        return CGPoint(x: p.x, y: p.y)
    }
    private func worldPoint(_ p: CGPoint) -> Vec2 {
        boardTransform.worldPoint(Vec2(x: p.x, y: p.y))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if lastSize != bounds.size {
            finishInteractionForTransition()
            lastSize = bounds.size
            screenBacking = makeScreenBacking()
            rebuildAccessibility()
        }
        layoutDeleteButton()
    }
    private func controlMetrics(for width: CGFloat) -> (row: CGFloat, compact: Bool, single: Bool) {
        let font = Palette.typeface(compatibleWith: traitCollection)
        let row = Palette.minimumControlHeight(compatibleWith:traitCollection)
        let single = ("Remove" as NSString).size(withAttributes:[.font:font]).width+16 > (width-8)/2
        // Measure labels to keep controls inline whenever their actual widths fit.
        let moveWidth = ("Move" as NSString).size(withAttributes:[.font:font]).width+20
        let removeWidth = ("Remove" as NSString).size(withAttributes:[.font:font]).width+20
        let actionSpace = max(moveWidth/0.43,removeWidth/0.57)
        let inlineWidth = 2*max(44,row) + 24 + actionSpace
        return (row,width < inlineWidth,single)
    }
    var contextLayoutState: Int {
        if dragMode != nil { return 2 }
        return session.phase == .setup && (session.activeHoleID ?? session.selectedID) != nil ? 1 : 0
    }
    private var tutorialCue: String? {
        guard trackedTouch != nil else { return nil }
        if let mode = dragMode, firstModeUse {
            return mode == .strength ? "↑↓ Adjust pull\nRelease to set" : "Move freely\nRelease to set"
        }
        return placementHintVisible && dragMode == nil ? "Hold ↑↓: pull\nStart ↔: move" : nil
    }
    private var tutorialCueIsVisible: Bool {
        guard !gestureHint.isHidden, !controlDock.isHidden, let window = gestureHint.window,
              gestureHint.bounds.width > 0, gestureHint.bounds.height > 0 else { return false }
        if let scroll = controlDock.superview as? UIScrollView {
            return scroll.bounds.contains(controlDock.convert(gestureHint.frame,to:scroll))
        }
        return window.bounds.contains(gestureHint.convert(gestureHint.bounds,to:window))
    }
    private func tutorialHeight(for width: CGFloat) -> CGFloat {
        guard let cue = tutorialCue else { return 0 }
        return ceil((cue as NSString).boundingRect(with:CGSize(width:max(1,width),height:1000),
            options:.usesLineFragmentOrigin,
            attributes:[.font:Palette.typeface(compatibleWith:traitCollection)],context:nil).height)
    }
    func controlHeight(for width: CGFloat) -> CGFloat {
        guard contextLayoutState != 0 else { return 0 }
        let m = controlMetrics(for:width)
        let editorHeight = m.compact ? CGFloat(m.single ? 3 : 2)*(m.row+8)-8 : m.row
        // The normal 18pt cue fits the already-reserved row. Large text uses the
        // existing scrollable dock, never a smaller field or a route overlay.
        return max(editorHeight,tutorialHeight(for:width))
    }
    private func layoutDeleteButton() {
        guard let id = session.activeHoleID ?? session.selectedID, session.phase == .setup,
              let hole = session.holes.first(where: { $0.id == id }) else {
            editor.isHidden = true
            magnitude.isHidden = true
            gestureHint.isHidden = true
            gaugeHoleID = nil
            return
        }
        let width = controlDock.bounds.width
        let metrics = controlMetrics(for:width)
        let buttonHeight = metrics.row
        let compact = metrics.compact
        editor.frame = controlDock.bounds
        if compact {
            let half = max(44,(width-8)/2), firstY: CGFloat = 0
            lessButton.frame = CGRect(x:0,y:firstY,width:half,height:buttonHeight)
            moreButton.frame = CGRect(x:half+8,y:firstY,width:half,height:buttonHeight)
            moveButton.frame = CGRect(x:0,y:firstY+buttonHeight+8,width:half,height:buttonHeight)
            removeButton.frame = CGRect(x:half+8,y:firstY+buttonHeight+8,width:half,height:buttonHeight)
            if metrics.single {
                for (index,button) in [moveButton,removeButton].enumerated() {
                    button.frame = CGRect(x:0,y:firstY+CGFloat(index+1)*(buttonHeight+8),width:width,height:buttonHeight)
                }
            }
        } else {
            let square = max(44,buttonHeight)
            let remaining = width-2*square-24
            lessButton.frame = CGRect(x:0,y:0,width:square,height:buttonHeight)
            moreButton.frame = CGRect(x:square+8,y:0,width:square,height:buttonHeight)
            moveButton.frame = CGRect(x:2*square+16,y:0,width:remaining*0.43,height:buttonHeight)
            removeButton.frame = CGRect(x:moveButton.frame.maxX+8,y:0,width:remaining*0.57,height:buttonHeight)
        }
        let adjustmentEnabled = !session.isInteracting || repeatTransaction
        lessButton.isEnabled = adjustmentEnabled && (repeatTransaction || hole.mass > Physics.minMass + 1e-9)
        lessButton.accessibilityHint = hole.mass <= Physics.minMass + 1e-9 ? "Minimum strength is 2." : nil
        moreButton.isEnabled = adjustmentEnabled
        moveButton.setEnabled(!session.isInteracting, temporarilyLocked: repeatTransaction)
        removeButton.setEnabled(!session.isInteracting, temporarilyLocked: repeatTransaction)
        moveButton.setTitle(moveArmed ? "Drag…" : "Move", for:.normal)
        let cue = tutorialCue
        gestureHint.text = cue
        gestureHint.font = Palette.typeface(compatibleWith:traitCollection)
        gestureHint.frame = CGRect(x:0,y:0,width:width,
            height:min(controlDock.bounds.height,max(metrics.row,tutorialHeight(for:width))))
        gestureHint.isHidden = cue == nil
        // Buttons are disabled during the field gesture anyway. Use their dock
        // for first-use teaching, and hide the large editor throughout movement.
        editor.isHidden = dragMode != nil || cue != nil
        if cue != nil, dragMode != nil, firstModeUse, tutorialCueIsVisible {
            if modeCueVisibleSince == nil { modeCueVisibleSince = CACurrentMediaTime() }
        } else { modeCueVisibleSince = nil }
        layoutMagnitude(hole)
    }
    private func layoutMagnitude(_ hole: Hole) {
        let font = Palette.instrumentTypeface(compatibleWith: traitCollection)
        let width = min(bounds.width-16, ceil(("PULL 140.0" as NSString).size(withAttributes:[.font:font]).width)+8)
        let value = dragMode == .move ? "MOVE" : String(format:"PULL %.1f",hole.mass)
        strengthLabel.font = font
        strengthLabel.numberOfLines = 0
        strengthLabel.lineBreakMode = .byWordWrapping
        strengthLabel.text = value
        let valueHeight = ceil(strengthLabel.sizeThatFits(CGSize(width:max(1,width),height:1000)).height)
        let height = valueHeight+8
        guard width > 0, bounds.height > height+16 else { magnitude.isHidden = true; return }
        let frames = [CGRect(x:8,y:8,width:width,height:height),
                      CGRect(x:bounds.width-width-8,y:8,width:width,height:height),
                      CGRect(x:8,y:bounds.height-height-8,width:width,height:height),
                      CGRect(x:bounds.width-width-8,y:bounds.height-height-8,width:width,height:height)]
        // Choose once per deliberate selection, away from the route and objects.
        // Keep it anchored throughout adjustment instead of chasing the finger.
        if gaugeHoleID != hole.id {
            let route = session.preview.compactMap { $0 }.map(screenPoint)
            let objects = session.holes.map { screenPoint(Vec2(x:$0.x,y:$0.y)) }
                + session.level.bodies.map { screenPoint(Vec2(x:$0.x,y:$0.y)) }
                + [screenPoint(Vec2(x:session.level.ship.x,y:session.level.ship.y)),screenPoint(Physics.goalAt(level:session.level,time:0))]
            let finger = screenPoint(Vec2(x:hole.x,y:hole.y))
            func score(_ rect: CGRect) -> Int {
                let expanded = rect.insetBy(dx:-12,dy:-12)
                return route.filter { expanded.contains($0) }.count
                    + objects.filter { expanded.contains($0) }.count*40
                    + (rect.insetBy(dx:-45,dy:-45).contains(finger) ? 1000 : 0)
            }
            gaugeCorner = frames.indices.min { score(frames[$0]) < score(frames[$1]) } ?? 0
            gaugeHoleID = hole.id
        }
        magnitude.frame = frames[gaugeCorner]
        magnitude.isHidden = false
        strengthLabel.font = font
        strengthLabel.frame = CGRect(x:0,y:0,width:width,height:valueHeight)
        strengthLabel.text = dragMode == .move ? "MOVE" : String(format:"PULL %.1f",hole.mass)
        let capacity = max(Physics.minMass, floor(Physics.capacityAt(level:session.level,
            holes:session.holes.filter { $0.id != hole.id },x:hole.x,y:hole.y)*2+1e-9)/2)
        magnitudeTrack.frame = CGRect(x:0,y:valueHeight+5,width:width,height:3)
        magnitudeTrack.isHidden = dragMode == .move
        magnitudeFill.frame = CGRect(x:0,y:0,width:width*CGFloat(min(1,hole.mass/capacity)),height:3)
    }
    func layoutControls() { layoutDeleteButton() }
    func updateTypography() {
        Palette.applyTypeface(to: strengthLabel, weight: .bold)
        Palette.applyTypeface(to: gestureHint)
        for button in [lessButton,moreButton,moveButton,removeButton] {
            if let label = button.titleLabel { Palette.applyTypeface(to:label,weight:.bold) }
        }
        layoutDeleteButton()
    }

    private func showFirstEditHint() {
        guard !defaults.bool(forKey:placementTutorialKey) else { return }
        placementHintVisible = true
        tutorialGeneration &+= 1
        let generation = tutorialGeneration
        // A quick tap/cancellation must not consume a lesson that never had a
        // readable frame. This finite callback changes no game state or timing.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { [weak self] in
            guard let self, self.tutorialGeneration == generation,
                  self.placementHintVisible, self.trackedTouch != nil, self.dragMode == nil,
                  self.tutorialCueIsVisible else { return }
            self.defaults.set(true,forKey:self.placementTutorialKey)
        }
    }
    private func finishTutorialCue(completed: Bool) {
        if completed, let mode = dragMode, firstModeUse,
           let shown = modeCueVisibleSince, CACurrentMediaTime()-shown >= 0.2 {
            defaults.set(true,forKey:mode == .strength ? "orbit.strengthLearned" : "orbit.moveLearned")
        }
        tutorialGeneration &+= 1
        placementHintVisible = false
        modeCueVisibleSince = nil
        firstModeUse = false
        gestureHint.isHidden = true
    }

    func refresh(accessibility: Bool = false) {
        layoutDeleteButton()
        setNeedsDisplay()
        if accessibility { rebuildAccessibility() }
    }
    @objc private func deleteHole() {
        stopRepeating()
        session.deleteSelected()
        changed()
        focusPlacementCursor()
    }
    @objc private func decreaseStrength() { startRepeating(-0.5) }
    @objc private func increaseStrength() { startRepeating(0.5) }
    private func startRepeating(_ direction: Double) {
        stopRepeating()
        guard let hole = session.selectedHole, session.phase == .setup,
              session.begin(at:hole.position,screenY:0,hitRadius:0) else { return }
        repeatTransaction = true
        let step = strengthRepeat.begin(holeID:hole.id,direction:direction > 0 ? .increase : .decrease,at:ProcessInfo.processInfo.systemUptime)
        applyStep(step)
        guard strengthRepeat.isActive else { return }
        let timer = Timer(timeInterval:0.05,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let step = self.strengthRepeat.advance(at:ProcessInfo.processInfo.systemUptime,
                    selectedHoleID:self.session.selectedID,editable:self.session.phase == .setup)
                if step != 0 { self.applyStep(step) }
                if !self.strengthRepeat.isActive { self.repeatTimer?.invalidate(); self.repeatTimer = nil }
            }
        }
        repeatTimer = timer
        RunLoop.main.add(timer,forMode:.common)
    }
    private func applyStep(_ step: Double) {
        guard step != 0, let before = session.selectedHole?.mass, session.phase == .setup else { stopRepeating(); return }
        session.setStrength(before + step)
        let after = session.selectedHole?.mass ?? before
        strengthRepeat.didApply(before:before,after:after)
        if after != before { ArcadeFeedback.shared.detent() }
        changed()
    }
    @objc private func stopRepeating() {
        repeatTimer?.invalidate(); repeatTimer = nil; strengthRepeat.cancel()
        guard repeatTransaction else { return }
        repeatTransaction = false; session.end(); changed()
    }
    @objc private func cancelRepeating() {
        repeatTimer?.invalidate(); repeatTimer = nil; strengthRepeat.cancel()
        guard repeatTransaction else { return }
        // A scroll recognizer cancels the button touch; discard its tentative adjustment.
        repeatTransaction = false; session.cancel(); changed()
    }
    func cancelEditorPressForScroll() { cancelRepeating() }
    @objc private func armMove() { moveArmed.toggle(); refresh(accessibility: true) }
    func dismissEditor() {
        moveArmed = false
        cancelTouch(); session.clearSelection(); refresh(accessibility: true)
    }
    private func changed() {
        refresh(accessibility: true)
        onChange?()
    }
    func finishInteractionForTransition() {
        // Commit the last legal position once; never carry a held gesture across geometry/lifecycle changes.
        session.end()
        cancelTouch()
    }
    func cancelTouch() {
        stopRepeating()
        finishTutorialCue(completed:false)
        trackedTouch = nil
        dragMode = nil
        moveArmed = false
        gestureHint.isHidden = true
        session.cancel()
        session.clearSelection()
        refresh(accessibility: true)
        onChange?()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, event?.allTouches?.count == 1,
              let touch = touches.first, session.phase == .setup else {
            cancelTouch(); return
        }
        let p = touch.location(in: self)
        let hit = boardTransform.hitHole(in: session.holes, at: Vec2(x: p.x, y: p.y))
        if session.dismissIfEmpty(hitHole: hit, additionalOverlay: hasContextualOverlay?() ?? false) {
            onDismiss?(); changed(); return
        }
        ArcadeFeedback.shared.prepare()
        if session.begin(at: hit?.position ?? worldPoint(p), screenY: p.y, hitRadius: 0) {
            trackedTouch = touch
            touchOrigin = p
            moveHasDisplacement = false
            touchStarted = touch.timestamp - (moveArmed ? 0.25 : 0)
            lastEditTime = 0
            dragMode = moveArmed ? .move : nil
            if moveArmed {
                firstModeUse = !defaults.bool(forKey: "orbit.moveLearned")
                ArcadeFeedback.shared.button()
            }
            holeOrigin = session.holes.first { $0.id == session.activeHoleID }!.position
            if hit == nil { ArcadeFeedback.shared.place() } else { ArcadeFeedback.shared.button() }
            lastMassBand = Int((session.holes.first { $0.id == session.activeHoleID }?.mass ?? 2) * 2)
            lastMoveCell = Vec2(x: floor(holeOrigin.x / 40), y: floor(holeOrigin.y / 40))
            showFirstEditHint()
            changed()
        } else { changed() }
    }
    @discardableResult
    private func applyDrag(_ touch: UITouch, final: Bool = false) -> Bool {
        guard touch.timestamp - touchStarted >= 0.25 else { return false }
        let p = touch.location(in: self)
        let dx = p.x - touchOrigin.x, dy = p.y - touchOrigin.y
        if dragMode == .move, !moveHasDisplacement {
            guard max(abs(dx), abs(dy)) >= 10 else { return false }
            moveHasDisplacement = true
        }
        if dragMode == nil {
            guard max(abs(dx), abs(dy)) >= 10 else { return false }
            moveHasDisplacement = true
            // Lock once: a horizontal start enables free movement, a vertical start resizes.
            dragMode = abs(dx) > abs(dy) ? .move : .strength
            let key = dragMode == .strength ? "orbit.strengthLearned" : "orbit.moveLearned"
            firstModeUse = !defaults.bool(forKey: key)
            placementHintVisible = false
            modeCueVisibleSince = nil
            ArcadeFeedback.shared.button()
            if dragMode == .strength { session.reanchorStrength(screenY: p.y) }
            layoutDeleteButton()
        }
        // Preview rebuilding is capped at 30 Hz even on a 120 Hz touch screen.
        guard final || touch.timestamp - lastEditTime >= 1.0 / 30 else { return false }
        lastEditTime = touch.timestamp
        let before = session.holes.first { $0.id == session.activeHoleID }
        let previousFeedback = session.lastFeedback
        if dragMode == .strength {
            session.dragPrecisely(screenY: p.y)
        } else {
            let start = screenPoint(holeOrigin)
            session.move(to: worldPoint(CGPoint(x: start.x + dx, y: start.y + dy)))
        }
        guard let id = session.activeHoleID, let hole = session.holes.first(where: { $0.id == id }) else { return false }
        let band = Int(hole.mass * 2)
        let cell = Vec2(x: floor(hole.x / 40), y: floor(hole.y / 40))
        let crossed = dragMode == .strength ? band != lastMassBand : cell != lastMoveCell
        if crossed {
            ArcadeFeedback.shared.detent()
        }
        lastMassBand = band
        lastMoveCell = cell
        return hole != before || previousFeedback != session.lastFeedback
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        guard touch.timestamp - touchStarted >= 0.25, touch.timestamp - lastEditTime >= 1.0 / 30 else { return }
        guard applyDrag(touch) else { return }
        refresh()
        onChange?()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        applyDrag(touch, final: true)
        // A stationary touch still selects, even when it lasts longer than the
        // drag arming delay. Only entering an edit mode closes the editor.
        let edited = dragMode != nil
        finishTutorialCue(completed:true)
        session.end()
        if edited { session.clearSelection() }
        gestureHint.isHidden = true
        trackedTouch = nil
        dragMode = nil
        moveArmed = false
        changed()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelTouch()
    }

    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        c.interpolationQuality = .none
        c.setFillColor(Palette.black.cgColor); c.fill(bounds)
        screenBacking?.draw(in:bounds)
        c.saveGState()
        if portrait { c.translateBy(x: 0, y: bounds.height); c.rotate(by: -.pi / 2) }
        c.scaleBy(x: scaleX, y: scaleY)
        c.clip(to: CGRect(x: 0, y: 0, width: 1600, height: 900))
        for zone in session.level.zones {
            c.saveGState()
            c.clip(to: CGRect(x: zone.x, y: zone.y, width: zone.w, height: zone.h))
            c.setFillColor(Palette.pink.withAlphaComponent(0.05).cgColor)
            c.fill(CGRect(x: zone.x, y: zone.y, width: zone.w, height: zone.h))
            c.setStrokeColor(Palette.pink.withAlphaComponent(0.22).cgColor)
            c.setLineWidth(1 / scale)
            for x in stride(from: -900.0, through: 2500, by: 44) {
                c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x + 900, y: 900))
            }
            c.strokePath(); c.restoreGState()
        }
        // Keep the previous attempt legible while tuning, behind the new prediction.
        drawPath(session.lastCompletedTrail, in: c, color: Palette.white.withAlphaComponent(0.30), dotted: true)
        if session.phase == .setup { drawPath(session.preview, in: c, color: Palette.white.withAlphaComponent(0.65), dotted: true) }
        drawPath(session.trail.suffix(193), in: c, color: Palette.teal, dotted: false)
        let time = session.flight?.time ?? 0
        rebuildPortalPairsIfNeeded()
        for body in session.level.bodies {
            let p = Physics.bodyAt(body: body, time: time)
            switch body.type {
            case .hole: drawHole(c, at: p, mass: body.mass, fixed: true)
            case .wormhole:
                pixelRing(c, at: p, radius: body.r * 1.3, color: Palette.pink, line: 5)
                pixelRing(c, at: p, radius: body.r * 0.7, color: Palette.pink.withAlphaComponent(0.45), line: 3)
                if let id = body.id, let pair = portalPairs[id] {
                    drawPortalPairMark(c,at:p,pair:pair.number)
                }
            case .repulsor:
                pixelDisk(c, at: p, radius: body.r, color: Palette.white)
                pixelRing(c, at: p, radius: body.r + 14, color: Palette.pink, line: 3)
            case .planet: drawSprite(Self.sprites[1], at:p, radius:body.r)
            case .asteroid:
                // The collision surface remains visible between jagged sprite edges.
                c.setFillColor(Palette.white.withAlphaComponent(0.24).cgColor)
                c.fillEllipse(in:CGRect(x:p.x-body.r,y:p.y-body.r,width:body.r*2,height:body.r*2))
                drawSprite(Self.sprites[2], at:p, radius:body.r)

            }
        }
        for (i, beacon) in session.level.beacons.enumerated() {
            let passed = session.flight?.passed.indices.contains(i) == true && session.flight?.passed[i] == true
            let p = Vec2(x: beacon.x, y: beacon.y)
            drawPort(c, at:p, radius:beacon.r, color:passed ? Palette.teal : Palette.pink, goal:false,collected:passed)
        }
        let goal = Physics.goalAt(level: session.level, time: time)
        drawPort(c, at:goal, radius:session.level.goal.r, color:Palette.teal, goal:true)
        for hole in session.holes { drawHole(c, at: hole.position, mass: hole.mass, fixed: false) }
        let ship = session.flight.map { Vec2(x: $0.x, y: $0.y) } ?? Vec2(x: session.level.ship.x, y: session.level.ship.y)
        let angle = session.flight.map { atan2($0.vy, $0.vx) } ?? ((session.level.ship.angle ?? 0) * .pi / 180)
        c.restoreGState()
        // Uniform screen-space ship: portrait/landscape never stretch its silhouette.
        let screen = screenPoint(ship)
        let direction = screenPoint(ship + Vec2(x:cos(angle),y:sin(angle)))
        c.saveGState(); c.translateBy(x:screen.x,y:screen.y)
        c.rotate(by:atan2(direction.y-screen.y,direction.x-screen.x))
        let shipWidth = min(40,max(30,88*scale))
        let shipHeight = shipWidth*184/192
        c.interpolationQuality = .none
        Self.sprites[0]?.draw(in:CGRect(x:-shipWidth/2,y:-shipHeight/2,width:shipWidth,height:shipHeight))
        c.restoreGState()
        if let id = session.activeHoleID ?? session.selectedID,
           let hole = session.holes.first(where: { $0.id == id }) {
            let p = screenPoint(hole.position)
            c.setStrokeColor(Palette.white.withAlphaComponent(0.65).cgColor)
            c.setLineWidth(1)
            c.strokeEllipse(in: CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60))
        }
    }

    private func drawPath<S: Sequence>(_ points: S, in c: CGContext, color: UIColor, dotted: Bool) where S.Element == Vec2? {
        c.saveGState(); c.setStrokeColor(color.cgColor); c.setLineWidth(1.3 / scale)
        if dotted { c.setLineDash(phase: 0, lengths: [2 / scale, 6 / scale]) }
        var start = true
        for p in points {
            guard let p else { start = true; continue }
            if start { c.move(to: CGPoint(x: p.x, y: p.y)); start = false }
            else { c.addLine(to: CGPoint(x: p.x, y: p.y)) }
        }
        c.strokePath(); c.restoreGState()
    }
    private func pixelPath(at p: Vec2, radius r: Double) -> CGPath {
        let path = CGMutablePath()
        let points: [(Double, Double)] = [(-0.5,-1),(0.5,-1),(0.5,-0.85),(0.85,-0.85),(0.85,-0.5),(1,-0.5),(1,0.5),(0.85,0.5),(0.85,0.85),(0.5,0.85),(0.5,1),(-0.5,1),(-0.5,0.85),(-0.85,0.85),(-0.85,0.5),(-1,0.5),(-1,-0.5),(-0.85,-0.5),(-0.85,-0.85),(-0.5,-0.85)]
        for (i, v) in points.enumerated() {
            let point = CGPoint(x: p.x + v.0 * r, y: p.y + v.1 * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath(); return path
    }
    private func pixelDisk(_ c: CGContext, at p: Vec2, radius: Double, color: UIColor) {
        c.setFillColor(color.cgColor); c.addPath(pixelPath(at: p, radius: radius)); c.fillPath()
    }
    private func pixelRing(_ c: CGContext, at p: Vec2, radius: Double, color: UIColor, line: Double) {
        c.setStrokeColor(color.cgColor); c.setLineWidth(line)
        c.addPath(pixelPath(at: p, radius: radius)); c.strokePath()
    }
    private func drawPort(_ c:CGContext, at p:Vec2, radius:Double, color:UIColor, goal:Bool, collected:Bool = false) {
        pixelDisk(c,at:p,radius:radius+6,color:Palette.white.withAlphaComponent(0.25))
        pixelDisk(c,at:p,radius:radius+2,color:color)
        pixelDisk(c,at:p,radius:radius-6,color:Palette.black)
        pixelRing(c,at:p,radius:radius-11,color:color.withAlphaComponent(0.45),line:3)
        for sign in [-1.0,1.0] {
            square(c,x:p.x+sign*(radius-3)-4,y:p.y-6,size:8,color:Palette.white)
        }
        if goal {
            c.setStrokeColor(color.cgColor); c.setLineWidth(4)
            c.move(to:CGPoint(x:p.x-7,y:p.y-7)); c.addLine(to:CGPoint(x:p.x+1,y:p.y))
            c.addLine(to:CGPoint(x:p.x-7,y:p.y+7)); c.strokePath()
        } else if collected {
            // Keep the check upright as the world rotates; collection is a shape
            // change as well as a color change, with no additional animation.
            c.saveGState(); c.translateBy(x:p.x,y:p.y)
            if portrait { c.rotate(by:.pi/2) }
            c.setStrokeColor(Palette.white.cgColor); c.setLineWidth(max(3,1.5/scale))
            c.move(to:CGPoint(x:-radius*0.4,y:0))
            c.addLine(to:CGPoint(x:-radius*0.1,y:radius*0.3))
            c.addLine(to:CGPoint(x:radius*0.4,y:-radius*0.3)); c.strokePath()
            c.restoreGState()
        } else {
            // A diamond identifies an uncollected beacon even without color.
            let r = min(radius*0.38,3/scale)
            c.setFillColor(Palette.white.cgColor)
            c.move(to:CGPoint(x:p.x,y:p.y-r)); c.addLine(to:CGPoint(x:p.x+r,y:p.y))
            c.addLine(to:CGPoint(x:p.x,y:p.y+r)); c.addLine(to:CGPoint(x:p.x-r,y:p.y))
            c.closePath(); c.fillPath()
        }
    }
    private func rebuildPortalPairsIfNeeded() {
        // Catalog level names are unique, and the session changes level only at
        // a load boundary. Rotation/flight/editing reuse these tiny descriptors.
        guard portalLevelName != session.level.name else { return }
        portalLevelName = session.level.name
        portalPairs.removeAll(keepingCapacity:true)
        let portals = session.level.bodies.filter { $0.type == .wormhole }
        var keys = Set<[String]>()
        for portal in portals {
            guard let id = portal.id, let twin = portal.twin, id != twin,
                  portals.contains(where:{ $0.id == twin && $0.twin == id }) else { continue }
            keys.insert([id,twin].sorted())
        }
        for (offset,key) in keys.sorted(by:{ $0.lexicographicallyPrecedes($1) }).enumerated() {
            guard let first = portals.first(where:{ $0.id == key[0] }),
                  let second = portals.first(where:{ $0.id == key[1] }) else { continue }
            portalPairs[key[0]] = (offset+1,second)
            portalPairs[key[1]] = (offset+1,first)
        }
    }
    private func drawPortalPairMark(_ c:CGContext, at p:Vec2, pair:Int) {
        // One/two white bars in the existing dark portal center. World geometry
        // and the actual portal aperture are unchanged; no connecting line.
        c.saveGState(); c.setStrokeColor(Palette.white.cgColor)
        c.setLineWidth(2/scale); c.setLineCap(.square)
        for index in 0..<pair {
            let x = p.x+(Double(index)-Double(pair-1)/2)*5/scale
            c.move(to:CGPoint(x:x,y:p.y-2.5/scale))
            c.addLine(to:CGPoint(x:x,y:p.y+2.5/scale))
        }
        c.strokePath(); c.restoreGState()
    }
    private func drawHole(_ c: CGContext, at p: Vec2, mass: Double, fixed: Bool) {
        let radius = Physics.horizonRadius(mass:mass)
        // The outer accretion cue supplies phone-scale presence. The authored dark
        // core below remains exactly tied to the unchanged collision horizon.
        let aura = max(radius*1.8,14/scale)
        c.saveGState()
        // Open arcs avoid implying a second collision or range boundary.
        c.addRects([CGRect(x:p.x-aura*1.2,y:p.y-aura*1.2,width:aura*2.4,height:aura*0.65),
                    CGRect(x:p.x-aura*1.2,y:p.y+aura*0.55,width:aura*2.4,height:aura*0.65)])
        c.clip()
        pixelRing(c,at:p,radius:aura,color:Palette.pink.withAlphaComponent(0.28),line:1.5/scale)
        c.restoreGState()
        if let image = Self.sprites[3] {
            // Crop core center (345,223), radius 133; the disk is decorative.
            image.draw(in:CGRect(x:p.x-radius*345/133,y:p.y-radius*223/133,width:radius*692/133,height:radius*461/133))
        } else { drawAccretionHole(c,at:p,radius:radius) }
        if fixed {
            c.saveGState(); c.setLineDash(phase:0,lengths:[4,5]);
            pixelRing(c,at:p,radius:radius*2.6,color:Palette.white.withAlphaComponent(0.5),line:1/scale)
            c.restoreGState()
        }
    }
    private func drawSprite(_ image: UIImage?, at p: Vec2, radius:Double) {
        guard let image else { return }
        let ratio = image.size.width/image.size.height
        let width = radius*2*(ratio > 1 ? ratio : 1)
        let height = radius*2*(ratio < 1 ? 1/ratio : 1)
        image.draw(in:CGRect(x:p.x-width/2,y:p.y-height/2,width:width,height:height))
    }
    private func makeScreenBacking() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // One point-resolution glass image per layout; no decorative animation or
        // per-frame texture work. All routes and sprites draw above this surface.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size:bounds.size,format:format).image { context in
            let c = context.cgContext
            c.setFillColor(Palette.black.cgColor); c.fill(bounds)
            c.setFillColor(Palette.teal.withAlphaComponent(0.075).cgColor)
            c.fill(bounds)
            // Narrow edge falloff gives the inset glass depth without a luminous
            // oval, bright corners, scanlines, or texture across the route.
            for inset in 0..<12 {
                c.setStrokeColor(Palette.black.withAlphaComponent(CGFloat(12-inset)/40).cgColor)
                c.setLineWidth(1)
                c.stroke(bounds.insetBy(dx:CGFloat(inset)+0.5,dy:CGFloat(inset)+0.5))
            }
            // Quiet inset edge, never an overlay across the flight path.
            c.setStrokeColor(Palette.teal.withAlphaComponent(0.16).cgColor)
            c.setLineWidth(1); c.stroke(bounds.insetBy(dx:0.5,dy:0.5))
        }
    }
    private func drawAccretionHole(_ c: CGContext, at p: Vec2, radius: Double) {
        c.saveGState(); c.translateBy(x: p.x,y: p.y); c.scaleBy(x: radius,y: radius)
        c.setStrokeColor(Palette.pink.cgColor); c.setFillColor(Palette.pink.cgColor)
        c.setAlpha(0.35); c.setLineWidth(0.13); c.addPath(HoleAccretionPaths.disk); c.strokePath()
        c.setAlpha(1); c.addPath(HoleAccretionPaths.lensedArc); c.fillPath()
        c.setFillColor(Palette.black.cgColor); c.addPath(HoleAccretionPaths.core); c.fillPath()
        c.setAlpha(0.7); c.setLineWidth(0.08); c.addPath(HoleAccretionPaths.rim); c.strokePath()
        c.setAlpha(1); c.setFillColor(Palette.pink.cgColor); c.addPath(HoleAccretionPaths.foreground); c.fillPath()
        c.setAlpha(0.85); c.setFillColor(Palette.white.cgColor); c.addPath(HoleAccretionPaths.brightSide); c.fillPath()
        c.setAlpha(0.22); c.setFillColor(Palette.black.cgColor)
        c.fill(CGRect(x: -1.7,y: 0.37,width: 0.18,height: 0.045))
        c.fill(CGRect(x: 0.9,y: 0.67,width: 0.16,height: 0.045))
        c.restoreGState()
    }

    private func square(_ c: CGContext, x: Double, y: Double, size: Double, color: UIColor) {
        c.setFillColor(color.cgColor); c.fill(CGRect(x: x, y: y, width: size, height: size))
    }

    // VoiceOver uses the same placement constraints and undo transactions as touch.
    private func rebuildAccessibility() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        rebuildPortalPairsIfNeeded()
        var elements: [UIAccessibilityElement] = []
        var liveKeys = Set<String>()
        let levelKey = session.level.name + "/"
        func item(_ key: String, _ label: String, adjustable: Bool = false) -> UIAccessibilityElement {
            liveKeys.insert(key)
            let element = boardAXElements[key] ?? (adjustable
                ? HoleAccessibilityElement(accessibilityContainer: self)
                : UIAccessibilityElement(accessibilityContainer: self))
            boardAXElements[key] = element
            element.accessibilityIdentifier = key
            element.accessibilityLabel = label
            element.accessibilityTraits = .staticText
            elements.append(element)
            return element
        }
        let budget = item("boardBudget", "Placement budget")
        budget.accessibilityValue = "\(session.availableMatter.formatted(.number.precision(.fractionLength(0...1)))) strength left. Up to \(session.remainingPlacements) more \(session.remainingPlacements == 1 ? "hole" : "holes")."
        budget.accessibilityFrameInContainerSpace = axBoundedFrame(CGRect(x: 0, y: 0, width: 44, height: 44))
        let ship = item(levelKey + "ship", "Ship")
        ship.accessibilityTraits = .image
        ship.accessibilityValueBlock = { [weak self] in
            guard let self else { return nil }
            let status = self.session.flight?.status.rawValue ?? "ready to launch"
            return status + ". " + self.axPosition(self.session.flight?.position ?? self.session.level.ship.position)
        }
        axTrackFrame(ship, radius: 18) { [weak self] in
            self?.session.flight?.position ?? self?.session.level.ship.position ?? .zero
        }
        let goal = item(levelKey + "goal", "Docking goal")
        goal.accessibilityTraits = .image
        goal.accessibilityHint = session.level.beacons.isEmpty ? "Reach this to complete the sector."
            : "Collect every beacon, then reach this to complete the sector."
        goal.accessibilityValueBlock = { [weak self] in
            guard let self else { return nil }
            let moving = self.session.level.goal.orbit != nil || self.session.level.goal.patrol != nil
            return (moving ? "Moves during flight. " : "") + self.axPosition(
                Physics.goalAt(level: self.session.level, time: self.session.flight?.time ?? 0))
        }
        axTrackFrame(goal, radius: session.level.goal.r) { [weak self] in
            guard let self else { return .zero }
            return Physics.goalAt(level: self.session.level, time: self.session.flight?.time ?? 0)
        }
        for (index, body) in session.level.bodies.enumerated() {
            let label: String
            switch body.type {
            case .hole: label = "Fixed black hole"
            case .planet: label = "Planet"
            case .repulsor: label = "Repulsor"
            case .asteroid: label = "Asteroid"
            case .wormhole: label = "Wormhole"
            }
            let pair = body.id.flatMap { portalPairs[$0] }
            let spokenLabel = pair.map { "Wormhole pair \($0.number)" } ?? "\(label) \(index + 1)"
            let element = item(levelKey + "body-\(index)-" + (body.id ?? ""),spokenLabel)
            element.accessibilityTraits = .image
            if body.type == .wormhole {
                element.accessibilityHint = "Teleports to the exit with the same pair marks."
            } else if body.type == .hole {
                element.accessibilityHint = "Fixed hazard; cannot be moved or removed. Its dark core ends the flight."
            } else { element.accessibilityHint = "Avoid a collision with this object." }
            element.accessibilityValueBlock = { [weak self] in
                guard let self else { return nil }
                let time = self.session.flight?.time ?? 0
                let moving = body.orbit != nil || body.patrol != nil
                let location = (moving ? "Moves during flight. " : "") + self.axPosition(
                    Physics.bodyAt(body:body,time:time))
                guard let pair else { return location }
                return location + " Paired exit: " + self.axPosition(Physics.bodyAt(body:pair.exit,time:time))
            }
            axTrackFrame(element, radius: body.type == .hole ? Physics.horizonRadius(mass: body.mass) : body.r) { [weak self] in
                Physics.bodyAt(body: body, time: self?.session.flight?.time ?? 0)
            }
        }
        for (index, beacon) in session.level.beacons.enumerated() {
            let element = item(levelKey + "beacon-\(index)", "Beacon \(index + 1)")
            element.accessibilityTraits = .image
            element.accessibilityValueBlock = { [weak self] in
                guard let self else { return nil }
                let passed = self.session.flight?.passed
                let collected = passed?.indices.contains(index) == true && passed?[index] == true
                return (collected ? "Collected. " : "Not collected. ") + self.axPosition(beacon.position)
            }
            element.accessibilityHint = "Fly through every beacon before docking."
            axTrackFrame(element, radius: beacon.r) { beacon.position }
        }
        for (index, zone) in session.level.zones.enumerated() {
            let element = item(levelKey + "zone-\(index)", "No-placement zone \(index + 1)")
            element.accessibilityValue = "From X \(Int(zone.x)), Y \(Int(zone.y)) to X \(Int(zone.x + zone.w)), Y \(Int(zone.y + zone.h))."
            element.accessibilityHint = "Black holes cannot be placed here. The ship can pass through."
            let a = screenPoint(Vec2(x: zone.x, y: zone.y))
            let b = screenPoint(Vec2(x: zone.x + zone.w, y: zone.y + zone.h))
            element.accessibilityFrameInContainerSpace = axBoundedFrame(CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        }
        if session.phase == .setup {
            let cursorElement = item("placementCursor", "Black hole placement cursor")
            cursorElement.accessibilityTraits = .button
            cursorElement.accessibilityValue = axPosition(cursor)
            cursorElement.accessibilityHint = "Double-tap to place. Use Actions to move one grid step."
            cursorElement.accessibilityFrameInContainerSpace = axFrame(at: cursor, radius: 0)
            let place: () -> Bool = { [weak self] in
                guard let self, self.axCanEdit else { return false }
                guard self.session.hole(at: self.cursor, hitRadius: 0) == nil else {
                    UIAccessibility.post(notification: .announcement, argument: "A black hole is already here.")
                    return false
                }
                let placed = self.session.begin(at: self.cursor, screenY: 0, hitRadius: 0)
                self.session.end(); self.changed()
                if placed { ArcadeFeedback.shared.place() }
                if !placed { UIAccessibility.post(notification: .announcement, argument: self.session.lastFeedback) }
                return placed
            }
            cursorElement.accessibilityActivateBlock = place
            cursorElement.accessibilityCustomActions = [
                cursorAction("Move up", dx: portrait ? 40 : 0, dy: portrait ? 0 : -40),
                cursorAction("Move down", dx: portrait ? -40 : 0, dy: portrait ? 0 : 40),
                cursorAction("Move left", dx: portrait ? 0 : -40, dy: portrait ? -40 : 0),
                cursorAction("Move right", dx: portrait ? 0 : 40, dy: portrait ? 40 : 0),
                UIAccessibilityCustomAction(name: "Place black hole") { _ in place() }
            ]
        }
        for (index, hole) in session.holes.enumerated() {
            guard let element = item("blackHole-" + hole.id.uuidString, "Black hole \(index + 1)",
                                     adjustable: true) as? HoleAccessibilityElement else { continue }
            let id = hole.id
            let editable = session.phase == .setup
            element.accessibilityValue = String(format: "%.1f strength. ", hole.mass) + axPosition(hole.position)
            element.accessibilityTraits = editable ? .adjustable : .staticText
            element.accessibilityHint = editable ? "Swipe up or down to change strength by 0.5. Actions move or remove this hole." : nil
            element.accessibilityFrameInContainerSpace = axFrame(at: hole.position, radius: Physics.horizonRadius(mass: hole.mass))
            element.adjust = editable ? { [weak self] delta in
                guard let self, self.axCanEdit, let current = self.session.holes.first(where: { $0.id == id }),
                      self.session.begin(at: current.position, screenY: 0, hitRadius: 0) else { return }
                self.session.end(); self.session.adjustSelected(by: delta); self.changed()
                if self.session.selectedHole?.mass != current.mass { ArcadeFeedback.shared.detent() }
            } : nil
            element.accessibilityCustomActions = editable ? [
                holeMoveAction("Move up", id: id, dx: portrait ? 40 : 0, dy: portrait ? 0 : -40),
                holeMoveAction("Move down", id: id, dx: portrait ? -40 : 0, dy: portrait ? 0 : 40),
                holeMoveAction("Move left", id: id, dx: portrait ? 0 : -40, dy: portrait ? -40 : 0),
                holeMoveAction("Move right", id: id, dx: portrait ? 0 : 40, dy: portrait ? 40 : 0),
                UIAccessibilityCustomAction(name: "Remove") { [weak self] _ in
                    guard let self, self.axCanEdit, let current = self.session.holes.first(where: { $0.id == id }),
                          self.session.begin(at: current.position, screenY: 0, hitRadius: 0) else { return false }
                    self.session.end(); self.session.deleteSelected(); self.changed()
                    self.focusPlacementCursor(); ArcadeFeedback.shared.button(); return true
                }
            ] : nil
        }
        boardAXElements = boardAXElements.filter { liveKeys.contains($0.key) }
        accessibilityElements = elements
    }

    /// Return focus to a surviving element after delete/reset instead of a removed hole.
    func focusPlacementCursor() {
        rebuildAccessibility()
        UIAccessibility.post(notification: .layoutChanged,
            argument: boardAXElements["placementCursor"] ?? boardAXElements["boardBudget"])
    }

    private var axCanEdit: Bool {
        isUserInteractionEnabled && session.phase == .setup && !session.isInteracting
    }
    private func axPosition(_ position: Vec2) -> String {
        let p = screenPoint(position)
        let row = p.y < bounds.height / 3 ? "top" : (p.y > bounds.height * 2 / 3 ? "bottom" : "middle")
        let column = p.x < bounds.width / 3 ? "left" : (p.x > bounds.width * 2 / 3 ? "right" : "center")
        return "\(row) \(column). X \(Int(position.x.rounded())), Y \(Int(position.y.rounded()))."
    }
    private func axBoundedFrame(_ rect: CGRect) -> CGRect {
        let width = min(bounds.width, max(44, rect.width))
        let height = min(bounds.height, max(44, rect.height))
        return CGRect(x: min(bounds.maxX - width, max(bounds.minX, rect.midX - width / 2)),
                      y: min(bounds.maxY - height, max(bounds.minY, rect.midY - height / 2)),
                      width: width, height: height)
    }
    private func axFrame(at position: Vec2, radius: Double) -> CGRect {
        let p = screenPoint(position)
        let diameter = max(44, CGFloat(radius) * scale * 2)
        return axBoundedFrame(CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2,
                                    width: diameter, height: diameter))
    }
    private func axTrackFrame(_ element: UIAccessibilityElement, radius: Double,
                              position: @escaping @MainActor () -> Vec2) {
        // Queried by accessibility, not the display link. The same board transform is used.
        element.accessibilityFrameBlock = { [weak self] in
            guard let self else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(self.axFrame(at: position(), radius: radius), in: self)
        }
    }
    private func holeMoveAction(_ title: String, id: UUID, dx: Double, dy: Double) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: title) { [weak self] _ in
            guard let self, self.axCanEdit, let hole = self.session.holes.first(where: { $0.id == id }),
                  self.session.begin(at: hole.position, screenY: 0, hitRadius: 0) else { return false }
            self.session.move(to: Vec2(x: hole.x + dx, y: hole.y + dy))
            self.session.end(); self.changed()
            let moved = self.session.holes.first { $0.id == id }?.position != hole.position
            if moved { ArcadeFeedback.shared.detent() }
            if !moved { UIAccessibility.post(notification: .announcement, argument: self.session.lastFeedback ?? "Board edge.") }
            return moved
        }
    }
    private func cursorAction(_ title: String, dx: Double, dy: Double) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: title) { [weak self] _ in
            guard let self, self.axCanEdit else { return false }
            let old = self.cursor
            self.cursor = Vec2(x: min(1560, max(40, old.x + dx)), y: min(860, max(40, old.y + dy)))
            self.rebuildAccessibility()
            UIAccessibility.post(notification: .announcement, argument: self.axPosition(self.cursor))
            return self.cursor != old
        }
    }
}

@MainActor private final class HoleAccessibilityElement: UIAccessibilityElement {
    var adjust: ((Double) -> Void)?
    override func accessibilityIncrement() { adjust?(0.5) }
    override func accessibilityDecrement() { adjust?(-0.5) }
}

@MainActor private enum HoleAccretionPaths {
    static let disk = CGPath(ellipseIn: CGRect(x: -2.4,y: -0.42,width: 4.8,height: 0.84), transform: nil)
    static let core = CGPath(ellipseIn: CGRect(x: -1,y: -1,width: 2,height: 2), transform: nil)
    static let rim = CGPath(ellipseIn: CGRect(x: -1.1,y: -1.1,width: 2.2,height: 2.2), transform: nil)
    static let lensedArc: CGPath = {
        let path = CGMutablePath()
        let points: [(Double,Double)] = [(-1.42,0.02),(-1.42,-0.54),(-1.12,-1.02),(-0.78,-1.36),(-0.35,-1.5),(0.35,-1.5),(0.78,-1.36),(1.12,-1.02),(1.42,-0.54),(1.42,0.02),(1.15,-0.03),(1.15,-0.45),(0.91,-0.83),(0.63,-1.1),(0.28,-1.24),(-0.28,-1.24),(-0.63,-1.1),(-0.91,-0.83),(-1.15,-0.45),(-1.15,-0.03)]
        for (i,v) in points.enumerated() {
            let point = CGPoint(x: v.0,y: v.1)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath(); return path
    }()
    static let foreground: CGPath = {
        let path = CGMutablePath(); path.move(to: CGPoint(x: -2.4,y: 0.05))
        path.addCurve(to: CGPoint(x: 0,y: 0.75), control1: CGPoint(x: -1.55,y: 0.48), control2: CGPoint(x: -0.78,y: 0.75))
        path.addCurve(to: CGPoint(x: 2.4,y: 0.05), control1: CGPoint(x: 0.88,y: 0.75), control2: CGPoint(x: 1.72,y: 0.44))
        path.addLine(to: CGPoint(x: 2.4,y: 0.24))
        path.addCurve(to: CGPoint(x: 0,y: 0.96), control1: CGPoint(x: 1.6,y: 0.76), control2: CGPoint(x: 0.75,y: 0.96))
        path.addCurve(to: CGPoint(x: -2.4,y: 0.24), control1: CGPoint(x: -0.95,y: 0.96), control2: CGPoint(x: -1.7,y: 0.66))
        path.closeSubpath(); return path
    }()
    static let brightSide: CGPath = {
        let path = CGMutablePath(); path.move(to: CGPoint(x: -2.2,y: 0.16))
        path.addCurve(to: CGPoint(x: -0.28,y: 0.73), control1: CGPoint(x: -1.45,y: 0.49), control2: CGPoint(x: -0.85,y: 0.67))
        path.addLine(to: CGPoint(x: -0.28,y: 0.85))
        path.addCurve(to: CGPoint(x: -2.2,y: 0.26), control1: CGPoint(x: -0.95,y: 0.79), control2: CGPoint(x: -1.68,y: 0.56))
        path.closeSubpath(); return path
    }()
}
