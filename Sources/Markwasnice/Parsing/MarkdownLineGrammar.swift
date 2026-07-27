import Foundation

/// The token spellings of the markdown line-prefix grammar — bullets, ordered
/// markers, task checkboxes — in one place.
///
/// The regexes themselves stay in the files that own their behavior (they
/// differ in anchoring, capture groups and what they allow around the marker);
/// only the fragments live here, so widening the grammar — another bullet
/// character, another checkbox state — is a single edit instead of a sweep
/// across the styling, continuation, typography and title-suggestion paths,
/// which per-file unit tests would not catch drifting apart.
enum MarkdownLineGrammar {
    /// Characters that open an unordered list item.
    static let bulletCharacters = "-+*"

    /// Characters a task checkbox can carry between its brackets.
    static let checkboxStateCharacters = " xX"

    /// Separators an ordered list marker can use after its number.
    static let orderedMarkerSeparators = ".)"

    /// `[-+*]` — one bullet character.
    static let bullet = "[\(bulletCharacters)]"

    /// `\d+[.)]` — a number followed by its separator.
    static let orderedMarker = "\\d+[\(orderedMarkerSeparators)]"

    /// `(?:[-+*]|\d+[.)])` — either kind of list marker.
    static let listMarker = "(?:\(bullet)|\(orderedMarker))"

    /// `\[[ xX]\]` — a task checkbox in any state.
    static let checkbox = "\\[[\(checkboxStateCharacters)]\\]"

    /// The checkbox prefixes as plain literals, one per state, for the
    /// scanners that walk characters instead of running a regex.
    static let checkboxLiterals = checkboxStateCharacters.map { "[\($0)] " }
}
