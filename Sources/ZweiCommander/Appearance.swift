import AppKit
import CommanderCore

struct AppearanceSettings: Codable, Equatable {
    var schemaVersion = 1
    var compact = true
    var fontSize = 0
    var toolbarLabels = true
    var importedColors = true
    static let fontSizes = [0, 10, 11, 12, 13, 14, 16]
    var rowHeight: CGFloat { max(compact ? 21 : 28, CGFloat(fontSize == 0 ? 12 : fontSize)+7) }
    func validate() throws {
        guard schemaVersion == 1,Self.fontSizes.contains(fontSize) else { throw CommanderError.message("Ungültige Listenschriftgröße.") }
    }
}

extension Preferences {
    static let appearanceKey = "ZweiCommander.appearance.v1"
    static var appearanceTestDefaults: UserDefaults?
    private static var cachedAppearance: (Data?,AppearanceSettings)?
    private static var appearanceDefaults: UserDefaults? { testMode ? appearanceTestDefaults : .standard }
    static func appearanceSettings() -> AppearanceSettings {
        let data = appearanceDefaults?.data(forKey:appearanceKey)
        if let cachedAppearance,cachedAppearance.0 == data { return cachedAppearance.1 }
        guard let data,
              let value = try? JSONDecoder().decode(AppearanceSettings.self,from:data),
              (try? value.validate()) != nil else { let fallback = AppearanceSettings();cachedAppearance = (data,fallback);return fallback }
        cachedAppearance = (data,value)
        return value
    }
    static func saveAppearance(_ value: AppearanceSettings) throws {
        try value.validate()
        if let old = appearanceDefaults?.object(forKey:appearanceKey) {
            guard let data = old as? Data,let decoded = try? JSONDecoder().decode(AppearanceSettings.self,from:data),
                  (try? decoded.validate()) != nil else { throw CommanderError.message("Die gespeicherte Darstellung ist nicht lesbar und wurde nicht ersetzt.") }
        }
        appearanceDefaults?.set(try JSONEncoder().encode(value),forKey:appearanceKey)
    }
}

struct CommanderPalette {
    let dark: Bool
    private func gray(_ value: Int) -> NSColor { NSColor(srgbRed:CGFloat(value)/255,green:CGFloat(value)/255,blue:CGFloat(value)/255,alpha:1) }
    static func current(in view: NSView) -> CommanderPalette { forAppearance(view.effectiveAppearance) }
    static func forAppearance(_ appearance: NSAppearance) -> CommanderPalette {
        CommanderPalette(dark:appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua)
    }
    var chrome: NSColor { gray(dark ? 76 : 237) }
    var toolbar: NSColor { gray(dark ? 79 : 244) }
    var activeList: NSColor { gray(dark ? 83 : 255) }
    var inactiveList: NSColor { gray(dark ? 61 : 246) }
    var text: NSColor { gray(dark ? 245 : 30) }
    var secondaryText: NSColor { gray(dark ? 211 : 83) }
    var separator: NSColor { gray(dark ? 113 : 191) }
    var hover: NSColor { gray(dark ? 96 : 222) }
    var accent: NSColor { NSColor(srgbRed:0.08,green:0.40,blue:0.73,alpha:1) }
    var activePath: NSColor { NSColor(srgbRed:dark ? 0.20 : 0.16,green:dark ? 0.47 : 0.43,blue:dark ? 0.72 : 0.71,alpha:1) }
    var activeTab: NSColor { gray(dark ? 109 : 216) }
    var inactiveSelection: NSColor { gray(dark ? 101 : 215) }
    var selectionText: NSColor { .white }
    func list(active: Bool,profile: SettingsProfile? = nil) -> NSColor {
        if Preferences.appearanceSettings().importedColors,let profile,profile.darkAppearance == dark,
           let imported = (active ? profile.background : profile.inactiveBackground) ?? profile.background {
            // A mislabeled imported scheme must not turn a light list dark, or vice versa.
            let color = imported.nsColor
            if (Self.luminance(color) < 0.30) == dark { return color }
        }
        return active ? activeList : inactiveList
    }
    func readable(_ candidate: NSColor?,on background: NSColor, fallback: NSColor? = nil) -> NSColor {
        let base = fallback ?? text
        let anchor: NSColor = Self.contrast(.black,background) >= Self.contrast(.white,background) ? .black : .white
        guard let candidate else { return Self.contrast(base,background) >= 4.5 ? base : anchor }
        if Self.contrast(candidate,background) >= 4.5 { return candidate }
        // Retain the hue of file-type colors while repairing their contrast.
        for step in 1...10 {
            if let adjusted = candidate.blended(withFraction:CGFloat(step)/10,of:anchor),Self.contrast(adjusted,background) >= 4.5 { return adjusted }
        }
        return anchor
    }
    static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4) }
        return 0.2126*linear(rgb.redComponent)+0.7152*linear(rgb.greenComponent)+0.0722*linear(rgb.blueComponent)
    }
    static func contrast(_ a: NSColor,_ b: NSColor) -> CGFloat {
        let x = luminance(a),y = luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05)
    }
}

class CommanderSurface: NSView {
    var toolbarSurface = false
    override init(frame: NSRect) { super.init(frame:frame);wantsLayer = false;updateSurface() }
    required init?(coder:NSCoder) { fatalError() }
    func updateSurface() { let p = CommanderPalette.current(in:self);layer?.backgroundColor = (toolbarSurface ? p.toolbar : p.chrome).cgColor }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { let p = CommanderPalette.current(in:self);(toolbarSurface ? p.toolbar : p.chrome).setFill();bounds.fill(using:.sourceOver) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateSurface();needsDisplay = true }
}

class CommanderTextView: NSTextView {
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateColors() }
    func updateColors() {
        let p = CommanderPalette.current(in:self)
        backgroundColor = p.activeList;textColor = p.text;insertionPointColor = p.text
        selectedTextAttributes = [.backgroundColor:p.accent,.foregroundColor:p.selectionText]
    }
}

class CommanderTableView: NSTableView {
    var workflowKeys: ((NSEvent)->Bool)?
    override func keyDown(with event: NSEvent) { if workflowKeys?(event) == true { return };super.keyDown(with:event) }
    override init(frame: NSRect) { super.init(frame:frame);headerView?.frame.size.height = 23;updateSurface() }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();updateSurface() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateSurface() }
    func updateSurface() {
        let p = CommanderPalette.current(in:self)
        backgroundColor = p.activeList;enclosingScrollView?.backgroundColor = backgroundColor;updateHeaderColors();needsDisplay = true
    }
    func updateHeaderColors() {
        let p = CommanderPalette.current(in:self)
        for column in tableColumns {
            if !(column.headerCell is CommanderHeaderCell) { column.headerCell = CommanderHeaderCell(textCell:column.title) }
            column.headerCell.attributedStringValue = NSAttributedString(string:column.title,attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:p.text])
        }
        headerView?.needsDisplay = true
    }
}
