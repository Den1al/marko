import AppKit

/// The icons of a terminal prompt and the like are characters of Unicode's private use areas,
/// which mean what an icon font says they mean; "Nerd Fonts" are the usual ones. No font of the
/// system draws them, so the text system shows its last-resort box. Where a Nerd Font is
/// installed, the renderer sets those characters, and only those, in it. None is bundled.
enum IconFont {
    /// The private use areas: where a paragraph has none of these there is nothing to do.
    static let characters = CharacterSet(charactersIn: "\u{E000}"..."\u{F8FF}").union(CharacterSet(charactersIn: "\u{F0000}"..."\u{10FFFD}"))

    /// The installed font families with "Nerd Font" in their name, in order of name. They are
    /// looked up when the first such character is to be shown, and again when the set of
    /// installed fonts changes (`reload`). Tests set their own.
    static var families = installed() {
        didSet { (fonts, substituted) = ([:], [:]) }
    }

    /// The font made for each kind and size of font it stands in for.
    private static var fonts: [String: NSFont] = [:]
    /// Whether a character is set in an icon font, by the name of the font around it: the
    /// answer takes making a font for the character, and a prompt's icons come again on every line.
    private static var substituted: [String: Bool] = [:]

    private static func installed() -> [String] {
        (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).filter { $0.contains("Nerd Font") }.sorted()
    }

    /// A font was installed or removed.
    static func reload() { families = installed() }

    /// The font to set `character` in where the text around it is in `font`; nil when a font of
    /// the system draws it, or when no Nerd Font is installed. A character that the system
    /// itself finds in an installed Nerd Font is set in the app's choice of one all the same:
    /// MEASURED for U+F0001, the system takes a variant whose icons are wider than their room,
    /// and in code at a size that is not as wide as the code's characters.
    static func font(for character: String, inPlaceOf font: NSFont) -> NSFont? {
        guard !families.isEmpty else { return nil }
        let asked = font.fontName + character
        if substituted[asked] == nil {
            let drawing = CTFontCreateForString(font, character as CFString, CFRange(location: 0, length: (character as NSString).length))
            substituted[asked] = CTFontCopyPostScriptName(drawing) as String == "LastResort" || families.contains(CTFontCopyFamilyName(drawing) as String)
        }
        guard substituted[asked] == true else { return nil }
        let key = "\(font.isFixedPitch) \(font.pointSize)"
        if let known = fonts[key] { return known }
        let family = family(forCode: font.isFixedPitch)
        func made(size: CGFloat) -> NSFont? { NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: size) }
        guard var icons = made(size: font.pointSize) else { return nil }
        // As wide as the characters of the code beside it, so that the columns of a code block
        // hold; by a digit's width, since a font's widest character may be a double-width one.
        func advance(_ font: NSFont) -> CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }
        if font.isFixedPitch, icons.isFixedPitch, advance(icons) > 0 {
            icons = made(size: font.pointSize * advance(font) / advance(icons)) ?? icons
        }
        fonts[key] = icons
        return icons
    }

    /// In code the variant whose icons are one character wide; in other text the one whose icons
    /// take the room they need. The plain variant's icons are wider than their room. Any, failing those.
    static func family(forCode isCode: Bool) -> String {
        let wanted = isCode ? ["Nerd Font Mono"] : ["Nerd Font Propo", "Nerd Font Mono"]
        return wanted.lazy.compactMap { suffix in families.first { $0.hasSuffix(suffix) } }.first ?? families[0]
    }
}
