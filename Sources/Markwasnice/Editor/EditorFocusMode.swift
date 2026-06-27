enum EditorFocusMode: String, CaseIterable, Equatable {
    case focus
    case typewriter

    var title: String {
        switch self {
        case .focus:
            "Focus"
        case .typewriter:
            "Typewriter"
        }
    }
}
