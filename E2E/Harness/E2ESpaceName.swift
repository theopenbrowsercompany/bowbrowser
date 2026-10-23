import Foundation

/// A key `E2ESpaceNameApp.pressSheetKey(_:in:)` presses in a window's sheet.
enum E2ESheetKey: String {
    case returnKey = "Return"
    case escape = "Escape"

    /// The characters and macOS virtual key code (kVK_*) of the key.
    var event: (characters: String, keyCode: UInt16) {
        switch self {
        case .returnKey: ("\r", 36)
        case .escape: ("\u{1b}", 53)
        }
    }
}

/// The Space name above the Space's tabs as a person uses it: a double click on it, and the rename sheet it opens
/// typed into and answered from the keyboard. Its context menu is read through `E2ESpaceThemeApp.spaceMenuTitles`,
/// which builds it without showing it.
@MainActor
protocol E2ESpaceNameApp: E2ESpaceThemeApp {
    /// Double clicks the middle of the Space name in the sidebar of the window `page` is in: the first click and then
    /// the second (click count 2), each pressed and released, go to the view under that point. Throws when the
    /// sidebar shows no Space name or something else covers its middle.
    func doubleClickSpaceName(in page: any E2EPage) throws
    /// The text of the field in the sheet on the window `page` is in, and whether all of it is selected (as a field
    /// that typing replaces shows it); nil when no sheet with a field is up.
    func sheetField(in page: any E2EPage) throws -> (text: String, allSelected: Bool)?
    /// Types `text` into the field of the sheet on the window `page` is in, replacing its selection, the way text
    /// arrives from the keyboard; an empty `text` deletes the selection. Throws when no sheet with a field is up.
    func typeInSheet(_ text: String, in page: any E2EPage) throws
    /// Presses `key` in the sheet on the window `page` is in, as a key sheet routes it: a button whose key
    /// equivalent it is takes it (Escape's Cancel), and Return presses the sheet's default button. Throws when no sheet
    /// is up or nothing in it takes the key.
    func pressSheetKey(_ key: E2ESheetKey, in page: any E2EPage) throws
}
