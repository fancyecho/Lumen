import Foundation
import JavaScriptCore

/// Runs a scene's SceneScript (Wallpaper Engine's JavaScript for layer properties: clocks,
/// day/night switches, animated positions) in one JavaScriptCore context.
///
/// Each script is an ES module; it's rewritten into a function scope so its top-level names
/// stay private, and its exported `init`/`update`/`applyUserProperties` are kept. Layers are
/// plain JS objects; after every frame the runtime collects the ones scripts touched and
/// hands their properties back in a single call.
final class SceneScriptRuntime: @unchecked Sendable {
    struct LayerInfo {
        let id: Int
        let name: String
        let parent: Int?
        let origin: SIMD3<Float>
        let scale: SIMD3<Float>
        let angles: SIMD3<Float>
        let alpha: Float
        let visible: Bool
        let color: SIMD3<Float>
        let text: String?
        let size: SIMD2<Float>?
    }

    /// What scripts changed on a layer this frame.
    struct Change {
        var origin: SIMD3<Float>
        var scale: SIMD3<Float>
        var angles: SIMD3<Float>
        var alpha: Float
        var visible: Bool
        var color: SIMD3<Float>
        var text: String?
    }

    private let context: JSContext
    private var hasScripts = false
    private(set) var cursorLayerIDs: Set<Int> = []
    private var failed = false
    private let lock = NSLock()

    init?(layers: [LayerInfo], canvas: SIMD2<Float>, userProperties: [String: PropertyValue], storageKey: String) {
        guard let context = JSContext() else { return nil }
        self.context = context
        context.exceptionHandler = { _, exception in
            #if DEBUG
            if let message = exception?.toString() { Log.engine.debug("SceneScript: \(message, privacy: .public)") }
            #endif
        }
        context.evaluateScript(Self.prelude)
        var properties: [String: Any] = [:]
        for (key, value) in userProperties {
            switch value {
            case .bool(let flag): properties[key] = flag
            case .number(let number): properties[key] = number
            case .string(let string): properties[key] = Self.scriptValue(forUserString: string)
            }
        }
        let layerList: [[String: Any]] = layers.map { layer in
            var entry: [String: Any] = [
                "id": layer.id, "name": layer.name,
                "origin": [layer.origin.x, layer.origin.y, layer.origin.z],
                "scale": [layer.scale.x, layer.scale.y, layer.scale.z],
                "angles": [layer.angles.x, layer.angles.y, layer.angles.z],
                "alpha": layer.alpha, "visible": layer.visible,
                "color": [layer.color.x, layer.color.y, layer.color.z],
            ]
            if let parent = layer.parent { entry["parent"] = parent }
            if let text = layer.text { entry["text"] = text }
            if let size = layer.size { entry["size"] = [size.x, size.y] }
            return entry
        }
        let saved = UserDefaults.standard.dictionary(forKey: "sceneScriptStorage.\(storageKey)") ?? [:]
        context.objectForKeyedSubscript("__setup")?.call(withArguments: [layerList, [canvas.x, canvas.y], properties, saved])
        let storage: @convention(block) (JSValue) -> Void = { value in
            guard let dictionary = value.toDictionary() as? [String: Any] else { return }
            UserDefaults.standard.set(dictionary, forKey: "sceneScriptStorage.\(storageKey)")
        }
        context.setObject(storage, forKeyedSubscript: "__persistStorage" as NSString)
    }

    /// User colours are "r g b" strings; scripts expect them as such, numbers as numbers.
    private static func scriptValue(forUserString string: String) -> Any {
        if let number = Double(string) { return number }
        return string
    }

    /// Registers the script on `property` of layer `id`. `value` is the property's starting
    /// value; `scriptProperties` are the scene's values for the script's own settings.
    func addScript(layer id: Int, property: String, source: String, value: Any?, scriptProperties: [String: Any]) {
        let body = Self.moduleBody(source)
        let wrapper = """
        (function(thisLayer, thisObject) {
        \(body)
        ;return {
          update: typeof update === 'function' ? update : null,
          init: typeof init === 'function' ? init : null,
          applyUserProperties: typeof applyUserProperties === 'function' ? applyUserProperties : null,
          cursorClick: typeof cursorClick === 'function' ? cursorClick : null,
          cursorDown: typeof cursorDown === 'function' ? cursorDown : null,
          cursorUp: typeof cursorUp === 'function' ? cursorUp : null,
          cursorMove: typeof cursorMove === 'function' ? cursorMove : null,
          cursorEnter: typeof cursorEnter === 'function' ? cursorEnter : null,
          cursorLeave: typeof cursorLeave === 'function' ? cursorLeave : null
        };
        })
        """
        lock.lock()
        defer { lock.unlock() }
        guard let factory = context.evaluateScript(wrapper), !factory.isUndefined else { return }
        if context.objectForKeyedSubscript("__addScript")?
            .call(withArguments: [id, property, factory, value ?? NSNull(), scriptProperties])?.toBool() == true {
            cursorLayerIDs.insert(id)
        }
        hasScripts = true
    }

    /// Calls `applyUserProperties` and `init` on every script.
    func start() {
        guard hasScripts else { return }
        lock.lock()
        context.objectForKeyedSubscript("__start")?.call(withArguments: [])
        wantsAudio = context.evaluateScript("__audioBuffers.length > 0")?.toBool() ?? false
        lock.unlock()
    }

    /// Whether a script called `engine.registerAudioBuffers` (so capture should run).
    private(set) var wantsAudio = false

    func applyUserProperties(_ changed: [String: PropertyValue]) {
        guard hasScripts else { return }
        var properties: [String: Any] = [:]
        for (key, value) in changed {
            switch value {
            case .bool(let flag): properties[key] = flag
            case .number(let number): properties[key] = number
            case .string(let string): properties[key] = Self.scriptValue(forUserString: string)
            }
        }
        lock.lock()
        context.objectForKeyedSubscript("__applyUserProperties")?.call(withArguments: [properties])
        lock.unlock()
    }

    /// Runs one frame of every script and returns the layers they changed, keyed by id.
    func update(time: Double, delta: Double, daytime: Double, cursor: SIMD2<Float>?, cursorDown: Bool,
                cursorScreen: SIMD2<Float>? = nil, cursorEvents: [SceneCursorEvent] = [],
                audio: AudioBands = .silent) -> [Int: Change] {
        guard hasScripts, !failed else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        let cursorArgument: Any = cursor.map { [$0.x, $0.y] as Any } ?? NSNull()
        let audioArgument: Any = wantsAudio ? (audio.left + audio.right) as Any : NSNull()
        let screenArgument: Any = cursorScreen.map { [$0.x, $0.y] as Any } ?? NSNull()
        let eventArgument: Any = cursorEvents.isEmpty ? NSNull() : cursorEvents.map { event -> [Any] in
            [event.kind.rawValue, event.layerID, event.world.x, event.world.y, event.local.x, event.local.y,
             event.screen.x, event.screen.y, event.isDown]
        }
        guard let result = context.objectForKeyedSubscript("__frame")?
            .call(withArguments: [time, delta, daytime, cursorArgument, cursorDown, screenArgument, eventArgument, audioArgument]),
              let text = result.toString(), let data = text.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
        else { return [:] }
        var changes: [Int: Change] = [:]
        for entry in entries where entry.count >= 13 {
            func number(_ index: Int) -> Float { (entry[index] as? NSNumber)?.floatValue ?? 0 }
            guard let id = (entry[0] as? NSNumber)?.intValue else { continue }
            changes[id] = Change(
                origin: SIMD3(number(1), number(2), number(3)),
                scale: SIMD3(number(4), number(5), number(6)),
                angles: SIMD3(number(7), number(8), number(9)),
                alpha: number(10),
                visible: (entry[11] as? NSNumber)?.boolValue ?? true,
                color: SIMD3(number(12), entry.count > 13 ? number(13) : 1, entry.count > 14 ? number(14) : 1),
                text: entry.count > 15 ? entry[15] as? String : nil
            )
        }
        return changes
    }

    /// Strips `import` lines and `export` keywords so the module runs inside a function.
    static func moduleBody(_ source: String) -> String {
        var lines: [String] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import ") { continue }
            lines.append(line)
        }
        var text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: "export default ", with: "")
        text = text.replacing(/\bexport\s+(?=(?:async\s+)?function\b|var\b|let\b|const\b|class\b)/) { _ in "" }
        return text
    }

    // MARK: Prelude

    static let prelude = #"""
    'use strict';
    var console = { log: function () {}, warn: function () {}, error: function () {}, info: function () {} };

    class Vec2 {
      constructor(x, y) { if (typeof x === 'object' && x) { this.x = +x.x || 0; this.y = +x.y || 0; } else { this.x = x === undefined ? 0 : +x; this.y = y === undefined ? this.x : +y; } }
      copy() { return new Vec2(this.x, this.y); }
      add(v) { return typeof v === 'number' ? new Vec2(this.x + v, this.y + v) : new Vec2(this.x + v.x, this.y + v.y); }
      subtract(v) { return typeof v === 'number' ? new Vec2(this.x - v, this.y - v) : new Vec2(this.x - v.x, this.y - v.y); }
      multiply(v) { return typeof v === 'number' ? new Vec2(this.x * v, this.y * v) : new Vec2(this.x * v.x, this.y * v.y); }
      divide(v) { return typeof v === 'number' ? new Vec2(this.x / v, this.y / v) : new Vec2(this.x / v.x, this.y / v.y); }
      length() { return Math.sqrt(this.x * this.x + this.y * this.y); }
      lengthSqr() { return this.x * this.x + this.y * this.y; }
      normalize() { var l = this.length() || 1; return new Vec2(this.x / l, this.y / l); }
      dot(v) { return this.x * v.x + this.y * v.y; }
      mix(v, t) { return new Vec2(this.x + (v.x - this.x) * t, this.y + (v.y - this.y) * t); }
      perpendicular() { return new Vec2(-this.y, this.x); }
      reflect(n) { var d = 2 * this.dot(n); return new Vec2(this.x - d * n.x, this.y - d * n.y); }
      equals(v) { return this.x === v.x && this.y === v.y; }
      toString() { return this.x + ' ' + this.y; }
    }
    class Vec3 {
      constructor(x, y, z) {
        if (typeof x === 'string') { var p = x.split(' ').map(Number); this.x = p[0] || 0; this.y = p[1] || 0; this.z = p[2] || 0; return; }
        if (typeof x === 'object' && x) { this.x = +x.x || 0; this.y = +x.y || 0; this.z = +(x.z || 0); return; }
        this.x = x === undefined ? 0 : +x; this.y = y === undefined ? this.x : +y; this.z = z === undefined ? (y === undefined ? this.x : 0) : +z;
      }
      copy() { return new Vec3(this.x, this.y, this.z); }
      add(v) { return typeof v === 'number' ? new Vec3(this.x + v, this.y + v, this.z + v) : new Vec3(this.x + v.x, this.y + v.y, this.z + (v.z || 0)); }
      subtract(v) { return typeof v === 'number' ? new Vec3(this.x - v, this.y - v, this.z - v) : new Vec3(this.x - v.x, this.y - v.y, this.z - (v.z || 0)); }
      multiply(v) { return typeof v === 'number' ? new Vec3(this.x * v, this.y * v, this.z * v) : new Vec3(this.x * v.x, this.y * v.y, this.z * (v.z === undefined ? 1 : v.z)); }
      divide(v) { return typeof v === 'number' ? new Vec3(this.x / v, this.y / v, this.z / v) : new Vec3(this.x / v.x, this.y / v.y, this.z / (v.z || 1)); }
      length() { return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z); }
      lengthSqr() { return this.x * this.x + this.y * this.y + this.z * this.z; }
      normalize() { var l = this.length() || 1; return new Vec3(this.x / l, this.y / l, this.z / l); }
      dot(v) { return this.x * v.x + this.y * v.y + this.z * v.z; }
      cross(v) { return new Vec3(this.y * v.z - this.z * v.y, this.z * v.x - this.x * v.z, this.x * v.y - this.y * v.x); }
      mix(v, t) { return new Vec3(this.x + (v.x - this.x) * t, this.y + (v.y - this.y) * t, this.z + (v.z - this.z) * t); }
      equals(v) { return this.x === v.x && this.y === v.y && this.z === v.z; }
      toString() { return this.x + ' ' + this.y + ' ' + this.z; }
    }
    class Vec4 { constructor(x, y, z, w) { this.x = +x || 0; this.y = +y || 0; this.z = +z || 0; this.w = w === undefined ? 1 : +w; } copy() { return new Vec4(this.x, this.y, this.z, this.w); } toString() { return this.x + ' ' + this.y + ' ' + this.z + ' ' + this.w; } }

    var WEMath = {
      PI: Math.PI, TAU: Math.PI * 2, deg2rad: Math.PI / 180, rad2deg: 180 / Math.PI,
      lerp: function (a, b, t) { return a + (b - a) * t; }, mix: function (a, b, t) { return a + (b - a) * t; },
      clamp: function (v, a, b) { return Math.min(Math.max(v, a), b); },
      smoothStep: function (a, b, x) { var t = Math.min(Math.max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t); },
      fract: function (x) { return x - Math.floor(x); }, sign: Math.sign,
      angleVector2: function (a) { return new Vec2(Math.cos(a), Math.sin(a)); },
      vectorAngle2: function (v) { return Math.atan2(v.y, v.x); }
    };
    var WEVector = {
      angleVector2: function (a) { return new Vec2(Math.cos(a * Math.PI / 180), Math.sin(a * Math.PI / 180)); },
      vectorAngle2: function (v) { return Math.atan2(v.y, v.x) * 180 / Math.PI; }
    };
    var WEColor = {
      rgb2hsv: function (c) { var r = c.x, g = c.y, b = c.z, max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min, h = 0;
        if (d) { if (max === r) h = ((g - b) / d) % 6; else if (max === g) h = (b - r) / d + 2; else h = (r - g) / d + 4; h /= 6; if (h < 0) h += 1; }
        return new Vec3(h, max ? d / max : 0, max); },
      hsv2rgb: function (c) { var h = c.x * 6, s = c.y, v = c.z, i = Math.floor(h), f = h - i, p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
        var m = [[v, t, p], [q, v, p], [p, v, t], [p, q, v], [t, p, v], [v, p, q]][((i % 6) + 6) % 6]; return new Vec3(m[0], m[1], m[2]); },
      normalizeColor: function (c) { return new Vec3(c.x / 255, c.y / 255, c.z / 255); },
      expandColor: function (c) { return new Vec3(c.x * 255, c.y * 255, c.z * 255); }
    };
    var MediaPlaybackEvent = { PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 };
    var AnimationEvent = {};

    var __pendingScriptProperties = {};
    function createScriptProperties() {
      var values = {};
      var builder = {};
      function add(def) { if (def && def.name) values[def.name] = def.name in __pendingScriptProperties ? __pendingScriptProperties[def.name] : def.value; return builder; }
      ['addCheckbox', 'addSlider', 'addText', 'addCombo', 'addColor', 'addFile', 'addDirectory', 'addTextInput'].forEach(function (n) { builder[n] = add; });
      builder.finish = function () { return values; };
      return builder;
    }

    var shared = {};
    var __storage = {};
    var localStorage = {
      LOCATION_GLOBAL: 0, LOCATION_SCREEN: 1,
      get: function (k) { return __storage[k]; },
      set: function (k, v) { __storage[k] = v; if (typeof __persistStorage === 'function') __persistStorage(__storage); },
      delete: function (k) { delete __storage[k]; if (typeof __persistStorage === 'function') __persistStorage(__storage); },
      clear: function () { __storage = {}; if (typeof __persistStorage === 'function') __persistStorage(__storage); }
    };

    var __layers = {}, __byName = {}, __order = [], __scripts = [], __touched = {}, __canvas = new Vec2(1920, 1080);
    function __vec(a) { return a ? new Vec3(a[0], a[1], a[2]) : new Vec3(0, 0, 0); }
    function __makeLayer(d) {
      var layer = {
        id: d.id, name: d.name, origin: __vec(d.origin), scale: __vec(d.scale), angles: __vec(d.angles),
        alpha: d.alpha, visible: d.visible, color: __vec(d.color), text: d.text, size: d.size ? new Vec2(d.size[0], d.size[1]) : new Vec2(0, 0),
        font: '', pointsize: 0, horizontalalign: 'center', verticalalign: 'center', parallaxDepth: new Vec2(1, 1),
        __parent: d.parent, __lastText: d.text,
        getParent: function () { return this.__parent !== undefined ? (__layers[this.__parent] ? __touch(__layers[this.__parent]) : null) : null; },
        getTextureAnimation: function () { return { play: function () {}, pause: function () {}, stop: function () {}, setFrame: function () {}, getFrame: function () { return 0; }, isPlaying: function () { return true; }, frameCount: 1, rate: 1 }; },
        getAnimation: function () { return { play: function () {}, pause: function () {}, stop: function () {}, setFrame: function () {}, getFrame: function () { return 0; }, isPlaying: function () { return false; } }; },
        getEffect: function () { return { visible: true, getMaterial: function () { return { setValue: function () {} }; } }; },
        getChildren: function () { var me = this.id; return __order.filter(function (l) { return l.__parent === me; }).map(__touch); },
        play: function () {}, pause: function () {}, stop: function () {}, isPlaying: function () { return false; }
      };
      return layer;
    }
    function __touch(layer) { if (layer) __touched[layer.id] = layer; return layer; }

    var engine = {
      frametime: 0, runtime: 0, timeOfDay: 0, canvasSize: new Vec2(1920, 1080), screenResolution: new Vec2(1920, 1080),
      userProperties: {}, AUDIO_RESOLUTION_16: 16, AUDIO_RESOLUTION_32: 32, AUDIO_RESOLUTION_64: 64,
      isDesktopDevice: function () { return true; }, isWallpaper: function () { return true; }, isScreensaver: function () { return false; },
      isRunningInEditor: function () { return false; }, isMobileDevice: function () { return false; },
      registerAudioBuffers: function (n) {
        n = n === 32 || n === 64 ? n : 16;
        var b = { left: new Float32Array(n), right: new Float32Array(n), average: new Float32Array(n), resolution: n };
        __audioBuffers.push(b);
        return b;
      },
      registerAsset: function () { return {}; }, openUserShortcut: function () {}, setTimeout: function () {}, getScreenResolution: function () { return this.screenResolution; }
    };
    var input = { cursorWorldPosition: new Vec3(0, 0, 0), cursorScreenPosition: new Vec2(0, 0), cursorLeftDown: false };
    var thisScene = {
      getLayer: function (key) { return __touch(typeof key === 'number' ? __order[key] : __byName[key]) || null; },
      getLayerCount: function () { return __order.length; },
      enumerateLayers: function () { return __order.map(__touch); },
      getLayerIndex: function (layer) { return __order.indexOf(layer); },
      sortLayer: function () {}, createLayer: function () { return __makeLayer({ id: -1, name: '', visible: false, alpha: 0 }); }, destroyLayer: function () {},
      getCameraTransforms: function () { return { eye: new Vec3(__canvas.x / 2, __canvas.y / 2, 1000), center: new Vec3(__canvas.x / 2, __canvas.y / 2, 0), up: new Vec3(0, 1, 0) }; },
      clearColor: new Vec3(0, 0, 0), bloom: false
    };

    function __setup(layers, canvas, props, storage) {
      __canvas = new Vec2(canvas[0], canvas[1]);
      engine.canvasSize = __canvas.copy(); engine.screenResolution = __canvas.copy();
      engine.userProperties = props || {};
      __storage = storage || {};
      layers.forEach(function (d) { var l = __makeLayer(d); __layers[d.id] = l; if (!(d.name in __byName)) __byName[d.name] = l; __order.push(l); });
    }

    function __convertIn(property, value) {
      if (property === 'origin' || property === 'scale' || property === 'angles' || property === 'color') return value instanceof Vec3 ? value : new Vec3(String(value));
      return value;
    }

    var __cursorScripts = {};
    var __cursorHandlers = ['cursorEnter', 'cursorLeave', 'cursorMove', 'cursorDown', 'cursorUp', 'cursorClick'];

    function __addScript(id, property, factory, value, scriptProperties) {
      var layer = __layers[id];
      if (!layer) return;
      __pendingScriptProperties = scriptProperties || {};
      var hasCursorHandlers = false;
      try {
        var api = factory(layer, layer);
        var script = { layer: layer, property: property, api: api, value: __convertIn(property, value), errors: 0 };
        __scripts.push(script);
        hasCursorHandlers = __cursorHandlers.some(function (name) { return typeof api[name] === 'function'; });
        if (hasCursorHandlers) (__cursorScripts[id] || (__cursorScripts[id] = [])).push(script);
        __touch(layer);
      } catch (e) {}
      __pendingScriptProperties = {};
      return hasCursorHandlers;
    }

    function __assign(s, value) {
      if (value === undefined) return;
      s.value = value;
      var p = s.property;
      if (p === 'origin' || p === 'scale' || p === 'angles' || p === 'color') { if (value && typeof value === 'object') s.layer[p] = new Vec3(value); }
      else if (p === 'alpha') s.layer.alpha = +value;
      else if (p === 'visible') s.layer.visible = !!value;
      else if (p === 'text') s.layer.text = String(value);
    }

    function __call(s, name, arg) {
      if (!s.api || typeof s.api[name] !== 'function' || s.errors > 20) return undefined;
      try { return s.api[name](arg); } catch (e) { s.errors++; return undefined; }
    }

    function __start() {
      __scripts.forEach(function (s) { __call(s, 'applyUserProperties', engine.userProperties); });
      __scripts.forEach(function (s) { var v = __call(s, 'init', s.value); if (v !== undefined) __assign(s, v); });
    }

    function __applyUserProperties(changed) {
      for (var k in changed) engine.userProperties[k] = changed[k];
      __scripts.forEach(function (s) { __call(s, 'applyUserProperties', changed); });
    }

    var __audioBuffers = [];
    // `bands` holds 64 left values then 64 right values; each buffer gets its own resolution.
    function __audio(bands) {
      for (var i = 0; i < __audioBuffers.length; i++) {
        var b = __audioBuffers[i], group = 64 / b.resolution;
        for (var j = 0; j < b.resolution; j++) {
          var l = 0, r = 0;
          for (var k = 0; k < group; k++) { l += bands[j * group + k]; r += bands[64 + j * group + k]; }
          b.left[j] = l / group; b.right[j] = r / group; b.average[j] = (l + r) / (2 * group);
        }
      }
    }

    function __dispatchCursorEvents(events) {
      for (var i = 0; i < events.length; i++) {
        var e = events[i], scripts = __cursorScripts[e[1]];
        if (!scripts) continue;
        input.cursorWorldPosition = new Vec3(e[2], e[3], 0);
        input.cursorScreenPosition = new Vec2(e[6], e[7]);
        input.cursorLeftDown = e[8];
        for (var j = 0; j < scripts.length; j++) {
          __call(scripts[j], e[0], { worldPosition: new Vec3(e[2], e[3], 0), localPosition: new Vec3(e[4], e[5], 0) });
        }
      }
    }

    function __frame(time, delta, daytime, cursor, down, screen, cursorEvents, audio) {
      if (audio) __audio(audio);
      engine.runtime = time; engine.frametime = delta; engine.timeOfDay = daytime;
      if (cursorEvents) __dispatchCursorEvents(cursorEvents);
      if (cursor) input.cursorWorldPosition = new Vec3(cursor[0], cursor[1], 0);
      if (screen) input.cursorScreenPosition = new Vec2(screen[0], screen[1]);
      else if (cursor) input.cursorScreenPosition = new Vec2(cursor[0] / __canvas.x, 1 - cursor[1] / __canvas.y);
      input.cursorLeftDown = !!down;
      for (var i = 0; i < __scripts.length; i++) {
        var s = __scripts[i];
        var v = __call(s, 'update', s.value);
        if (v !== undefined) __assign(s, v);
      }
      var out = [];
      for (var id in __touched) {
        var l = __touched[id];
        var o = l.origin || new Vec3(), sc = l.scale || new Vec3(1, 1, 1), a = l.angles || new Vec3(), c = l.color || new Vec3(1, 1, 1);
        var entry = [l.id, +o.x || 0, +o.y || 0, +o.z || 0, +sc.x, +sc.y, +sc.z, +a.x || 0, +a.y || 0, +a.z || 0, +l.alpha, !!l.visible, +c.x, +c.y, +c.z];
        if (l.text !== undefined && l.text !== null) entry.push(String(l.text));
        out.push(entry);
      }
      return JSON.stringify(out);
    }
    """#
}
