import UIKit
import OrbitCore

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Game", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = StartupViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
    func sceneWillResignActive(_ scene: UIScene) {
        (window?.rootViewController as? StartupViewController)?.game?.setActive(false)
    }
    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? StartupViewController)?.game?.persistSession(background: true)
    }
    @available(iOS 26.0, *)
    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        (window?.rootViewController as? StartupViewController)?.game?.sceneGeometryDidChange()
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        (window?.rootViewController as? StartupViewController)?.game?.persistSession()
        (window?.rootViewController as? StartupViewController)?.game?.stopDisplayLink()
        (window?.rootViewController as? StartupViewController)?.cancelPreparation()
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        (window?.rootViewController as? StartupViewController)?.game?.setActive(true)
    }
}

// The initial root owns only presentation. No catalog or saved-game work runs
// until the splash has appeared, and no unprepared session can be persisted.
struct PreparedGame {
    let levels: [Level]
    let session: GameSession
    let index: Int
    let unlocked: Int
}

private actor GameLoader {
    enum LoadError: Error { case savedGameTooLarge, invalidSavedGame }
    func load(startFresh: Bool) async throws -> sending PreparedGame {
        try Task.checkCancellation()
        let levels = try LevelCatalog.load()
        let defaults = UserDefaults.standard
        let unlocked = min(levels.count - 1, max(0, defaults.integer(forKey: "orbit.unlocked")))
        var index = min(unlocked, max(0, defaults.integer(forKey: "orbit.current")))
        var restored: GameSession?
        if startFresh, let original = defaults.data(forKey: "orbit.checkpoint.v1") {
            defaults.set(original, forKey: "orbit.checkpoint.recovery.v1")
        }
        if !startFresh, let data = defaults.data(forKey: "orbit.checkpoint.v1") {
            // Reject pathological input before JSON allocations. Never delete the
            // original checkpoint on load failure; Retry stays on the splash.
            guard data.count <= 32 * 1024 * 1024 else { throw LoadError.savedGameTooLarge }
            if let checkpoint = try? JSONDecoder().decode(GameSession.Checkpoint.self, from: data) {
                let matches = levels.indices.filter { checkpoint.matches(levels[$0]) }
                if matches.count == 1, let savedIndex = matches.first, savedIndex <= unlocked {
                    restored = try? GameSession(restoring: checkpoint, level: levels[savedIndex])
                    if restored != nil { index = savedIndex }
                }
            }
            guard restored != nil else { throw LoadError.invalidSavedGame }
            if let restored, restored.pruneCachedTrails(keeping: Set(levels.map(\.name))),
               defaults.object(forKey: "orbit.checkpoint.catalogRecovery.v1") == nil {
                defaults.set(data, forKey: "orbit.checkpoint.catalogRecovery.v1")
            }
        }
        let session = restored ?? GameSession(level: levels[index])
        try Task.checkCancellation()
        return PreparedGame(levels: levels, session: session, index: index, unlocked: unlocked)
    }
}

@MainActor final class StartupViewController: UIViewController {
    private(set) var game: GameViewController?
    private let loader = GameLoader()
    private var splash: ArcadeSplash?
    private var preparation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = 0
    private var requestedPlay = false
    private var failed = false
    private var recoveryAvailable = false
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.black
        let splash = ArcadeSplash()
        splash.preparing()
        splash.onPlay = { [weak self] in self?.play() }
        view.addSubview(splash)
        self.splash = splash
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        game?.view.frame = view.bounds
        splash?.frame = view.bounds
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if game == nil, preparation == nil { prepare() }
    }
    private func prepare(startFresh: Bool = false) {
        cancelPreparation()
        failed = false; recoveryAvailable = false; requestedPlay = false
        splash?.preparing()
        let current = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await loader.load(startFresh: startFresh)
                try Task.checkCancellation()
                guard generation == current else { return }
                let controller = GameViewController(prepared: prepared)
                addChild(controller)
                controller.view.frame = view.bounds
                view.insertSubview(controller.view, at: 0)
                controller.didMove(toParent: self)
                game = controller
                deadline?.cancel(); deadline = nil; preparation = nil
                splash?.ready()
                if requestedPlay { play() }
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                preparation = nil; deadline?.cancel(); deadline = nil
                failed = true
                recoveryAvailable = error is GameLoader.LoadError
                splash?.failed(canRecover: recoveryAvailable)
            }
        }
        deadline = Task { [weak self] in
            let timeout = 15.0
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, game == nil, generation == current else { return }
            cancelPreparation(); failed = true; splash?.failed()
        }
    }
    func cancelPreparation() {
        generation += 1
        preparation?.cancel(); preparation = nil
        deadline?.cancel(); deadline = nil
    }
    private func play() {
        if failed { prepare(startFresh: recoveryAvailable); return }
        guard let game else { requestedPlay = true; splash?.preparing(requestedPlay: true); return }
        splash?.removeFromSuperview(); splash = nil
        game.beginPlaying()
        UIAccessibility.post(notification: .screenChanged, argument: game.view)
    }
}
