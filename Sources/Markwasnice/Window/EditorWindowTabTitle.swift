/// A native tab shows nothing but its window's title — isDocumentEdited only
/// dots the close button of the whole tab group, so an unsaved tab is
/// indistinguishable from a saved one. The marker the top bar draws next to the
/// title is therefore baked into the tab's own title.
enum EditorWindowTabTitle {
    static let editedMarker = "•"

    static func make(title: String, isEdited: Bool) -> String {
        isEdited ? "\(title) \(editedMarker)" : title
    }
}
