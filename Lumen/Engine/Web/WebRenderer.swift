import AppKit
import WebKit

struct WebRenderSettings: Equatable {
    /// Caps `requestAnimationFrame`; 0 leaves the page at the display's rate.
    var frameRate: Int
    var muted: Bool
    var volume: Double
    /// Feed `wallpaperRegisterAudioListener` with the system audio spectrum.
    var audioReactive = false
}

/// Renderers that react to the pointer while it rests on the desktop.
@MainActor
protocol PointerAwareRenderer: AnyObject {
    /// Whether this wallpaper currently listens to pointer movement or clicks.
    var needsPointer: Bool { get }
    /// Called when `needsPointer` changes (after scene load or web listener registration).
    var onPointerNeedChange: (() -> Void)? { get set }
    /// `point` is in the renderer view's coordinates with a top-left origin; nil when the pointer left.
    func pointerMoved(to point: CGPoint?)
    func pointerPressed(_ isDown: Bool, at point: CGPoint)
}

/// Renderers whose content has Wallpaper Engine user properties.
@MainActor
protocol PropertyAwareRenderer: AnyObject {
    func update(values: [String: PropertyValue])
}

/// Plays an HTML wallpaper in a WKWebView, emulating Wallpaper Engine's web API.
@MainActor
final class WebRenderer: NSObject, WallpaperRenderer, PointerAwareRenderer, PropertyAwareRenderer {
    enum Source {
        case folder(URL, entry: String, id: UUID)
        case remote(URL, id: UUID)
    }

    var view: NSView { container }

    private let container = FlippedView()
    private let webView: WKWebView
    private let snapshotView = NSImageView()
    private let schemeHandler: LocalContentSchemeHandler?
    private let messageProxy = ScriptMessageProxy()
    private var properties: [WEProperty]
    private var values: [String: PropertyValue]
    private var settings: WebRenderSettings
    private var wantsActive = false
    private var isReady = false
    private var isTornDown = false
    private var readyHandlers: [@MainActor () -> Void] = []
    private var propertiesDelivered = false
    private var readyTimeout: Task<Void, Never>?
    private var snapshotGeneration = 0
    private var lastPointerSend: CFTimeInterval = 0
    /// The page last saw the pointer over it, so leaving must be reported.
    private var pointerInside = false
    /// The page registered a mouse or pointer listener.
    private var wantsPointer = false
    var needsPointer: Bool { wantsPointer }
    var onPointerNeedChange: (() -> Void)?
    /// The page registered an audio listener.
    private var wantsAudio = false
    private var audioTimer: Timer?

    init(source: Source, properties: [WEProperty], values: [String: PropertyValue], settings: WebRenderSettings) {
        self.properties = properties
        self.values = values
        self.settings = settings

        let configuration = WKWebViewConfiguration()
        let storeID: UUID
        switch source {
        case .folder(let root, _, let id):
            let handler = LocalContentSchemeHandler(root: root)
            configuration.setURLSchemeHandler(handler, forURLScheme: LocalContentSchemeHandler.scheme)
            schemeHandler = handler
            storeID = id
        case .remote(_, let id):
            schemeHandler = nil
            storeID = id
        }
        // Each wallpaper keeps its own cookies and localStorage, isolated from the others.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebBridgeScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController.add(messageProxy, name: "lumen")

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        messageProxy.target = self
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = .black
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.autoresizingMask = [.width, .height]
        snapshotView.isHidden = true
        container.addSubview(snapshotView)
        applyMute()

        switch source {
        case .folder(_, let entry, let id):
            if let url = LocalContentSchemeHandler.url(for: id, entry: entry) {
                webView.load(URLRequest(url: url))
            }
        case .remote(let url, _):
            webView.load(URLRequest(url: url))
        }

        // Pages that never paint (or block rAF) must not hold up the cross-fade forever.
        readyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.markReady()
        }
    }

    // MARK: WallpaperRenderer

    func setActive(_ active: Bool) {
        guard !isTornDown, active != wantsActive else { return }
        wantsActive = active
        updateAudioCapture()
        guard isReady else { return }
        active ? resume() : pause()
    }

    func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if isReady { handler() } else { readyHandlers.append(handler) }
    }

    /// Web pages lay themselves out for the whole screen, so position and zoom don't apply.
    func setFraming(_ framing: WallpaperFraming) {}

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        onPointerNeedChange = nil
        updateAudioCapture()
        readyTimeout?.cancel()
        readyHandlers.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lumen")
        // Unloading the page stops its audio and timers right away.
        webView.loadHTMLString("", baseURL: nil)
        container.removeFromSuperview()
    }

    // MARK: Live updates

    func update(settings newSettings: WebRenderSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        applyMute()
        updateAudioCapture()
        evaluate("window.__lumen && (__lumen.setFPS(\(newSettings.frameRate)), __lumen.setVolume(\(newSettings.muted ? 0 : newSettings.volume)))")
    }

    /// Sends changed user properties to the page, as Wallpaper Engine does when a slider moves.
    func update(values newValues: [String: PropertyValue]) {
        let changed = newValues.filter { values[$0.key] != $0.value }
        values = newValues
        guard !changed.isEmpty, propertiesDelivered else { return }
        evaluate("window.__lumen && __lumen.applyProperties(\(propertiesJSON(only: Set(changed.keys))))")
    }

    // MARK: PointerAwareRenderer

    func pointerMoved(to point: CGPoint?) {
        guard isReady, wantsActive else { return }
        guard let point else {
            // A browser reports the pointer leaving the window; pages rely on it to end hover
            // effects, and a press that began on the desktop never gets its mouseup otherwise,
            // leaving the page "held" (and animating) after the pointer moved onto a window.
            if pointerInside { evaluate("window.__lumen && __lumen.leave()") }
            pointerInside = false
            return
        }
        pointerInside = true
        // A desktop doesn't need more than ~60 pointer updates a second.
        let now = CACurrentMediaTime()
        guard now - lastPointerSend > 1.0 / 60 else { return }
        lastPointerSend = now
        evaluate("window.__lumen && __lumen.pointer('mousemove', \(point.x), \(point.y), 0)")
    }

    func pointerPressed(_ isDown: Bool, at point: CGPoint) {
        guard isReady, wantsActive else { return }
        pointerInside = true
        evaluate("window.__lumen && __lumen.pointer('\(isDown ? "mousedown" : "mouseup")', \(point.x), \(point.y), \(isDown ? 1 : 0))")
    }

    // MARK: Audio

    /// Captures system audio only while the page listens, plays and the setting allows it;
    /// Wallpaper Engine sends 64 left then 64 right bands about 30 times a second.
    private func updateAudioCapture() {
        let capture = wantsAudio && wantsActive && !isTornDown && settings.audioReactive
        guard capture != (audioTimer != nil) else { return }
        if capture {
            AudioSpectrumService.shared.retain(self)
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendAudio() }
            }
            RunLoop.main.add(timer, forMode: .common)
            audioTimer = timer
        } else {
            audioTimer?.invalidate()
            audioTimer = nil
            AudioSpectrumService.shared.release(self)
            evaluate("window.__lumen && __lumen.setAudio(null)")
        }
    }

    private func sendAudio() {
        let bands = AudioSpectrumService.shared.bands
        let values = (bands.left + bands.right).map { String(format: "%.3f", $0) }.joined(separator: ",")
        evaluate("window.__lumen && __lumen.setAudio([\(values)])")
    }

    // MARK: Page lifecycle

    fileprivate func pageLoaded() {
        let general = "{\"fps\":\(settings.frameRate)}"
        let script = """
        (function(){ if (!window.__lumen) return false;
          __lumen.setFPS(\(settings.frameRate)); __lumen.setVolume(\(settings.muted ? 0 : settings.volume));
          __lumen.applyGeneral(\(general));
          return __lumen.deliverProperties(\(propertiesJSON(only: nil)));
        })()
        """
        evaluate(script)
        propertiesDelivered = true
    }

    fileprivate func received(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            markReady()
        case "audio":
            wantsAudio = true
            updateAudioCapture()
        case "pointer":
            guard !wantsPointer else { return }
            wantsPointer = true
            onPointerNeedChange?()
        case "log":
            #if DEBUG
            Log.engine.debug("web: \(String(describing: message["text"] ?? ""), privacy: .public)")
            #endif
        default:
            break
        }
    }

    private func markReady() {
        guard !isTornDown, !isReady else { return }
        isReady = true
        readyTimeout?.cancel()
        if !wantsActive { pause() }
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    /// Freezes the page on its current picture: a snapshot covers it, the page stops animating
    /// (hidden web views get no animation frames) and media is suspended.
    private func pause() {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        evaluate("window.__lumen && __lumen.setPaused(true)")
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTornDown, generation == self.snapshotGeneration, !self.wantsActive else { return }
                if let image {
                    self.snapshotView.image = image
                    self.snapshotView.frame = self.container.bounds
                    self.snapshotView.isHidden = false
                }
                self.webView.isHidden = true
                self.webView.setAllMediaPlaybackSuspended(true)
            }
        }
    }

    private func resume() {
        snapshotGeneration += 1
        webView.isHidden = false
        webView.setAllMediaPlaybackSuspended(false)
        evaluate("window.__lumen && __lumen.setPaused(false)")
        // Keep the snapshot up until the page has drawn again.
        let generation = snapshotGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, generation == self.snapshotGeneration else { return }
            self.snapshotView.isHidden = true
            self.snapshotView.image = nil
        }
    }

    // MARK: Recording

    /// Keeps the page animating while its window is hidden or off-screen (for recording a
    /// Lock Screen loop); WebKit otherwise throttles occluded pages to a stop.
    func keepRenderingWhenOccluded() {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector), let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(webView, selector, false)
    }

    /// The page as currently drawn.
    func snapshot() async -> CGImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func applyMute() {
        // WebKit's page-level mute silences Web Audio too; fall back to the bridge's media volume.
        let selector = NSSelectorFromString("_setPageMuted:")
        if webView.responds(to: selector), let method = class_getInstanceMethod(WKWebView.self, selector) {
            typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
            let call = unsafeBitCast(method_getImplementation(method), to: SetMuted.self)
            call(webView, selector, settings.muted ? 1 : 0)
        }
    }

    private func evaluate(_ script: String) {
        guard !isTornDown else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// `{ "name": { "value": … }, … }` as Wallpaper Engine passes to `applyUserProperties`.
    private func propertiesJSON(only keys: Set<String>?) -> String {
        var parts: [String] = []
        for property in properties where keys?.contains(property.id) ?? true {
            let value = values[property.id] ?? property.defaultValue
            let key = PropertyValue.string(property.id).jsonLiteral
            parts.append("\(key):{\"type\":\(PropertyValue.string(property.kind.rawValue).jsonLiteral),\"value\":\(value.jsonLiteral)}")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

extension WebRenderer: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.engine.error("Web wallpaper failed: \(error.localizedDescription, privacy: .public)")
        markReady()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.engine.error("Web wallpaper didn't load: \(error.localizedDescription, privacy: .public)")
        markReady()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isTornDown else { return }
        Log.engine.info("Web wallpaper's content process ended; reloading")
        propertiesDelivered = false
        if wantsPointer {
            wantsPointer = false
            onPointerNeedChange?()
        }
        webView.reload()
    }

    /// The wallpaper may load what it likes, but it can't navigate the desktop away from itself.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame ?? false
        if isMainFrame, action.navigationType == .linkActivated {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// Breaks the retain cycle between the content controller and the renderer.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WebRenderer?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { target?.received(body) }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Injected before any page script: Wallpaper Engine's web API plus Lumen's controls.
enum WebBridgeScript {
    static let source = #"""
    (function () {
      if (window.__lumen) return;
      var post = function (m) { try { window.webkit.messageHandlers.lumen.postMessage(m); } catch (e) {} };
      var nativeRAF = window.requestAnimationFrame.bind(window);
      var callbacks = new Map(), nextID = 1, scheduled = false, last = 0;
      var state = { fps: 0, paused: false, volume: 1 };

      function pump(t) {
        scheduled = false;
        if (state.paused) return;
        if (state.fps > 0 && t - last < 1000 / state.fps - 1.5) { schedule(); return; }
        last = t;
        var run = Array.from(callbacks.values()); callbacks.clear();
        for (var i = 0; i < run.length; i++) {
          try { run[i](t); } catch (e) { setTimeout(function () { throw e; }); }
        }
      }
      function schedule() { if (!scheduled && callbacks.size) { scheduled = true; nativeRAF(pump); } }
      window.requestAnimationFrame = function (cb) { var id = nextID++; callbacks.set(id, cb); schedule(); return id; };
      window.cancelAnimationFrame = function (id) { callbacks.delete(id); };

      var audioListeners = [], audioTimer = null, silence = new Array(128).fill(0), audioFrame = silence;
      function feedAudio() {
        if (state.paused) return;
        for (var i = 0; i < audioListeners.length; i++) { try { audioListeners[i](audioFrame); } catch (e) {} }
      }
      window.wallpaperRegisterAudioListener = function (cb) {
        if (typeof cb !== 'function') return;
        audioListeners.push(cb);
        if (!audioTimer) { audioTimer = setInterval(feedAudio, 33); post({ type: 'audio' }); }
      };
      ['wallpaperRegisterMediaStatusListener', 'wallpaperRegisterMediaPropertiesListener',
       'wallpaperRegisterMediaThumbnailListener', 'wallpaperRegisterMediaPlaybackListener',
       'wallpaperRegisterMediaTimelineListener'].forEach(function (name) { window[name] = function () {}; });
      window.wallpaperRequestRandomFileForProperty = function () {};

      var nativePlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        try { this.volume = Math.min(this.volume, state.volume); } catch (e) {}
        return nativePlay.apply(this, arguments);
      };

      var pendingProperties = null;
      var last = null, held = false;
      function listener() { return window.wallpaperPropertyListener; }
      function deliver(props) {
        var l = listener();
        if (l && typeof l.applyUserProperties === 'function') {
          try { l.applyUserProperties(props); } catch (e) { console.error(e); }
          return true;
        }
        return false;
      }

      window.__lumen = {
        setFPS: function (n) { state.fps = n | 0; },
        setAudio: function (bands) { audioFrame = bands || silence; },
        setVolume: function (v) {
          state.volume = v;
          document.querySelectorAll('audio,video').forEach(function (m) { try { m.volume = v; } catch (e) {} });
        },
        setPaused: function (p) {
          state.paused = !!p;
          if (!state.paused) schedule();
          var l = listener();
          if (l && typeof l.setPaused === 'function') { try { l.setPaused(state.paused); } catch (e) {} }
        },
        applyGeneral: function (g) {
          var l = listener();
          if (l && typeof l.applyGeneralProperties === 'function') { try { l.applyGeneralProperties(g); } catch (e) {} }
        },
        applyProperties: function (props) { return deliver(props); },
        // Pages often define the listener in a script that runs after load; keep trying briefly.
        deliverProperties: function (props) {
          if (deliver(props)) return true;
          pendingProperties = props;
          var tries = 0;
          var timer = setInterval(function () {
            tries++;
            if (deliver(pendingProperties) || tries > 40) { clearInterval(timer); pendingProperties = null; }
          }, 50);
          return false;
        },
        pointer: function (type, x, y, buttons) {
          var target = document.elementFromPoint(x, y) || document.body || document.documentElement;
          if (!target) return;
          last = { x: x, y: y, target: target };
          if (type === 'mousedown') held = true; else if (type === 'mouseup') held = false;
          var init = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y,
                       screenX: x, screenY: y, buttons: buttons, button: 0 };
          var pointerType = { mousemove: 'pointermove', mousedown: 'pointerdown', mouseup: 'pointerup' }[type];
          if (pointerType && window.PointerEvent) {
            var pinit = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, init);
            target.dispatchEvent(new PointerEvent(pointerType, pinit));
          }
          target.dispatchEvent(new MouseEvent(type, init));
          if (type === 'mouseup') target.dispatchEvent(new MouseEvent('click', init));
        },
        // The pointer left the desktop: release a press still held, then report the exit.
        leave: function () {
          if (!last) return;
          var x = last.x, y = last.y, target = last.target.isConnected ? last.target : (document.body || document.documentElement);
          if (held) {
            held = false;
            var up = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, buttons: 0, button: 0 };
            if (window.PointerEvent) target.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, up)));
            target.dispatchEvent(new MouseEvent('mouseup', up));
          }
          var out = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, relatedTarget: null };
          if (window.PointerEvent) {
            var pout = Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, out);
            target.dispatchEvent(new PointerEvent('pointerout', pout));
            document.documentElement.dispatchEvent(new PointerEvent('pointerleave', Object.assign({}, pout, { bubbles: false })));
          }
          target.dispatchEvent(new MouseEvent('mouseout', out));
          document.documentElement.dispatchEvent(new MouseEvent('mouseleave', Object.assign({}, out, { bubbles: false })));
          last = null;
        }
      };

      var pointerReported = false;
      var pointerEvents = {
        mousemove: 1, mousedown: 1, mouseup: 1, click: 1,
        mouseover: 1, mouseenter: 1, mouseleave: 1, mouseout: 1,
        pointermove: 1, pointerdown: 1, pointerup: 1, pointerover: 1, pointerenter: 1
      };
      function reportPointer() {
        if (pointerReported) return;
        pointerReported = true;
        post({ type: 'pointer' });
      }
      var nativeAddEventListener = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = function (type) {
        if (typeof type === 'string' && pointerEvents[type.toLowerCase()]) reportPointer();
        return nativeAddEventListener.apply(this, arguments);
      };
      function scanInlinePointerHandlers() {
        if (pointerReported) return;
        var props = ['onmousemove', 'onmousedown', 'onmouseup', 'onclick', 'onpointermove', 'onpointerdown', 'onpointerup'];
        for (var i = 0; i < props.length; i++) {
          var p = props[i];
          if (typeof window[p] === 'function' || typeof document[p] === 'function' ||
              (document.body && typeof document.body[p] === 'function')) {
            reportPointer();
            return;
          }
        }
        if (document.querySelector('[onmousemove],[onmousedown],[onclick],[onpointermove]')) reportPointer();
      }

      function announceReady() {
        scanInlinePointerHandlers();
        setTimeout(scanInlinePointerHandlers, 500);
        nativeRAF(function () { nativeRAF(function () { post({ type: 'ready' }); }); });
      }
      if (document.readyState === 'complete') announceReady();
      else window.addEventListener('load', announceReady, { once: true });
    })();
    """#
}
