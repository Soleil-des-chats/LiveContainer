//
//  DesktopShell.swift
//  LiveContainer
//
//  Desktop simulation: wallpaper + icons, taskbar (start button, window
//  buttons, clock), start menu. Forces every app to launch in a virtual window.
//

import UIKit
import SwiftUI
import Combine

// MARK: - State

@available(iOS 16.0, *)
final class DesktopState: ObservableObject {
    static let shared = DesktopState()
    @Published var now = Date()
    @Published var startOpen = false
    @Published var frontUUID: String? = nil
    @Published var hiddenUUIDs: Set<String> = []
    @Published var query = ""

    func refresh() {
        now = Date()
        let host = MultitaskDockManager.shared.windowHostingView
        var hidden = Set<String>()
        var front: String? = nil
        let apps = MultitaskDockManager.shared.apps
        for app in apps {
            if app.view?.isHidden ?? true { hidden.insert(app.appUUID) }
        }
        if let top = host.subviews.last(where: { !$0.isHidden }),
           let match = apps.first(where: { $0.view === top }) {
            front = match.appUUID
        }
        if hidden != hiddenUUIDs { hiddenUUIDs = hidden }
        if front != frontUUID { frontUUID = front }
    }
}

// MARK: - Shell manager

@available(iOS 16.0, *)
@objc public class DesktopShell: NSObject {
    @objc public static let shared = DesktopShell()
    static let barHeight: CGFloat = 48
    static let key = "LCDesktopMode"

    /// User setting.
    @objc public static var isEnabled: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: key)
    }
    /// Shell installed on screen right now.
    @objc public private(set) static var isActive = false

    /// Height of the taskbar including the home-indicator inset (0 when inactive).
    @objc public static var taskbarTotalHeight: CGFloat {
        guard isActive else { return 0 }
        return barHeight + (shared.window?.safeAreaInsets.bottom ?? 0)
    }
    /// Height that windows must keep clear (0 when inactive).
    @objc public static var reservedBottom: CGFloat { isActive ? barHeight : 0 }

    private var window: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }
    private var desktopHC: UIHostingController<DesktopView>?
    private var taskbarHC: UIHostingController<TaskbarView>?
    private var startHC: UIHostingController<StartMenuView>?
    private let scrim = UIView()
    private let snapPreview = UIView()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: lifecycle

    @objc public func activateIfNeeded() {
        guard DesktopShell.isEnabled, !DesktopShell.isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.activate() }
    }

    @objc public func activate() {
        guard !DesktopShell.isActive, let window = window,
              let rootView = window.rootViewController?.view else { return }
        // Desktop needs virtual windows
        LCUtils.appGroupUserDefault.set(MultitaskMode.virtualWindow.rawValue, forKey: "LCMultitaskMode")
        LCUtils.appGroupUserDefault.set(true, forKey: DesktopShell.key)
        DesktopShell.isActive = true

        let manager = MultitaskDockManager.shared // creates windowHostingView
        let host = manager.windowHostingView
        let hostParent = host.superview ?? rootView

        // Desktop (below app windows)
        let d = UIHostingController(rootView: DesktopView())
        d.view.backgroundColor = .clear
        d.view.frame = hostParent.bounds
        d.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostParent.insertSubview(d.view, belowSubview: host)
        rootView.window?.rootViewController?.addChild(d)
        desktopHC = d

        // Scrim + start menu
        scrim.frame = window.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.backgroundColor = .clear
        scrim.isHidden = true
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeStart)))
        window.addSubview(scrim)

        let s = UIHostingController(rootView: StartMenuView())
        s.view.backgroundColor = .clear
        scrim.addSubview(s.view)
        startHC = s

        // Taskbar
        let t = UIHostingController(rootView: TaskbarView())
        t.view.backgroundColor = .clear
        window.addSubview(t.view)
        taskbarHC = t

        snapPreview.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.25)
        snapPreview.layer.borderColor = UIColor.systemBlue.cgColor
        snapPreview.layer.borderWidth = 2
        snapPreview.layer.cornerRadius = 10
        snapPreview.isUserInteractionEnabled = false
        snapPreview.alpha = 0
        window.addSubview(snapPreview)

        layoutShell()
        NotificationCenter.default.addObserver(self, selector: #selector(layoutShell),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
        DesktopState.shared.$startOpen.receive(on: DispatchQueue.main).sink { [weak self] open in
            self?.setStart(open: open)
        }.store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DesktopState.shared.refresh()
            // keep shell above any freshly added guest windows
            if let w = self.window, let t = self.taskbarHC?.view {
                w.bringSubviewToFront(self.scrim)
                w.bringSubviewToFront(t)
            }
        }
        DesktopState.shared.refresh()
    }

    @objc public func deactivate() {
        guard DesktopShell.isActive else { return }
        DesktopShell.isActive = false
        LCUtils.appGroupUserDefault.set(false, forKey: DesktopShell.key)
        timer?.invalidate(); timer = nil
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
        [desktopHC?.view, taskbarHC?.view, startHC?.view, scrim, snapPreview].forEach { $0?.removeFromSuperview() }
        desktopHC?.removeFromParent()
        desktopHC = nil; taskbarHC = nil; startHC = nil
        DesktopState.shared.startOpen = false
    }

    @objc private func layoutShell() {
        DispatchQueue.main.async {
            guard let window = self.window else { return }
            let total = DesktopShell.taskbarTotalHeight
            let b = window.bounds
            self.taskbarHC?.view.frame = CGRect(x: 0, y: b.height - total, width: b.width, height: total)
            let w = min(360, b.width - 16)
            let h = min(520, b.height - total - window.safeAreaInsets.top - 16)
            self.startHC?.view.frame = CGRect(x: 8, y: b.height - total - h - 6, width: w, height: h)
            self.desktopHC?.view.frame = (self.desktopHC?.view.superview ?? window).bounds
        }
    }

    // MARK: start menu

    @objc func closeStart() { DesktopState.shared.startOpen = false }

    private func setStart(open: Bool) {
        guard let s = startHC?.view else { return }
        if open {
            DesktopState.shared.query = ""
            scrim.isHidden = false
            s.alpha = 0
            s.transform = CGAffineTransform(translationX: 0, y: 24)
            UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
                s.alpha = 1; s.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.16, animations: {
                s.alpha = 0; s.transform = CGAffineTransform(translationX: 0, y: 24)
            }, completion: { _ in
                if !DesktopState.shared.startOpen { self.scrim.isHidden = true }
            })
        }
    }

    // MARK: window helpers (called from DecoratedAppSceneViewController)

    /// Area windows may occupy.
    @objc public func usableFrame() -> CGRect {
        guard let w = window else { return .zero }
        var f = w.bounds.inset(by: w.safeAreaInsets)
        f.size.height -= DesktopShell.barHeight
        return f
    }

    /// Cascade new windows and size them for a desktop.
    @objc public func placeNewWindow(_ view: UIView) {
        let area = usableFrame()
        let n = max(0, MultitaskDockManager.shared.apps.count - 1)
        let size = CGSize(width: min(area.width - 40, 440), height: min(area.height - 40, 620))
        let step: CGFloat = 32
        var x = area.minX + 20 + CGFloat(n % 8) * step
        var y = area.minY + 16 + CGFloat(n % 8) * step
        x = min(x, area.maxX - size.width)
        y = min(y, area.maxY - size.height)
        view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
        view.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Which snap zone (if any) the pointer is in. 0 none, 1 left, 2 right, 3 top(maximize)
    @objc(snapZoneAtPoint:) public func snapZone(at p: CGPoint) -> Int {
        guard let w = window else { return 0 }
        let b = w.bounds
        if p.y < w.safeAreaInsets.top + 18 { return 3 }
        if p.x < 18 { return 1 }
        if p.x > b.width - 18 { return 2 }
        return 0
    }

    @objc public func snapRect(zone: Int) -> CGRect {
        let a = usableFrame()
        switch zone {
        case 1: return CGRect(x: a.minX, y: a.minY, width: a.width / 2, height: a.height)
        case 2: return CGRect(x: a.midX, y: a.minY, width: a.width / 2, height: a.height)
        case 3: return a
        default: return .zero
        }
    }

    @objc public func showSnapPreview(zone: Int) {
        if zone == 0 { hideSnapPreview(); return }
        snapPreview.frame = snapRect(zone: zone).insetBy(dx: 4, dy: 4)
        UIView.animate(withDuration: 0.12) { self.snapPreview.alpha = 1 }
    }

    @objc public func hideSnapPreview() {
        UIView.animate(withDuration: 0.12) { self.snapPreview.alpha = 0 }
    }

    // MARK: actions

    func toggle(app: DockAppModel) {
        let state = DesktopState.shared
        state.startOpen = false
        let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController
        if state.hiddenUUIDs.contains(app.appUUID) {
            _ = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: app.appUUID)
        } else if state.frontUUID == app.appUUID {
            vc?.minimizeWindow()
        } else {
            _ = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: app.appUUID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { state.refresh() }
    }

    func close(app: DockAppModel) {
        (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?.closeWindow()
    }

    func showDesktop() {
        DesktopState.shared.startOpen = false
        MultitaskDockManager.shared.minimizeAllWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { DesktopState.shared.refresh() }
    }

    func closeAllWindows() {
        DesktopState.shared.startOpen = false
        MultitaskDockManager.shared.apps.forEach { close(app: $0) }
    }

    func launch(_ model: LCAppModel) {
        DesktopState.shared.startOpen = false
        Task { @MainActor in
            do { try await model.runApp(multitask: true) }
            catch {
                let a = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .cancel))
                self.window?.rootViewController?.present(a, animated: true)
            }
            DesktopState.shared.refresh()
        }
    }
}

// MARK: - Views

@available(iOS 16.0, *)
private func allApps() -> [LCAppModel] {
    DataManager.shared.model.apps.sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
}

@available(iOS 16.0, *)
struct AppIconTile: View {
    let model: LCAppModel
    var size: CGFloat = 52
    var body: some View {
        Image(uiImage: model.appInfo.iconIsDarkIcon(false) ?? UIImage())
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

@available(iOS 16.0, *)
struct DesktopView: View {
    @ObservedObject var state = DesktopState.shared
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.05, green: 0.18, blue: 0.45),
                                        Color(red: 0.13, green: 0.45, blue: 0.80),
                                        Color(red: 0.35, green: 0.70, blue: 0.95)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                    .ignoresSafeArea()
                // wallpaper glow
                Circle().fill(Color.white.opacity(0.10)).frame(width: 420).blur(radius: 40)
                    .offset(x: geo.size.width * 0.35, y: geo.size.height * 0.15)

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 6, alignment: .top)],
                              alignment: .leading, spacing: 10) {
                        ForEach(allApps(), id: \.self) { app in
                            Button { DesktopShell.shared.launch(app) } label: {
                                VStack(spacing: 4) {
                                    AppIconTile(model: app)
                                    Text(app.displayName)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.7), radius: 2)
                                        .lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(width: 84)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, DesktopShell.taskbarTotalHeight + 12)
                }
                .padding(.top, geo.safeAreaInsets.top)
            }
            .contentShape(Rectangle())
            .onTapGesture { state.startOpen = false }
        }
    }
}

@available(iOS 16.0, *)
struct TaskbarView: View {
    @ObservedObject var dock = MultitaskDockManager.shared
    @ObservedObject var state = DesktopState.shared

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { withAnimation { state.startOpen.toggle() } } label: {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(state.startOpen ? .white : .accentColor)
                        .frame(width: 42, height: 38)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(state.startOpen ? Color.accentColor : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: 26)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(dock.apps) { app in
                            TaskButton(app: app, state: state)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button { DesktopShell.shared.showDesktop() } label: {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Self.timeFmt.string(from: state.now))
                            .font(.system(size: 13, weight: .semibold))
                        Text(Self.dateFmt.string(from: state.now))
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: DesktopShell.barHeight)
            Spacer(minLength: 0)
        }
        .background(.ultraThinMaterial)
        .overlay(Rectangle().fill(Color.white.opacity(0.15)).frame(height: 0.5), alignment: .top)
    }
}

@available(iOS 16.0, *)
struct TaskButton: View {
    let app: DockAppModel
    @ObservedObject var state: DesktopState

    var body: some View {
        let isFront = state.frontUUID == app.appUUID
        let isMin = state.hiddenUUIDs.contains(app.appUUID)
        Button { DesktopShell.shared.toggle(app: app) } label: {
            HStack(spacing: 6) {
                if let info = app.appInfo {
                    Image(uiImage: info.iconIsDarkIcon(false) ?? UIImage())
                        .resizable().frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                } else {
                    Image(systemName: "app.fill").frame(width: 24, height: 24)
                }
                Text(app.appName)
                    .font(.system(size: 12, weight: isFront ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 90, alignment: .leading)
            }
            .opacity(isMin ? 0.55 : 1)
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isFront ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.06)))
            .overlay(alignment: .bottom) {
                Capsule().fill(isFront ? Color.accentColor : Color.secondary.opacity(isMin ? 0.4 : 0.8))
                    .frame(width: isFront ? 22 : 8, height: 3).padding(.bottom, 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { DesktopShell.shared.toggle(app: app) } label: {
                Label(isMin ? "Restore" : (isFront ? "Minimize" : "Focus"), systemImage: "macwindow")
            }
            Button(role: .destructive) { DesktopShell.shared.close(app: app) } label: {
                Label("Close window", systemImage: "xmark")
            }
        }
    }
}

@available(iOS 16.0, *)
struct StartMenuView: View {
    @ObservedObject var state = DesktopState.shared
    @ObservedObject var dock = MultitaskDockManager.shared

    private var filtered: [LCAppModel] {
        let all = allApps()
        let q = state.query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search apps", text: $state.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))

            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6, alignment: .top)], spacing: 12) {
                    ForEach(filtered, id: \.self) { app in
                        Button { DesktopShell.shared.launch(app) } label: {
                            VStack(spacing: 4) {
                                AppIconTile(model: app, size: 50)
                                Text(app.displayName).font(.system(size: 11)).foregroundColor(.primary)
                                    .lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(.plain)
                    }
                }
                if filtered.isEmpty {
                    Text("No apps found").foregroundColor(.secondary).padding(.top, 30)
                }
            }

            Divider()
            HStack(spacing: 8) {
                Label("\(dock.apps.count) open", systemImage: "macwindow")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button { DesktopShell.shared.showDesktop() } label: { Image(systemName: "rectangle.on.rectangle.slash") }
                Button { DesktopShell.shared.closeAllWindows() } label: { Image(systemName: "xmark.square") }
                Menu {
                    Button { DesktopShell.shared.deactivate() } label: {
                        Label("Exit desktop", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: { Image(systemName: "power") }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }
}
