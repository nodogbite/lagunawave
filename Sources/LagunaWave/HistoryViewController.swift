import AppKit

@MainActor
final class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let previewText = NSTextView()
    private let previewScroll = NSScrollView()
    private let previewTitle = NSTextField(labelWithString: "Transcription")
    private let previewContainer = NSView()
    private let typeButton = NSButton(title: "Type", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var history: TranscriptionHistory { TranscriptionHistory.shared }

    override func loadView() {
        view = NSView()

        // --- Left pane: table list ---

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        tableView.backgroundColor = .textBackgroundColor

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = true

        // --- Right pane: preview + buttons ---

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.font = NSFont.systemFont(ofSize: 14)
        previewText.textContainerInset = NSSize(width: 14, height: 12)
        previewText.isVerticallyResizable = true
        previewText.isHorizontallyResizable = false
        previewText.autoresizingMask = [.width]
        previewText.textContainer?.widthTracksTextView = true
        previewText.drawsBackground = false
        previewText.backgroundColor = .clear

        previewScroll.documentView = previewText
        previewScroll.hasVerticalScroller = true
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.borderType = .noBorder
        previewScroll.drawsBackground = false

        previewTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        previewTitle.textColor = .secondaryLabelColor
        previewTitle.translatesAutoresizingMaskIntoConstraints = false

        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = 8
        previewContainer.layer?.borderWidth = 1
        previewContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        previewContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewScroll)

        NSLayoutConstraint.activate([
            previewScroll.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
        ])

        typeButton.target = self
        typeButton.action = #selector(typeSelected)
        typeButton.bezelStyle = .rounded

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        copyButton.bezelStyle = .rounded

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let buttonBar = NSStackView(views: [spacer, typeButton, copyButton, deleteButton])
        buttonBar.orientation = .horizontal
        buttonBar.alignment = .centerY
        buttonBar.spacing = 8
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(previewTitle)
        rightPane.addSubview(previewContainer)
        rightPane.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            previewTitle.topAnchor.constraint(equalTo: rightPane.topAnchor, constant: 10),
            previewTitle.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor, constant: 10),
            previewTitle.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor, constant: -10),

            previewContainer.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 8),
            previewContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor, constant: 10),
            previewContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor, constant: -10),

            buttonBar.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 10),
            buttonBar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor, constant: 10),
            buttonBar.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor, constant: -10),
            buttonBar.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor, constant: -10)
        ])

        // --- Divider ---

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        // --- Assemble ---

        view.addSubview(tableScroll)
        view.addSubview(divider)
        view.addSubview(rightPane)

        NSLayoutConstraint.activate([
            tableScroll.topAnchor.constraint(equalTo: view.topAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableScroll.widthAnchor.constraint(equalToConstant: 240),

            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            rightPane.topAnchor.constraint(equalTo: view.topAnchor),
            rightPane.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightPane.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rightPane.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        updateButtons()

        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: .historyDidChange, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadHistory()
    }

    @objc private func historyChanged() {
        reloadHistory()
    }

    private func reloadHistory() {
        tableView.reloadData()
        if !history.records.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updatePreview()
        updateButtons()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        history.records.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("HistoryCell")
        let record = history.records[row]

        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let dateLabel = NSTextField(labelWithString: "")
            dateLabel.font = NSFont.systemFont(ofSize: 10)
            dateLabel.textColor = .secondaryLabelColor
            dateLabel.tag = 1

            let textLabel = NSTextField(wrappingLabelWithString: "")
            textLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            textLabel.maximumNumberOfLines = 1
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.tag = 2

            let stack = NSStackView(views: [dateLabel, textLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -6)
            ])
        }

        if let dateLabel = cell.viewWithTag(1) as? NSTextField {
            dateLabel.stringValue = dateFormatter.string(from: record.date)
        }
        if let textLabel = cell.viewWithTag(2) as? NSTextField {
            let preview = record.text.replacingOccurrences(of: "\n", with: " ")
            textLabel.stringValue = preview
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
        updateButtons()
    }

    // MARK: - Actions

    @objc private func typeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, history.records.indices.contains(row) else { return }
        let text = history.records[row].text
        view.window?.close()
        NotificationCenter.default.post(name: .retypeTranscription, object: text)
    }

    @objc private func copySelected() {
        let row = tableView.selectedRow
        guard row >= 0, history.records.indices.contains(row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(history.records[row].text, forType: .string)
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0, history.records.indices.contains(row) else { return }
        history.delete(at: row)
        tableView.reloadData()
        if history.records.isEmpty {
            previewText.string = ""
        } else {
            let newRow = min(row, history.records.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        }
        updatePreview()
        updateButtons()
    }

    // MARK: - Private

    private func updatePreview() {
        let row = tableView.selectedRow
        if row >= 0, history.records.indices.contains(row) {
            previewText.string = history.records[row].text
        } else {
            previewText.string = history.records.isEmpty ? "No transcriptions yet." : ""
        }
    }

    private func updateButtons() {
        let hasSelection = tableView.selectedRow >= 0
        typeButton.isEnabled = hasSelection
        copyButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }
}
