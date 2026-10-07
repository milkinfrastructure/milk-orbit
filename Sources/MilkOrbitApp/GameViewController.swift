import UIKit
import OrbitCore
import CoreHaptics

// Let a console pan cancel an already-tracking button touch. Strength edits
// use the existing touch-cancel/scroll handler to roll back the tentative change.
@MainActor private final class EditorScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIButton || super.touchesShouldCancel(in: view)
    }
}

@MainActor final class GameViewController: UIViewController {
    private let levels: [Level]
    private let session: GameSession
    private lazy var field = GameFieldView(session: session, defaults: defaults)
    private let brand = UILabel()
    private let consoleScroll = EditorScrollView()
    private var resumeRequired = false
    private var checkpointTask: Task<Void, Never>?
    private let checkpointEncoder = CheckpointEncoder()
    private var checkpointGeneration: UInt64 = 0
    private var checkpointBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var checkpointBackgroundGeneration: UInt64?
    private var lastContextLayoutState = -1
    private let cabinet = CabinetShell()
    private let carton = UIImageView(image: Palette.carton)
    private var panel: ArcadePanel?
    private weak var panelReturnFocus: UIView?
    private var victoryShareItem: VictoryShareItem?
    private var savedVictory: FlightRecord? {
        guard let data = defaults.data(forKey: "orbit.lastVictory.v1"),
              let record = try? JSONDecoder().decode(FlightRecord.self, from: data), record.isValid,
              record.sectorCount == levels.count, levels.indices.contains(record.sectorIndex) else { return nil }
        return record
    }
    private var consoleFrame = CGRect.zero
    private let sector = ArcadeButton(type: .custom)
    private let help = ArcadeButton(type: .custom)
    private let instrument = CabinetInstrument()
    private var instrumentFeedback = InstrumentFeedback()
    private var instrumentTask: Task<Void, Never>?
    private var instrumentDeadline: Double?
    private var lastInstrumentHeight: CGFloat = 0
    private var lastInputFeedback: String?
    private let launch = ArcadeButton(type: .custom)
    private let speed = ArcadeButton(type: .custom)
    private let undo = ArcadeButton(type: .custom)
    private let reset = ArcadeButton(type: .custom)
    private let defaults = UserDefaults.standard
    private var levelIndex: Int = 0
    private var unlocked: Int = 0
    private var displayLink: CADisplayLink?
    private var displayTarget: DisplayTarget?
    private var lastTimestamp: CFTimeInterval?
    private var lastStatusTime = 0.0
    private var thermalPaused: Bool { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue }
    private var active = false
    private var recordedFinish = false
    private var endingSeconds = 0.0
    private let haptics = UINotificationFeedbackGenerator()
    private let flightHaptics = FlightHaptics()

    init(prepared: PreparedGame) {
        levels = prepared.levels
        session = prepared.session
        super.init(nibName: nil, bundle: nil)
        levelIndex = prepared.index
        unlocked = prepared.unlocked
        resumeRequired = session.phase == .flying
    }
    required init?(coder: NSCoder) { fatalError("Use init(prepared:)") }
    func beginPlaying() {
        if session.phase == .finished, session.flight?.status == .won { finishFlight(restoring: true) }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.black
        view.addSubview(cabinet)
        view.addSubview(field)
        view.addSubview(consoleScroll)
        consoleScroll.showsVerticalScrollIndicator = true
        consoleScroll.indicatorStyle = .white
        consoleScroll.contentInsetAdjustmentBehavior = .never
        consoleScroll.isAccessibilityElement = false
        consoleScroll.panGestureRecognizer.addTarget(self,action:#selector(consolePanned))
        consoleScroll.addSubview(field.controlDock)
        field.onChange = { [weak self] in
            guard let self else { return }
            if let message = self.session.lastFeedback,
               message != self.lastInputFeedback || self.instrumentFeedback.visible(at:CACurrentMediaTime()) == nil {
                self.postInstrument(self.compactFeedback(message), announcement:message, lamp:.red, priority:50)
            } else if self.session.lastFeedback == nil, self.session.isInteracting {
                self.clearInstrument()
            }
            self.lastInputFeedback = self.session.lastFeedback
            self.updateControls()
            if !self.session.isInteracting { self.scheduleCheckpoint() }
        }
        field.onDismiss = { [weak self] in self?.dismissAllOverlays() }
        field.hasContextualOverlay = { [weak self] in self?.instrumentFeedback.visible(at:CACurrentMediaTime()) != nil }
        carton.contentMode = .scaleAspectFit
        carton.layer.magnificationFilter = .nearest
        carton.backgroundColor = .clear
        carton.isAccessibilityElement = false
        view.addSubview(carton)
        brand.text = "MILK ORBIT"
        brand.font = Palette.typeface(weight: .bold)
        brand.textColor = Palette.white
        brand.isAccessibilityElement = false
        view.addSubview(brand)
        view.addSubview(instrument)
        configure(sector, title: "Sector", color: .clear, action: #selector(openSectors))
        sector.titleLabel?.font = Palette.typeface(weight: .bold)
        sector.titleLabel?.numberOfLines = 2
        sector.titleLabel?.lineBreakMode = .byWordWrapping
        configure(help, title: "?", color: .clear, action: #selector(openHelp))
        help.accessibilityLabel = "How to play"
        configure(launch, title: "LAUNCH ↗", color: Palette.pink, action: #selector(launchTapped))
        configure(undo, title: "UNDO", color: .clear, action: #selector(undoTapped))
        configure(reset, title: "RESET", color: .clear, action: #selector(resetTapped))
        reset.accessibilityLabel = "Reset board"
        reset.accessibilityHint = "Clear placed holes and return this sector to setup."
        configure(speed, title: "HOLD 4×", color: .white, action: #selector(speedReleased))
        for state: UIControl.State in [.selected, [.selected,.highlighted]] {
            speed.setBackgroundImage(PaintedMaterial.button(.teal,pressed:true),for:state)
            speed.setTitleColor(Palette.black,for:state)
        }
        speed.addTarget(self, action: #selector(speedPressed), for: .touchDown)
        speed.addTarget(self, action: #selector(speedReleased), for: [.touchUpOutside, .touchCancel, .touchDragExit])
        speed.accessibilityIdentifier = "speedButton"
        speed.titleLabel?.numberOfLines = 2
        speed.titleLabel?.textAlignment = .center
        speed.accessibilityHint = "Hold to play the flight at four times the speed. Release to return to normal speed."
        speed.isHidden = true
        speed.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Play at four times the speed") { [weak self] _ in
                guard let self, !self.thermalPaused, self.session.phase == .flying else { return false }
                self.speedPressed(); return true
            },
            UIAccessibilityCustomAction(name: "Return to normal speed") { [weak self] _ in
                self?.speedReleased(); return self != nil
            }
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(thermalNotification),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        launch.accessibilityIdentifier = "launchButton"
        undo.accessibilityIdentifier = "undoButton"
        reset.accessibilityIdentifier = "resetButton"
        help.accessibilityIdentifier = "helpButton"
        sector.accessibilityIdentifier = "sectorButton"
        for button in [launch,undo,reset,speed] { button.titleLabel?.numberOfLines = 2 }
        updateTypography()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: GameViewController, _) in
            self.panel?.settlePresentation()
            self.field.finishInteractionForTransition()
            self.updateTypography(); self.view.setNeedsLayout()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(powerNotification),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
        updateControls()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        setActive(false)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ensureDisplayLink()
        setActive(view.window?.windowScene?.activationState == .foregroundActive)
    }
    private func ensureDisplayLink() {
        guard displayLink == nil, let scene = view.window?.windowScene else { return }
        let target = DisplayTarget(controller: self)
        displayTarget = target
        let link: CADisplayLink
        if #available(iOS 27.0, *), let sceneLink = scene.displayLink(target: target, selector: #selector(DisplayTarget.frame(_:))) {
            link = sceneLink
        } else { link = CADisplayLink(target: target, selector: #selector(DisplayTarget.frame(_:))) }
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateFrameRate()
    }
    func sceneGeometryDidChange() {
        guard isViewLoaded else { return }
        field.finishInteractionForTransition()
        session.setFastForwarding(false)
        lastTimestamp = nil
        updateFrameRate(); view.setNeedsLayout(); updateControls()
    }
    private func scheduleCheckpoint() {
        checkpointGeneration += 1
        checkpointTask?.cancel()
        endCheckpointBackgroundTask()
        checkpointTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self?.session.isInteracting == false else { return }
            self?.persistSession()
        }
    }
    func persistSession(background: Bool = false) {
        guard isViewLoaded else { return }
        checkpointGeneration += 1
        checkpointTask?.cancel()
        let generation = checkpointGeneration
        endCheckpointBackgroundTask()
        // Capture mutable game state on the main actor; only this value crosses actors.
        let checkpoint = session.checkpoint()
        if background || UIApplication.shared.applicationState == .background {
            checkpointBackgroundGeneration = generation
            checkpointBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save checkpoint") { [weak self] in
                guard let self, self.checkpointBackgroundGeneration == generation else { return }
                self.checkpointGeneration += 1
                self.checkpointTask?.cancel(); self.checkpointTask = nil
                self.endCheckpointBackgroundTask()
            }
            if checkpointBackgroundTask == .invalid { checkpointBackgroundGeneration = nil }
        }
        // Retain the controller only until this finite save finishes, including lease cleanup.
        checkpointTask = Task { [self] in
            defer {
                if checkpointGeneration == generation {
                    checkpointTask = nil
                    endCheckpointBackgroundTask()
                }
            }
            do {
                let data = try await checkpointEncoder.encode(checkpoint)
                guard !Task.isCancelled, checkpointGeneration == generation else { return }
                defaults.set(data, forKey: "orbit.checkpoint.v1")
            } catch is CancellationError {
                // A newer snapshot or background expiration superseded this save.
            } catch {
                #if DEBUG
                NSLog("MILK_CHECKPOINT_FAILED %@", String(describing: error))
                #endif
            }
        }
    }
    private func endCheckpointBackgroundTask() {
        let identifier = checkpointBackgroundTask
        checkpointBackgroundTask = .invalid
        checkpointBackgroundGeneration = nil
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
    }
    private func updateTypography() {
        Palette.applyTypeface(to:brand)
        instrument.updateTypography()
        for button in [sector,help,launch,speed,undo,reset] {
            if let label = button.titleLabel { Palette.applyTypeface(to:label,weight:.bold) }
        }
        field.updateTypography()
    }
    private func configure(_ button: UIButton, title: String, color: UIColor, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = Palette.typeface(weight: .bold)
        button.titleLabel?.adjustsFontSizeToFitWidth = false
        button.titleLabel?.minimumScaleFactor = 0.9
        button.setTitleColor(color == .clear ? Palette.white : Palette.black, for: .normal)
        button.setTitleColor(Palette.muted, for: .disabled)
        button.backgroundColor = color
        button.layer.cornerRadius = 0
        if button === launch || button === undo || button === reset || button === speed {
            button.layer.borderWidth = 2
            button.layer.borderColor = Palette.white.cgColor
            button.layer.shadowColor = Palette.black.cgColor
            button.layer.shadowOpacity = 1
            button.layer.shadowRadius = 0
            button.layer.shadowOffset = CGSize(width: 2, height: 2)
        }
        Palette.button(button, color: color)
        button.addTarget(self, action: action, for: .touchUpInside)
        view.addSubview(button)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.bounds.inset(by: view.safeAreaInsets)
        let font = Palette.typeface(compatibleWith: traitCollection)
        let largeText = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let row = Palette.minimumControlHeight(compatibleWith:traitCollection)
        let textHeight = ceil(font.lineHeight)*2
        let desiredWidth: CGFloat = largeText ? min(360,area.width*0.44) : 168
        // Reserve one editor row even when hidden: selecting a hole must never resize
        // the field and cancel the touch that selected it. Ordinary controls fit two rows.
        let portraitColumns = max(1,min(3,Int((area.width-16)/(max(96,font.pointSize*5.5+12)+8))))
        let portraitRows = CGFloat(Int(ceil(3.0/Double(portraitColumns))))
        let portraitFooter = portraitRows*row+(portraitRows-1)*8
        let desiredHeight = min(area.height*0.55, largeText ? row*2+textHeight+20 : max(row,textHeight)+8+portraitFooter)
        let headerRow = Palette.minimumControlHeight(compatibleWith:traitCollection)
        let stackedHeaderSpace: CGFloat = !largeText && area.width >= 600 && area.width > area.height ? 32 : 0
        let headerHeight = headerRow+max(24,ceil(font.lineHeight))+4+stackedHeaderSpace
        var divisions: [CGRect] = [], occlusions: [CGRect] = []
        if #available(iOS 27.1, *) {
            divisions = view.reservedRegions(kind:.division).map(\.frame)
            occlusions = view.reservedRegions(kind:.occlusion).map(\.frame)
        }
        let layout = CabinetLayout(area:area,consoleWidth:desiredWidth,consoleHeight:desiredHeight,
            headerHeight:headerHeight,panelOpen:panel != nil,divisions:divisions,occlusions:occlusions)
        field.presentationPortrait = layout.portraitBoard
        field.frame = layout.field
        // The portrait control face sits inside the casing's edge material. This
        // only seats labels/buttons; the existing world rectangle stays intact.
        let faceInset:CGFloat = layout.portraitBoard && !layout.sideConsole
            ? min(14,max(0,(min(layout.console.width,layout.header.width)-44)/2)) : 0
        let console = layout.console.insetBy(dx:faceInset,dy:0)
        var header = layout.header.insetBy(dx:faceInset,dy:0)
        if layout.sideConsole {
            let lowestOrigin = max(header.minY,console.maxY-header.height)
            header.origin.y = min(lowestOrigin,max(header.minY,CabinetShell.faceClearance(in:view.bounds.size)))
        }
        consoleFrame = console
        cabinet.frame = view.bounds
        cabinet.configure(field:layout.field,surround:layout.fieldSurround,header:header,console:console)
        let sectorTextWidth = ceil(("00/20" as NSString).size(withAttributes:[.font:Palette.typeface(weight:.bold,compatibleWith:traitCollection)]).width)+24
        let brandWidth = ceil(("MILK ORBIT" as NSString).size(withAttributes:[.font:font]).width)
        let narrowHeader = header.width < 36+brandWidth+8+sectorTextWidth+52 || largeText
        let stackedMarquee = layout.sideConsole && stackedHeaderSpace > 0
        brand.isHidden = narrowHeader && (!stackedMarquee || header.width < 36+brandWidth)
        sector.titleLabel?.numberOfLines = 1
        let icon: CGFloat = 28
        let rowY = header.minY+(stackedMarquee ? 32 : 0)
        carton.frame = CGRect(x:header.minX,y:header.minY+(stackedMarquee ? 0 : 8),width:icon,height:icon)
        let sectorWidth: CGFloat = stackedMarquee ? header.width-52 : (narrowHeader ? max(44,header.width-88) : max(68,sectorTextWidth))
        sector.frame = CGRect(x:header.maxX-52-sectorWidth,y:rowY,width:sectorWidth,height:headerRow)
        brand.frame = CGRect(x:header.minX+36,y:header.minY,width:stackedMarquee ? header.width-36 : max(0,sector.frame.minX-header.minX-44),height:stackedMarquee ? 28 : headerRow)
        sector.contentHorizontalAlignment = .center
        help.frame = CGRect(x:header.maxX-44,y:rowY,width:44,height:headerRow)
        // Seat the readout in the existing header lanes. It stays visible during
        // editing and never changes the world rectangle. Large text falls back to
        // the existing scrolling console instead of shrinking the font or field.
        let laneWidth = max(0,sector.frame.minX-header.minX-8)
        let instrumentWidth = layout.sideConsole ? header.width : laneWidth
        let instrumentHeight = instrument.height(for:instrumentWidth)
        let inHeader = !largeText && (layout.sideConsole || instrumentHeight <= header.height)
        if inHeader {
            if instrument.superview !== view { view.addSubview(instrument) }
            if layout.sideConsole {
                instrument.frame = CGRect(x:header.minX,y:rowY+headerRow+4,width:header.width,height:instrumentHeight)
            } else {
                carton.frame = CGRect(x:sector.frame.minX,y:sector.frame.maxY+2,width:22,height:22)
                brand.text = "MILK"; brand.isHidden = false
                brand.frame = CGRect(x:carton.frame.maxX+6,y:sector.frame.maxY,width:max(0,header.maxX-carton.frame.maxX-6),height:24)
                instrument.frame = CGRect(x:header.minX,y:header.midY-instrumentHeight/2,width:laneWidth,height:instrumentHeight)
            }
        } else {
            if instrument.superview !== consoleScroll { consoleScroll.addSubview(instrument) }
            instrument.frame = CGRect(x:0,y:0,width:console.width,height:instrument.height(for:console.width))
        }
        if layout.sideConsole || !inHeader { brand.text = "MILK ORBIT" }
        let minActionWidth = max(96,font.pointSize*5.5+12)
        let columns = max(1,min(3,Int((console.width+8)/(minActionWidth+8))))
        let rows = Int(ceil(3.0/Double(columns)))
        let proposedFooter = CGFloat(rows)*row+CGFloat(rows-1)*8
        let headerInside = console.contains(CGPoint(x:header.midX,y:header.midY))
        let headerBottom = inHeader ? max(header.maxY,instrument.frame.maxY) : header.maxY
        let bodyY = headerInside ? min(console.maxY,headerBottom+8) : console.minY
        // On short or large-text presentations keep the primary action reachable;
        // secondary controls join the native scrolling editor instead of overlapping it.
        let editorHeight = field.controlHeight(for:console.width)
        let instrumentOffset = inHeader ? 0 : instrument.frame.height+8
        let minimumBody = instrumentOffset + (editorHeight > 0 ? min(200,editorHeight) : 0)
        let secondaryScrolls = console.maxY-bodyY-proposedFooter < minimumBody
        let footerHeight = secondaryScrolls ? row : proposedFooter
        let footerY = max(bodyY,console.maxY-footerHeight)
        consoleScroll.frame = CGRect(x:console.minX,y:bodyY,width:console.width,height:max(0,footerY-bodyY-8))
        field.controlDock.frame = CGRect(x:0,y:instrumentOffset,width:console.width,height:editorHeight)
        field.layoutControls()
        var contentHeight = instrumentOffset + editorHeight
        if secondaryScrolls {
            if undo.superview !== consoleScroll { consoleScroll.addSubview(undo); consoleScroll.addSubview(reset); consoleScroll.addSubview(speed) }
            let two = console.width >= minActionWidth*2+8
            let width = two ? (console.width-8)/2 : console.width
            undo.frame = CGRect(x:0,y:contentHeight+8,width:width,height:row)
            reset.frame = CGRect(x:two ? width+8 : 0,y:two ? undo.frame.minY : undo.frame.maxY+8,width:width,height:row)
            speed.frame = undo.frame
            launch.frame = CGRect(x:console.minX,y:footerY,width:console.width,height:row)
            contentHeight = reset.frame.maxY+8
        } else {
            if undo.superview !== view { view.addSubview(undo); view.addSubview(reset); view.addSubview(speed) }
            let width = max(44,(console.width-CGFloat(columns-1)*8)/CGFloat(columns))
            for (index,button) in [undo,reset,launch].enumerated() {
                let col = index % columns, line = index / columns
                let remaining = 3-line*columns
                let span = remaining < columns && button === launch ? console.width : width
                button.frame = CGRect(x:console.minX+CGFloat(col)*(width+8),y:footerY+CGFloat(line)*(row+8),width:span,height:row)
            }
            speed.frame = undo.frame
        }
        consoleScroll.contentSize = CGSize(width:console.width,height:contentHeight)
        consoleScroll.isScrollEnabled = contentHeight > consoleScroll.bounds.height
        let maximumOffset = max(0,contentHeight-consoleScroll.bounds.height)
        if consoleScroll.contentOffset.y > maximumOffset { consoleScroll.contentOffset.y = maximumOffset }
        reset.isHidden = false
        panel?.frame = view.bounds; panel?.dockFrame = console; panel?.setNeedsLayout()
        if let panel { view.bringSubviewToFront(panel) }
    }
    @objc private func consolePanned() {
        if consoleScroll.panGestureRecognizer.state == .began { field.cancelEditorPressForScroll() }
    }
    private func dismissAllOverlays() {
        let returnFocus = panelReturnFocus
        panel?.removeFromSuperview(); panel = nil; panelReturnFocus = nil
        view.setNeedsLayout()
        field.dismissEditor()
        clearInstrument()
        updateControls()
        if let returnFocus { UIAccessibility.post(notification:.screenChanged,argument:returnFocus) }
        else { field.focusPlacementCursor() }
    }
    override func accessibilityPerformEscape() -> Bool {
        guard panel != nil || session.selectedID != nil else { return false }
        dismissAllOverlays(); return true
    }
    func setActive(_ active: Bool) {
        self.active = active
        updateFrameRate()
        lastTimestamp = nil
        guard isViewLoaded else { return }
        if !active {
            panel?.settlePresentation()
            clearInstrument()
            field.finishInteractionForTransition(); session.setFastForwarding(false); flightHaptics.stop()
            if session.phase == .flying { resumeRequired = true }
            persistSession()
        } else { ensureDisplayLink() }
        updateControls()
    }
    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayTarget = nil
    }
    fileprivate func frame(_ link: CADisplayLink) {
        guard active, !resumeRequired, !thermalPaused, session.phase == .flying || endingSeconds > 0 else { lastTimestamp = nil; return }
        defer { lastTimestamp = link.timestamp }
        guard let previous = lastTimestamp else { return }
        let elapsed = min(link.timestamp - previous, 0.1)
        if endingSeconds > 0 {
            endingSeconds = max(0, endingSeconds - elapsed)
            if endingSeconds == 0 {
                session.retry()
                persistSession()
                field.refresh(accessibility: true)
                updateControls()
            }
            return // Static failure hold: no redundant draw or label layout.
        } else {
            session.tick(elapsed: elapsed)
            let events = session.drainFlightEvents()
            presentFlightEvents(events)
            flightHaptics.update(session:session,elapsed:elapsed,events:events)
            if session.phase == .finished { finishFlight() }
        }
        field.refresh()
        // Only the time label changes during a flight. Avoid rebuilding every control per frame.
        if link.timestamp - lastStatusTime >= 0.1 || session.phase != .flying {
            lastStatusTime = link.timestamp
            updateControls()
        }
    }
    @objc private func speedPressed() {
        guard !thermalPaused, !resumeRequired, active else { return }
        session.setFastForwarding(true)
        updateControls()
    }
    @objc private func speedReleased() {
        session.setFastForwarding(false)
        updateControls()
    }
    // ProcessInfo notifications arrive on the posting thread. Entering an
    // @MainActor Objective-C selector there traps before its body can run.
    @objc nonisolated private func thermalNotification() {
        Task { @MainActor [weak self] in self?.thermalStateChanged() }
    }
    @objc nonisolated private func powerNotification() {
        Task { @MainActor [weak self] in self?.updateFrameRate() }
    }
    private func updateFrameRate() {
        let screenMaximum = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState != .nominal
        let maximum = Float(min(screenMaximum, constrained ? 60 : 120))
        // A preference, not a guaranteed hardware rate. Idle remains paused; physics stays 240 Hz.
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
    }
    private func thermalStateChanged() {
        updateFrameRate()
        if thermalPaused {
            clearInstrument()
            field.finishInteractionForTransition(); session.setFastForwarding(false); flightHaptics.stop()
            if session.phase == .flying { resumeRequired = true }
            persistSession()
        }
        lastTimestamp = nil
        updateControls()
    }
    private func updateControls() {
        guard isViewLoaded else { return }
        if lastContextLayoutState != field.contextLayoutState {
            lastContextLayoutState = field.contextLayoutState
            consoleScroll.setContentOffset(.zero,animated:false)
            view.setNeedsLayout()
        }
        sector.setTitle(String(format:"%02d/20",levelIndex+1),for:.normal)
        sector.accessibilityLabel = "Sector \(levelIndex + 1), \(session.level.name). Choose sector."
        undo.setEnabled(session.canUndo, temporarilyLocked: field.isRepeatingStrength)
        reset.isEnabled = !session.holes.isEmpty || session.phase != .setup || session.isInteracting
        sector.isEnabled = session.phase != .flying
        help.isEnabled = session.phase != .flying
        let canLaunch = resumeRequired ? active && !thermalPaused
            : !session.isInteracting && (session.phase != .setup || !thermalPaused)
        launch.setEnabled(canLaunch, temporarilyLocked: field.isRepeatingStrength && !thermalPaused && !resumeRequired)
        let flying = session.phase == .flying
        if speed.isHidden == flying { view.setNeedsLayout() }
        speed.isHidden = !flying
        speed.isEnabled = !thermalPaused && !resumeRequired
        field.isUserInteractionEnabled = !thermalPaused
        undo.isHidden = session.phase == .flying
        reset.isHidden = false
        speed.setTitle(session.isFastForwarding ? "4×" : "HOLD 4×", for: .normal)
        speed.backgroundColor = .clear
        speed.isSelected = session.isFastForwarding
        speed.accessibilityValue = session.isFastForwarding ? "4x" : "1x"
        switch session.phase {
        case .setup:
            launch.setTitle(session.launches > 0 ? "RETRY ↗" : "LAUNCH ↗", for: .normal)
            launch.accessibilityHint = "Launch the ship along the previewed route."
        case .flying:
            launch.setTitle(resumeRequired ? "RESUME ↗" : "ABORT", for: .normal)
            launch.accessibilityHint = resumeRequired ? "Continue the paused flight at normal speed." : "Stop this flight and return to editing."
        case .finished:
            launch.setTitle("RETRY ↗", for: .normal)
            launch.accessibilityHint = "Launch another flight immediately with your holes preserved."
        }
        updateInstrument()
        if !active || resumeRequired || thermalPaused || ArcadeFeedback.shared.muted { flightHaptics.stop() }
        else if session.phase != .flying { flightHaptics.stopMotion() }
        displayLink?.isPaused = !active || resumeRequired || thermalPaused || (session.phase != .flying && endingSeconds <= 0)
    }
    private func compactFeedback(_ message:String) -> String {
        if message.contains("hole limit") || message.contains("sector allows") { return "HOLE LIMIT" }
        if message.contains("clearance") { return "NEED SPACE" }
        if message.contains("Strength limited") { return "PULL LIMIT" }
        if message.contains("Not enough strength") { return "NEED 2 PULL" }
        if message.contains("Hatched zone") { return "BLOCKED ZONE" }
        if message.hasPrefix("Collision.") { return "IMPACT ×" }
        if message.hasPrefix("Inside the event horizon.") { return "CAPTURED ×" }
        if message.hasPrefix("Near miss.") { return "NEAR MISS" }
        if message.hasPrefix("Off course.") { return "OFF COURSE" }
        if message.hasPrefix("Flight timed out.") { return "TIME OUT" }
        if message.hasPrefix("No fuel.") { return "ADD A HOLE" }
        return message.uppercased()
    }
    private func presentFlightEvents(_ events:[FlightEvent]) {
        // One terminal outcome wins the batch. Portal/gate pulses from earlier
        // fixed steps must not overwrite a collision detected in the same frame.
        guard let event = events.last(where: { $0.kind.isTerminal }) ?? events.last else { return }
        let text:String, detail:String, lamp:InstrumentFeedback.Lamp
        switch event.kind {
        case .portalEnter: return // Entry+exit are an atomic physics pair.
        case .portalExit: text = "WORMHOLE →"; detail = "Wormhole transit complete"; lamp = .green
        case .beacon: text = "BEACON ✓"; detail = "Beacon collected. \(session.flight?.left ?? 0) remaining"; lamp = .green
        case .holeCapture: text = "CAPTURED ×"; detail = "Black hole capture. Give the ship more room"; lamp = .red
        case .planetImpact: text = "PLANET HIT ×"; detail = "Planet impact. Adjust the route"; lamp = .red
        case .asteroidImpact: text = "ROCK HIT ×"; detail = "Asteroid impact. Adjust the route"; lamp = .red
        case .repulsorImpact: text = "CORE HIT ×"; detail = "Repulsor impact. Adjust the route"; lamp = .red
        case .docked: text = "DOCKED ✓"; detail = "Docking confirmed"; lamp = .green
        case .lost, .stranded: text = compactFeedback(failureText); detail = failureText; lamp = .red
        }
        postInstrument(text,announcement:detail,lamp:lamp,priority:event.kind.isTerminal ? 90 : 30,
                       duration:event.kind.isTerminal ? 2.8 : 1.2)
    }
    private func clearInstrument() {
        instrumentTask?.cancel(); instrumentTask = nil; instrumentDeadline = nil
        instrumentFeedback.clear(); lastInputFeedback = nil
        session.discardFlightEvents()
    }
    private func postInstrument(_ text:String,announcement:String,lamp:InstrumentFeedback.Lamp,
                                priority:Int,duration:Double = 2.4) {
        let accepted = instrumentFeedback.post(text,announcement:announcement,lamp:lamp,
            priority:priority,now:CACurrentMediaTime(),duration:duration)
        guard accepted else { return }
        // Announce meaningful input/results, never the ticking flight baseline.
        if priority >= 50 { UIAccessibility.post(notification:.announcement,argument:announcement) }
        updateInstrument()
    }
    private func updateInstrument() {
        let now = CACurrentMediaTime()
        let message = instrumentFeedback.visible(at:now)
        let remaining = session.remainingPlacements
        let available = session.availableMatter.formatted(.number.precision(.fractionLength(0...2)))
        let budget = "\(available) PULL"
        var primary = "\(remaining) TO ADD"
        let secondary = budget
        var detail = "\(remaining) more \(remaining == 1 ? "hole" : "holes") can be placed. \(available) of \(Int(session.level.matter)) strength left."
        var lamp = instrumentFeedback.lamp(at:now)
        if session.phase == .flying {
            primary = "FLY \(session.isFastForwarding ? "4×" : "1×") \(session.flight?.left == 0 ? "DOCK" : "B\(session.flight?.left ?? 0)")"
            detail = "\(primary). \(String(format:"%.1f",session.flight?.time ?? 0)) seconds. \(detail)"
        }
        if session.phase == .finished && session.flight?.status == .won { primary = "DOCKED ✓" }
        if let message { primary = message.text; detail = "\(message.announcement) \(detail)" }
        if resumeRequired && session.phase == .flying {
            primary = "PAUSED"; lamp = .off
            detail = "Flight paused. Tap Resume to continue at normal speed."
        }
        if thermalPaused {
            primary = "COOLING"; lamp = .off
            detail = "Device warm. Flight paused until the device cools."
        }
        instrument.update(primary:primary,secondary:secondary,accessibility:detail,
            greenOn:lamp == .green,redOn:lamp == .red,budget:Float(session.availableMatter/max(1,session.level.matter)))
        let measured = instrument.height(for:instrument.bounds.width)
        if measured != lastInstrumentHeight {
            lastInstrumentHeight = measured; view.setNeedsLayout()
        }
        let deadline = instrumentFeedback.nextDeadline(after:now)
        if deadline != instrumentDeadline {
            instrumentTask?.cancel(); instrumentDeadline = deadline
            if let deadline {
                instrumentTask = Task { [weak self] in
                    try? await Task.sleep(for:.seconds(max(0,deadline-CACurrentMediaTime())))
                    guard !Task.isCancelled, let self else { return }
                    self.instrumentDeadline = nil; self.updateInstrument()
                }
            } else { instrumentTask = nil }
        }
    }
    private var failureText: String {
        switch session.flight?.status {
        case .won: "DOCKED. A little gravity goes a long way."
        case .crashed: "Collision. Adjust your holes and try again."
        case .imploded: "Inside the event horizon. Give the ship room."
        case .lost: nearDock ? "Near miss. Shift the pull slightly." : "Off course. Adjust your holes and try again."
        case .stranded: nearDock ? "Near miss. Shift the pull slightly." : "Flight timed out. Try a shorter route."
        default: "Ready for another flight."
        }
    }
    private var nearDock: Bool {
        guard let flight = session.flight, flight.left == 0, flight.closest.isFinite else { return false }
        // closest refers to gates until all are passed. Only then is it dock distance.
        return flight.closest < session.level.goal.r*2
    }
    @objc private func launchTapped() {
        if resumeRequired && session.phase == .flying {
            guard active, !thermalPaused else { updateControls(); return }
            resumeRequired = false; lastTimestamp = nil; updateControls(); persistSession(); return
        }
        resumeRequired = false
        field.cancelTouch()
        endingSeconds = 0
        flightHaptics.stop()
        clearInstrument()
        switch session.phase {
        case .setup, .finished:
            guard !thermalPaused else { updateControls(); return }
            if session.phase == .finished { session.retry() }
            recordedFinish = false
            if !session.launch() {
                postInstrument("ADD A HOLE",announcement:"No fuel. Place a black hole to pull the ship.",lamp:.red,priority:50)
                updateControls()
                if !ArcadeFeedback.shared.muted { haptics.notificationOccurred(.warning) }
                return
            }
            postInstrument("LAUNCHED",announcement:"Ship launched",lamp:.green,priority:30,duration:0.8)
        case .flying: session.retry()
        }
        lastTimestamp = nil
        updateControls()
        field.refresh(accessibility: true)
        persistSession()
    }
    @objc private func undoTapped() { session.undo(); clearInstrument(); updateControls(); field.refresh(accessibility: true); persistSession() }
    @objc private func resetTapped() {
        field.cancelTouch()
        panel?.removeFromSuperview(); panel = nil; panelReturnFocus = nil
        flightHaptics.stop()
        session.setFastForwarding(false)
        session.retry()
        session.reset()
        endingSeconds = 0
        resumeRequired = false
        recordedFinish = false
        lastTimestamp = nil
        clearInstrument()
        updateControls()
        field.refresh(accessibility: true)
        persistSession()
        field.focusPlacementCursor()
        UIAccessibility.post(notification: .announcement, argument: "Board reset. Strength restored.")
    }
    private func finishFlight(restoring: Bool = false) {
        guard !recordedFinish else { return }
        recordedFinish = true
        persistSession()
        guard session.flight?.status == .won else {
            endingSeconds = 1.1
            defaults.set(failureText, forKey: "orbit.lastOutcome.\(levelIndex)")
            if instrumentFeedback.visible(at:CACurrentMediaTime())?.priority != 90 {
                postInstrument(compactFeedback(failureText),announcement:failureText,lamp:.red,priority:90)
            }
            return
        }

        defaults.set("Docking confirmed.", forKey: "orbit.lastOutcome.\(levelIndex)")
        unlocked = max(unlocked, min(levels.count - 1, levelIndex + 1))
        defaults.set(unlocked, forKey: "orbit.unlocked")
        let used = session.level.matter - session.availableMatter
        if !session.assisted {
            let holeKey = "orbit.best.holes.\(levelIndex)", matterKey = "orbit.best.matter.\(levelIndex)"
            let bestHoles = min(defaults.object(forKey: holeKey) as? Int ?? Int.max, session.holes.count)
            let bestMatter = min((defaults.object(forKey: matterKey) as? NSNumber)?.doubleValue ?? .infinity, used)
            defaults.set(bestHoles, forKey: holeKey); defaults.set(bestMatter, forKey: matterKey)
        }
        guard let record = FlightRecord(session: session, sectorIndex: levelIndex, sectorCount: levels.count) else { return }
        if !restoring || savedVictory == nil, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: "orbit.lastVictory.v1")
        }
        let revealFinale = record.isFinalSector && !restoring && !defaults.bool(forKey: "orbit.finalePresented.v1")
        if revealFinale { defaults.set(true, forKey: "orbit.finalePresented.v1") }
        showVictory(record, retainLayout: true, celebrate: revealFinale)
    }

    private func showVictory(_ record: FlightRecord, retainLayout: Bool, celebrate: Bool = false) {
        let holeKey = "orbit.best.holes.\(record.sectorIndex)", pullKey = "orbit.best.matter.\(record.sectorIndex)"
        var records: [String] = []
        if let holes = defaults.object(forKey: holeKey) as? Int, holes >= 0 {
            records.append("fewest holes \(holes)")
        }
        if let pull = (defaults.object(forKey: pullKey) as? NSNumber)?.doubleValue, pull.isFinite, pull >= 0 {
            records.append("least pull \(pull.formatted(.number.precision(.fractionLength(0...1))))")
        }
        let content = VictoryContentView(record: record,
            records: records.isEmpty ? nil : "Sector records: " + records.joined(separator: "; "))
        var actions: [ArcadePanel.Action] = []
        let share = ArcadePanel.Action(title: "Share result", identifier: "shareResult", dismissesPanel: false) { [weak self] in
            self?.shareVictory(record)
        }
        if !record.isFinalSector {
            let nextIndex = record.sectorIndex + 1
            actions.append(.init(title: "Next sector") { [weak self] in
                guard let self else { return }; self.loadSector(nextIndex)
            })
        } else {
            // Match Next sector's stable footer placement at the end of the
            // campaign. Starting over still requires a separate confirmation.
            actions.append(.init(title: "Start over", identifier: "startOverCampaign", dismissesPanel: false) { [weak self] in
                self?.confirmCampaignRestart()
            })
        }
        actions.append(.init(title: retainLayout ? "Replay sector" : "Play this sector") { [weak self] in
            guard let self else { return }
            if retainLayout && self.levelIndex == record.sectorIndex {
                self.clearInstrument(); self.flightHaptics.stop(); self.session.retry()
                self.updateControls(); self.field.refresh(accessibility: true); self.persistSession()
                UIAccessibility.post(notification: .screenChanged, argument: self.launch)
            } else { self.loadSector(record.sectorIndex) }
        })
        if record.assisted {
            actions.append(.init(title: "Find my own route") { [weak self] in self?.loadSector(record.sectorIndex) })
        }
        actions.append(share)
        if record.isFinalSector {
            actions.append(.init(title: "Choose a sector") { [weak self] in self?.openSectors() })
        }
        showPanel(title: record.title, message: "", actions: actions, content: content, expanded: record.isFinalSector)
        if celebrate { content.celebrate() }
    }

    private func confirmCampaignRestart() {
        guard presentedViewController == nil else { return }
        panel?.settlePresentation()
        let confirmation = CampaignRestartConfirmation { [weak self] confirmed in
            guard let self else { return }
            if confirmed { self.restartCampaign() }
            else {
                UIAccessibility.post(notification: .screenChanged,
                    argument: self.panel?.actionButton(identifier: "startOverCampaign"))
            }
        }
        present(confirmation, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func restartCampaign() {
        guard let first = levels.first else { return }
        // Old asynchronous encodes may finish, but their generation can never commit.
        checkpointGeneration += 1
        checkpointTask?.cancel(); checkpointTask = nil
        endCheckpointBackgroundTask()
        field.cancelTouch()
        flightHaptics.stop()
        clearInstrument()
        session.restartCampaign(at: first)
        levelIndex = 0; unlocked = 0
        resumeRequired = false; recordedFinish = false; endingSeconds = 0
        lastTimestamp = nil; lastInputFeedback = nil
        victoryShareItem = nil
        CampaignProgress.reset(in: defaults)
        // No old checkpoint survives this synchronous boundary. Until the fresh
        // snapshot commits, a normal launch creates the same empty sector 1.
        dismissAllOverlays()
        field.refresh(accessibility: true)
        persistSession()
        UIAccessibility.post(notification: .screenChanged, argument: sector)
        UIAccessibility.post(notification: .announcement, argument: "Campaign restarted. Sector 1.")
    }

    private func shareVictory(_ record: FlightRecord) {
        guard presentedViewController == nil else { return }
        panel?.settlePresentation()
        if victoryShareItem?.record != record { victoryShareItem = VictoryShareItem(record: record) }
        guard let item = victoryShareItem else { return }
        let controller = UIActivityViewController(activityItems: item.activityItems, applicationActivities: nil)
        let anchor = panel?.actionButton(identifier: "shareResult") ?? view!
        controller.popoverPresentationController?.sourceView = anchor
        controller.popoverPresentationController?.sourceRect = anchor.bounds
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            Task { @MainActor [weak self] in
                UIAccessibility.post(notification: .screenChanged,
                    argument: self?.panel?.actionButton(identifier: "shareResult"))
            }
        }
        present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func loadSector(_ index: Int) {
        guard levels.indices.contains(index) else { return }
        field.cancelTouch()
        endingSeconds = 0
        flightHaptics.stop()
        clearInstrument()
        levelIndex = index
        resumeRequired = false
        session.load(level: levels[index])
        defaults.set(index, forKey: "orbit.current")
        recordedFinish = false
        lastTimestamp = nil
        updateControls()
        field.refresh(accessibility: true)
        persistSession()
        UIAccessibility.post(notification: .screenChanged, argument: sector)
    }
    private func showPanel(title: String, message: String, actions: [ArcadePanel.Action], returnFocus: UIView? = nil,
                           content: VictoryContentView? = nil, expanded: Bool = false) {
        field.dismissEditor()
        panel?.removeFromSuperview()
        panelReturnFocus = returnFocus ?? launch
        let panel = ArcadePanel(title: title, message: message, actions: actions, content: content, expanded: expanded)
        panel.onDismiss = { [weak self] in
            self?.panel = nil; self?.panelReturnFocus = nil; self?.view.setNeedsLayout()
        }
        panel.onCancel = { [weak self] in self?.dismissAllOverlays() }
        panel.frame = view.bounds
        panel.dockFrame = consoleFrame
        panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(panel)
        self.panel = panel
        view.setNeedsLayout(); view.layoutIfNeeded()
        // The modal dock owns its area; do not overlay Reset on its footer.
        UIAccessibility.post(notification: .screenChanged, argument: panel)
    }
    @objc private func openSectors() {
        field.cancelTouch()
        var actions = levels.enumerated().map { index, level in
            ArcadePanel.Action(title: String(format: "%02d  ", index + 1) + level.name + (index > unlocked ? " · LOCKED" : ""),
                               enabled: index <= unlocked) { [weak self] in self?.loadSector(index) }
        }
        actions.insert(.init(title: "Keep playing") { [weak self] in
            UIAccessibility.post(notification: .screenChanged, argument: self?.sector)
        }, at: 0)
        showPanel(title: "Sector index", message: "\(unlocked + 1) OF \(levels.count) SECTORS UNLOCKED\nChoosing a sector starts a fresh layout. Unlocked sectors and bests are kept.", actions: actions, returnFocus: sector)
    }
    @objc private func openHelp() {
        field.cancelTouch()
        let remaining = session.remainingPlacements
        let lastOutcome = defaults.string(forKey: "orbit.lastOutcome.\(levelIndex)")
        let context = (lastOutcome.map { "Last flight: \($0)\n\n" } ?? "")
            + "Sector \(levelIndex + 1): \(session.level.hint)"
        let budget = "PULL is strength. \(remaining) more \(remaining == 1 ? "hole" : "holes") · \(session.availableMatter.formatted(.number.precision(.fractionLength(0...1)))) / \(Int(session.level.matter)) pull left. New holes use 2."
        let editing = "Tap to place. Hold ↑↓ for strength.\nStart sideways, then drag freely to move on the grid.\nHold +/− for repeated 0.5 steps.\nTap empty space to close controls."
        let flight = "Collect diamond beacons, then reach the teal dock. Avoid solid obstacles.\nMatching portal marks lead to each other. Dashed-ring holes are fixed.\nWhite dots predict; gray shows your last route.\nA hole's dark core ends the flight; its glow is decorative.\nHold 4× in flight; release for 1×. Retry keeps your layout."
        let assistance = "Playing a solution keeps edits assisted until Reset or all holes are removed."
        let message = [context,budget,editing,flight,assistance].joined(separator:"\n\n")
        showPanel(title: "A little gravity", message: message, actions: [
            .init(title: "Keep playing") { [weak self] in
                UIAccessibility.post(notification: .screenChanged, argument: self?.help)
            },
            .init(title: "View last result", enabled: savedVictory != nil) { [weak self] in
                guard let self, let record = self.savedVictory else { return }
                self.showVictory(record, retainLayout: false)
            },
            .init(title: ArcadeFeedback.shared.muted ? "Enable haptics" : "Mute haptics") { [weak self] in
                ArcadeFeedback.shared.muted.toggle()
                if ArcadeFeedback.shared.muted { self?.flightHaptics.stop() }
                self?.updateControls()
                UIAccessibility.post(notification: .screenChanged, argument: self?.help)
            },
            .init(title: "Reset layout", enabled: !session.holes.isEmpty || session.phase != .setup) { [weak self] in self?.resetTapped() },
            .init(title: "Play solution", enabled: session.phase == .setup && !thermalPaused) { [weak self] in
                guard let self, !self.thermalPaused, self.session.phase == .setup else { return }
                self.clearInstrument(); self.flightHaptics.stop(); self.session.showSolution(); self.updateControls(); self.field.refresh(accessibility: true)
                self.launchTapped()
                UIAccessibility.post(notification: .screenChanged, argument: self.launch)
            }
        ], returnFocus: help)
    }
}

private actor CheckpointEncoder {
    func encode(_ checkpoint: GameSession.Checkpoint) throws -> Data {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(checkpoint)
        try Task.checkCancellation()
        return data
    }
}

@MainActor private final class DisplayTarget: NSObject {
    weak var controller: GameViewController?
    init(controller: GameViewController) { self.controller = controller }
    @objc func frame(_ link: CADisplayLink) {
        guard let controller else { link.invalidate(); return }
        controller.frame(link)
    }
}

/// The Milk cabinet treatment: square borders, original carton, pink actions, teal trim.
@MainActor private final class ArcadePanel: UIView {
    struct Action {
        let title: String
        var enabled = true
        var identifier: String?
        var dismissesPanel = true
        let perform: () -> Void
        init(title: String, enabled: Bool = true, identifier: String? = nil, dismissesPanel: Bool = true, perform: @escaping () -> Void) {
            self.title = title; self.enabled = enabled; self.identifier = identifier
            self.dismissesPanel = dismissesPanel; self.perform = perform
        }
    }
    var onDismiss: (() -> Void)?
    var onCancel: (() -> Void)?
    var dockFrame = CGRect.zero
    private let backdrop = UIControl()
    private let card = PaintedMaterial.surface(compact:true)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let footer = UIStackView()
    private let resultContent: VictoryContentView?
    private let expanded: Bool
    private let expandedCabinet: CabinetShell?
    private var actionButtons: [String: UIButton] = [:]
    private var measuredButtons: [(UIButton, NSLayoutConstraint)] = []
    private var primaryButton: UIButton?
    private var scrollingPrimary = false
    private var lastLayoutSize = CGSize.zero

    init(title: String, message: String, actions: [Action], content: VictoryContentView? = nil, expanded: Bool = false) {
        resultContent = content; self.expanded = expanded
        expandedCabinet = expanded ? CabinetShell() : nil
        super.init(frame: .zero)
        accessibilityIdentifier = "arcadePanel"
        accessibilityViewIsModal = true
        // A full result replaces the gameplay surface, including the narrow
        // bands outside its card. Docked dialogs deliberately keep the world.
        backgroundColor = expanded ? Palette.black : .clear
        addSubview(backdrop)
        if let expandedCabinet { backdrop.addSubview(expandedCabinet) }
        backdrop.accessibilityLabel = "Close dialog"
        backdrop.accessibilityIdentifier = "dismissOverlay"
        backdrop.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        card.isUserInteractionEnabled = true
        card.backgroundColor = Palette.black
        addSubview(card)
        card.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -9),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -18)
        ])
        footer.axis = .vertical
        footer.spacing = 8
        card.addSubview(footer)
        let header = UIStackView()
        header.spacing = 12
        header.alignment = .center
        let carton = UIImageView(image: Palette.carton)
        carton.contentMode = .scaleAspectFit
        carton.layer.magnificationFilter = .nearest
        carton.backgroundColor = .clear
        carton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        carton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        header.addArrangedSubview(carton)
        let heading = UILabel()
        heading.text = title.uppercased()
        Palette.applyTypeface(to:heading,weight:.bold)
        heading.textColor = Palette.white
        heading.numberOfLines = 0
        heading.accessibilityLabel = title
        heading.accessibilityTraits = .header
        header.addArrangedSubview(heading)
        stack.addArrangedSubview(header)
        let trim = UIView()
        trim.backgroundColor = Palette.teal
        trim.heightAnchor.constraint(equalToConstant: 4).isActive = true
        stack.addArrangedSubview(trim)
        if let content { stack.addArrangedSubview(content) }
        let body = UILabel()
        body.text = message
        Palette.applyTypeface(to:body)
        body.textColor = Palette.white
        body.numberOfLines = 0
        if !message.isEmpty { stack.addArrangedSubview(body) }
        for (index, action) in actions.enumerated() {
            let button = ArcadeButton(type: .custom)
            button.setTitle(action.title.uppercased(), for: .normal)
            button.accessibilityLabel = action.title
            button.accessibilityIdentifier = action.identifier
            if let identifier = action.identifier { actionButtons[identifier] = button }
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.titleLabel?.font = Palette.typeface(weight: .bold)
            button.titleLabel?.adjustsFontSizeToFitWidth = false
            button.setTitleColor(Palette.black, for: .normal)
            button.setTitleColor(Palette.muted, for: .disabled)
            Palette.button(button, color: index == 0 ? Palette.pink : .white)
            let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
            height.isActive = true
            measuredButtons.append((button, height))
            button.isEnabled = action.enabled
            button.addAction(UIAction { [weak self] _ in
                self?.settlePresentation()
                if action.dismissesPanel { self?.removeFromSuperview(); self?.onDismiss?() }
                action.perform()
            }, for: .touchUpInside)
            if index == 0 { primaryButton = button; footer.addArrangedSubview(button) }
            else { stack.addArrangedSubview(button) }
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(title:message:actions:)") }
    func actionButton(identifier: String) -> UIButton? { actionButtons[identifier] }
    func settlePresentation() { resultContent?.settle() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { settlePresentation() } }
    override func accessibilityPerformEscape() -> Bool { onCancel?(); return true }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize { settlePresentation(); lastLayoutSize = bounds.size }
        backdrop.frame = bounds
        expandedCabinet?.frame = backdrop.bounds
        let docked = !expanded && !dockFrame.isEmpty
        var safe = docked ? dockFrame : bounds.inset(by:safeAreaInsets).insetBy(dx:16,dy:12)
        if docked || expanded {
            let clearance = CabinetShell.faceClearance(in: bounds.size)
            let top = max(safe.minY, clearance), bottom = min(safe.maxY, bounds.maxY-clearance)
            safe.origin.y = top; safe.size.height = max(0,bottom-top)
        }
        if expanded, #available(iOS 27.1, *) {
            let reserved = (reservedRegions(kind: .division) + reservedRegions(kind: .occlusion)).map(\.frame)
            safe = CabinetLayout.presentationArea(in: safe, avoiding: reserved)
        }
        // Content constraints seat the card independently of the full-window cabinet.
        let contentFrame = CabinetShell.panelContentFrame(in:bounds,safeInsets:safeAreaInsets)
        let contained = safe.intersection(contentFrame)
        if !contained.isNull { safe = contained }
        let width = safe.width
        footer.axis = .vertical
        let inlaid = docked || expanded
        card.image = inlaid ? nil : PaintedMaterial.panel
        card.backgroundColor = inlaid ? PaintedMaterial.cabinetPaint : Palette.black
        card.frame = safe
        let font = Palette.typeface(weight: .bold, compatibleWith: traitCollection)
        for (button, height) in measuredButtons {
            let textHeight = ((button.currentTitle ?? "") as NSString).boundingRect(
                with: CGSize(width: max(1, width - 44), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height
            height.constant = max(48, ceil(textHeight) + 20)
        }
        let footerHeight = (measuredButtons.first?.1.constant ?? 48) + 8
        // If a large-text primary action would consume the body, scroll one
        // coherent surface with the action near the heading instead of clipping it.
        let needsScrollingPrimary = safe.height - footerHeight < max(88, font.lineHeight * 2)
        if scrollingPrimary != needsScrollingPrimary, let primaryButton {
            scrollingPrimary = needsScrollingPrimary
            if scrollingPrimary {
                footer.removeArrangedSubview(primaryButton); primaryButton.removeFromSuperview()
                stack.insertArrangedSubview(primaryButton, at: min(2, stack.arrangedSubviews.count))
            } else {
                stack.removeArrangedSubview(primaryButton); primaryButton.removeFromSuperview()
                footer.addArrangedSubview(primaryButton)
            }
        }
        footer.isHidden = scrollingPrimary
        scroll.frame = CGRect(x: 3, y: 3, width: max(0, width - 6),
            height: max(0, safe.height - (scrollingPrimary ? 6 : footerHeight + 6)))
        footer.frame = CGRect(x: 8, y: max(0, safe.height - footerHeight), width: max(0, width - 16), height: footerHeight - 4)

    }
}

/// Orientation-specific cabinet compositions. Artwork stays contained; native
/// branding and controls never cover the ship. No timer or idle drawing loop.
@MainActor final class ArcadeSplash: UIView {
    var onPlay: (() -> Void)?
    private let cabinet = CabinetShell()
    private let scroll = UIScrollView()
    private let artwork = UIImageView()
    private let carton = UIImageView(image: Palette.carton)
    private let title = UILabel()
    private let play = ArcadeButton(type: .custom)
    private let readiness = UILabel()
    private static let portrait = UIImage(named: "SplashPortrait") ?? UIImage(named: "ArcadeSplash")
    private static let landscape = UIImage(named: "SplashLandscape") ?? UIImage(named: "ArcadeSplash")
    private var wideComposition: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.black
        accessibilityIdentifier = "arcadeSplash"
        accessibilityViewIsModal = true
        addSubview(cabinet)
        addSubview(scroll)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = true
        scroll.indicatorStyle = .white
        artwork.contentMode = .scaleAspectFit
        artwork.clipsToBounds = true
        artwork.isAccessibilityElement = false
        artwork.layer.magnificationFilter = .nearest
        scroll.addSubview(artwork)
        carton.contentMode = .scaleAspectFit
        carton.layer.magnificationFilter = .nearest
        carton.isAccessibilityElement = false
        scroll.addSubview(carton)
        title.textColor = Palette.white
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header
        title.accessibilityLabel = "Milk Orbit"
        scroll.addSubview(title)
        play.setTitle("PLAY ↗", for: .normal)
        play.accessibilityIdentifier = "playButton"
        play.accessibilityLabel = "Play"
        play.titleLabel?.numberOfLines = 0
        Palette.button(play, color: Palette.pink)
        play.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)
        scroll.addSubview(play)
        Palette.applyTypeface(to: readiness)
        readiness.textColor = Palette.white
        readiness.numberOfLines = 0
        readiness.textAlignment = .center
        readiness.accessibilityIdentifier = "startupStatus"
        scroll.addSubview(readiness)
        accessibilityElements = [title, readiness, play]
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ArcadeSplash, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }
    func preparing(requestedPlay: Bool = false) {
        readiness.text = requestedPlay ? "Opening when ready…" : "Preparing your sector…"
        // Keep the button's footprint fixed while a queued Play waits for loading.
        play.setTitle("PLAY ↗", for: .normal)
        play.isEnabled = !requestedPlay
        play.accessibilityHint = requestedPlay ? "The game will open automatically." : "Opens as soon as your sector is ready."
        setNeedsLayout()
    }
    func ready() {
        readiness.text = "Ready to play."
        play.setTitle("PLAY ↗", for: .normal)
        play.isEnabled = true
        play.accessibilityHint = "Open your sector."
        setNeedsLayout()
    }
    func failed(canRecover: Bool = false) {
        readiness.text = canRecover ? "Saved board couldn’t load. Start a new board; the original save will be kept." : "Couldn’t prepare the game. Your saved board is preserved."
        play.setTitle(canRecover ? "NEW BOARD" : "RETRY", for: .normal)
        play.isEnabled = true
        play.accessibilityHint = readiness.text
        setNeedsLayout()
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layoutSubviews() {
        super.layoutSubviews()
        var safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 8, dy: 8)
        if #available(iOS 27.1, *) {
            let reserved = (reservedRegions(kind: .division) + reservedRegions(kind: .occlusion)).map(\.frame)
            safe = CabinetLayout.presentationArea(in: safe, avoiding: reserved)
        }
        guard safe.width > 0, safe.height > 0 else { return }
        // The casing is the window backdrop, as on the game and reset screens.
        // Only interactive content is inset from system safe/reserved regions.
        cabinet.frame = bounds
        let inset = CabinetShell.faceClearance(in: safe.size)
        scroll.frame = safe.insetBy(dx: inset, dy: inset)
        let area = CGRect(origin: .zero, size: scroll.bounds.size)
        let wide = bounds.width > bounds.height && area.width >= 500
        if wideComposition != wide {
            artwork.image = wide ? Self.landscape : Self.portrait
            title.text = wide ? "MILK\nORBIT" : "MILK ORBIT"
            wideComposition = wide
            scroll.contentOffset = .zero
        }
        title.font = Palette.titleTypeface(compatibleWith: traitCollection)
        Palette.applyTypeface(to: readiness)
        if let label = play.titleLabel { Palette.applyTypeface(to: label, weight: .bold) }
        let gap: CGFloat = 16
        let controlWidth = wide ? max(240, area.width * 0.35) : area.width
        let controlX = wide ? area.maxX - controlWidth : area.minX
        let logoSize: CGFloat = 52
        let titleWidth = max(1, controlWidth - logoSize - 12)
        let titleHeight = ceil(title.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let identityHeight = max(logoSize, titleHeight)
        let font = Palette.typeface(compatibleWith: traitCollection)
        // Reserve normal loading/ready copy so async readiness doesn't move Play.
        let statusHeight = max(font.lineHeight * 2,
            ceil(readiness.sizeThatFits(CGSize(width: controlWidth, height: .greatestFiniteMagnitude)).height))
        let buttonHeight = max(52, ceil(play.titleLabel?.sizeThatFits(
            CGSize(width: max(1, controlWidth - 20), height: .greatestFiniteMagnitude)).height ?? font.lineHeight) + 18)
        let deckHeight = statusHeight + 10 + buttonHeight
        let identityY: CGFloat
        let playY: CGFloat
        let imageBounds: CGRect
        let contentHeight: CGFloat
        if wide {
            // The left screen and right control deck are separate spatial zones.
            contentHeight = max(area.height, identityHeight + gap + deckHeight)
            identityY = max(0, (contentHeight - identityHeight - gap - deckHeight) / 2)
            playY = identityY + identityHeight + gap + statusHeight + 10
            imageBounds = CGRect(x: 0, y: 0, width: max(1, controlX - gap), height: area.height)
        } else {
            // Portrait reads vertically: marquee, illustrated screen, control deck.
            let minimumArtHeight = min(area.width, area.height * 0.35)
            contentHeight = max(area.height, identityHeight + gap * 2 + minimumArtHeight + deckHeight)
            identityY = 0
            playY = contentHeight - buttonHeight
            imageBounds = CGRect(x: 0, y: identityHeight + gap, width: area.width,
                height: contentHeight - identityHeight - deckHeight - gap * 2)
        }
        carton.frame = CGRect(x: controlX, y: identityY + (identityHeight - logoSize) / 2,
            width: logoSize, height: logoSize)
        title.frame = CGRect(x: controlX + logoSize + 12, y: identityY,
            width: titleWidth, height: identityHeight)
        play.frame = CGRect(x: controlX, y: playY, width: controlWidth, height: buttonHeight)
        readiness.frame = CGRect(x: controlX, y: playY - 10 - statusHeight,
            width: controlWidth, height: statusHeight)
        let imageSize = artwork.image?.size ?? CGSize(width: 1, height: 1)
        let scale = min(imageBounds.width / imageSize.width, imageBounds.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        artwork.frame = CGRect(x: imageBounds.midX - fitted.width / 2,
            y: imageBounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        scroll.contentSize = CGSize(width: area.width, height: contentHeight)
        scroll.alwaysBounceVertical = false
        scroll.isScrollEnabled = contentHeight > area.height + 1
        // The cabinet aperture follows the contained illustration, never its crop.
        let artInCabinet = scroll.convert(artwork.frame,to:cabinet)
        let visibleContent = scroll.convert(scroll.bounds,to:cabinet)
        cabinet.configure(field: scroll.isScrollEnabled ? .zero : artInCabinet,
            surround: visibleContent.insetBy(dx:-8,dy:-8), header: .zero, console: .zero)
    }
}

@MainActor private final class FlightHaptics {
    private var engine: CHHapticEngine?
    private var motionPlayer: (any CHHapticAdvancedPatternPlayer)?
    private var eventPlayers: [FlightHapticCue.Kind: any CHHapticAdvancedPatternPlayer] = [:]
    private var mapper = FlightHapticMapper()
    private var eventMapper = FlightHapticEventMapper()
    private var running = false
    private var failed = false
    private var elapsedSinceUpdate = 0.0
    private var eventBusyUntil = 0.0
    private var portalBusyUntil = 0.0
    private var stopTask: Task<Void, Never>?
    private var engineGeneration: UInt64 = 0
    private lazy var supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func update(session: GameSession, elapsed: Double, events: [FlightEvent]) {
        let now = ProcessInfo.processInfo.systemUptime
        let state = ProcessInfo.processInfo.thermalState
        let allowed = !ArcadeFeedback.shared.muted && UIApplication.shared.applicationState == .active
            && state != .serious && state != .critical
        let cues = eventMapper.consume(events, wallTime: now, enabled: allowed && supported && !failed)
        guard allowed else { stop(); return }
        guard supported, !failed else { return }
        do {
            if !cues.isEmpty {
                let engine = try startedEngine()
                stopMotion()
                let nativeStart = engine.currentTime + 0.01
                for cue in cues {
                    let recipe = FlightHapticRecipe.recipe(for: cue.kind)
                    // Preserve an earlier frame's still-playing portal exit before a
                    // subsequent terminal cue. This never delays the simulation/UI.
                    let delay = cue.kind == .portalTransit ? cue.delay
                        : max(cue.delay, portalBusyUntil - now)
                    if eventPlayers[cue.kind] == nil {
                        eventPlayers[cue.kind] = try engine.makeAdvancedPlayer(with: Self.pattern(recipe))
                    }
                    try eventPlayers[cue.kind]?.start(atTime: nativeStart + delay)
                    let end = now + 0.01 + delay + recipe.duration
                    eventBusyUntil = max(eventBusyUntil, end + 0.08)
                    if cue.kind == .portalTransit { portalBusyUntil = end + 0.01 }
                }
            }
            guard session.phase == .flying, let flight = session.flight else {
                stopMotion()
                if running {
                    stopTask?.cancel()
                    let delay = max(0, eventBusyUntil - now)
                    // One finite completion task, canceled by reset/retry/lifecycle.
                    stopTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled else { return }
                        self?.stop()
                    }
                }
                return
            }
            guard now >= eventBusyUntil else { return }
            elapsedSinceUpdate += elapsed
            guard elapsedSinceUpdate >= 1.0 / 30 else { return }
            let dt = elapsedSinceUpdate; elapsedSinceUpdate = 0
            var sources = session.holes.map {
                FlightHapticAttractor(id: $0.id.uuidString, position: $0.position,
                                      mass: $0.mass, radius: Physics.horizonRadius(mass: $0.mass))
            }
            sources += session.level.bodies.enumerated().map { index, body in
                FlightHapticAttractor(id: "body-\(index)", position: Physics.bodyAt(body: body, time: flight.time),
                                      mass: body.mass, radius: body.r, isPlayerHole: false)
            }
            let acceleration = Physics.pullAt(level: session.level, holes: session.holes,
                                              x: flight.x, y: flight.y, time: flight.time)
            let sample = mapper.update(active: true, position: flight.position, velocity: flight.velocity,
                                       acceleration: acceleration, attractors: sources, elapsed: dt)
            guard sample.shouldPulse else { return }
            let engine = try startedEngine()
            if motionPlayer == nil {
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                    CHHapticEventParameter(parameterID: .attackTime, value: 0.15),
                    CHHapticEventParameter(parameterID: .releaseTime, value: 0.2)
                ], relativeTime: 0, duration: 0.22)
                motionPlayer = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            }
            try motionPlayer?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(sample.intensity), relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Float(sample.sharpness - 0.5), relativeTime: 0)
            ], atTime: CHHapticTimeImmediate)
            try motionPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            stop(); motionPlayer = nil; eventPlayers.removeAll(); engine = nil; failed = true
            // One log, no retry loop. The instrument/AX still explains the exact event.
            NSLog("MilkOrbit flight haptics unavailable: %@", String(describing: error))
        }
    }

    private func startedEngine() throws -> CHHapticEngine {
        if engine == nil {
            let created = try CHHapticEngine()
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = true
            created.resetHandler = { [weak self, weak created] in Task { @MainActor in
                guard let self, let created, self.engine === created else { return }
                self.running = false
                self.stop()
                self.motionPlayer = nil; self.eventPlayers.removeAll(); self.engine = nil
            } }
            engine = created
        }
        let engine = engine!
        if !running {
            engineGeneration &+= 1
            let generation = engineGeneration
            engine.stoppedHandler = { [weak self] _ in Task { @MainActor in
                guard let self, self.engineGeneration == generation else { return }
                self.running = false; self.mapper.reset(); self.elapsedSinceUpdate = 0
            } }
            try engine.start(); running = true
        }
        return engine
    }

    private static func pattern(_ recipe: FlightHapticRecipe) throws -> CHHapticPattern {
        var events = recipe.transients.map {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float($0.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float($0.sharpness))
            ], relativeTime: $0.time)
        }
        var curves: [CHHapticParameterCurve] = []
        if let end = recipe.envelope.last {
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ], relativeTime: 0, duration: end.time))
            var intensity = recipe.envelope.map { CHHapticParameterCurve.ControlPoint(relativeTime: $0.time, value: Float($0.intensity)) }
            var sharpness = recipe.envelope.map { CHHapticParameterCurve.ControlPoint(relativeTime: $0.time, value: Float($0.sharpness - 0.5)) }
            if recipe.transients.contains(where: { $0.time > end.time }) {
                // Dynamic controls affect all haptics in the player. Restore their
                // defaults after the pull envelope so the exit pop is not muted.
                intensity.append(.init(relativeTime: end.time + 0.01, value: 1))
                sharpness.append(.init(relativeTime: end.time + 0.01, value: 0))
            }
            curves = [CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: intensity, relativeTime: 0),
                      CHHapticParameterCurve(parameterID: .hapticSharpnessControl, controlPoints: sharpness, relativeTime: 0)]
        }
        return try CHHapticPattern(events: events, parameterCurves: curves)
    }

    // Phase transitions may stop motion without chopping off the terminal cue.
    func stopMotion() {
        mapper.reset(); elapsedSinceUpdate = 0
        if running { try? motionPlayer?.stop(atTime: CHHapticTimeImmediate) }
    }

    // Explicit user/lifecycle boundary cancels every pending cue, including exit pops.
    func stop() {
        stopTask?.cancel(); stopTask = nil
        stopMotion()
        eventMapper.resetCadence() // Preserve consumed sequence identity.
        eventBusyUntil = 0; portalBusyUntil = 0; failed = false
        let wasRunning = running
        running = false
        engineGeneration &+= 1
        if wasRunning {
            for player in eventPlayers.values { try? player.stop(atTime: CHHapticTimeImmediate) }
            engine?.stop(completionHandler: nil)
        }
    }
}
