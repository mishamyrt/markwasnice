import AppKit

/// Sheet asking for the size of the table to insert.
@MainActor
enum InsertTableDialog {
    static func present(
        in window: NSWindow,
        onInsert: @escaping (_ rows: Int, _ columns: Int) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Adjust table size."
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")

        let accessory = TableSizeAccessoryView()
        alert.accessoryView = accessory
        // Must be assigned before beginSheetModal, otherwise the default
        // button steals the keyboard focus.
        alert.window.initialFirstResponder = accessory.initialFirstResponder

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                return
            }

            onInsert(accessory.rows, accessory.columns)
        }
    }
}

private final class TableSizeAccessoryView: NSView, NSTextFieldDelegate {
    private let rowsField = NSTextField()
    private let columnsField = NSTextField()
    private let rowsStepper = NSStepper()
    private let columnsStepper = NSStepper()

    var rows: Int {
        clamped(rowsField.integerValue)
    }

    var columns: Int {
        clamped(columnsField.integerValue)
    }

    var initialFirstResponder: NSView {
        rowsField
    }

    init() {
        super.init(frame: .zero)

        configure(
            field: rowsField, stepper: rowsStepper,
            value: MarkdownTableCommand.defaultRows
        )
        configure(
            field: columnsField, stepper: columnsStepper,
            value: MarkdownTableCommand.defaultColumns
        )
        rowsField.nextKeyView = columnsField
        columnsField.nextKeyView = rowsField

        let grid = NSGridView(views: [
            [rowsField, rowsStepper, NSTextField(labelWithString: "rows")],
            [columnsField, columnsStepper, NSTextField(labelWithString: "columns")],
        ])
        grid.rowSpacing = 8
        grid.yPlacement = .center
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        addSubview(grid)
        // NSAlert sizes the accessory view by its frame, not constraints.
        setFrameSize(grid.frame.size)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }

        stepper(for: field).integerValue = clamped(field.integerValue)
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        let field = sender == rowsStepper ? rowsField : columnsField
        field.integerValue = sender.integerValue
    }

    private func stepper(for field: NSTextField) -> NSStepper {
        field == rowsField ? rowsStepper : columnsStepper
    }

    private func configure(field: NSTextField, stepper: NSStepper, value: Int) {
        let formatter = NumberFormatter()
        formatter.minimum = MarkdownTableCommand.sizeRange.lowerBound as NSNumber
        formatter.maximum = MarkdownTableCommand.sizeRange.upperBound as NSNumber
        formatter.allowsFloats = false
        field.formatter = formatter
        field.integerValue = value
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 50).isActive = true

        stepper.minValue = Double(MarkdownTableCommand.sizeRange.lowerBound)
        stepper.maxValue = Double(MarkdownTableCommand.sizeRange.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = value
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
    }

    private func clamped(_ value: Int) -> Int {
        min(
            max(value, MarkdownTableCommand.sizeRange.lowerBound),
            MarkdownTableCommand.sizeRange.upperBound
        )
    }
}
