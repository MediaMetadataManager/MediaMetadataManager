//
//  PluginSettingsViewController.swift
//  Subler
//
//  A small, generic "Configure…" popover for plugin-backed metadata
//  providers that need a manually-entered setting, such as an API key or
//  a server address. The app knows nothing about any particular plugin:
//  each plugin describes its own settings through the optional
//  M3MetadataPlugin.settingsFields() requirement, and this popover just
//  shows one field per entry and reads/writes the UserDefaults key that
//  entry names. A plugin that returns no fields gets no Configure button.

import Cocoa

/// One editable setting shown in a plugin's configuration popover.
struct PluginSettingField {
    let key: String
    let label: String
    let isSecure: Bool
    let placeholder: String
}

/// Builds the Configure popover's fields for an installed plugin by
/// asking the plugin itself (see M3MetadataPlugin.settingsFields()).
/// Keyed by the provider's pluginName exactly as
/// MetadataSearch.pluginMovieProviders reports it.
enum PluginSettings {

    /// Nil when the provider isn't an installed plugin, or when the plugin
    /// declares no settings -- in either case there is nothing to configure.
    static func fields(for providerName: String) -> [PluginSettingField]? {
        guard let plugin = MetadataSearch.plugin(named: providerName),
              let declared = plugin.settingsFields?(), declared.isEmpty == false else { return nil }

        let fields = declared.compactMap { entry -> PluginSettingField? in
            guard let key = entry["key"] as? String, key.isEmpty == false,
                  let label = entry["label"] as? String else { return nil }
            return PluginSettingField(key: key,
                                      label: label,
                                      isSecure: (entry["secure"] as? NSNumber)?.boolValue ?? false,
                                      placeholder: entry["placeholder"] as? String ?? "")
        }
        return fields.isEmpty ? nil : fields
    }
}

/// The popover's own content: one labeled text field per
/// PluginSettingField, pre-filled from UserDefaults, with Cancel/Save
/// buttons. Saving an emptied field removes the key entirely rather
/// than storing an empty string, so an optional setting falls back to
/// the plugin's own default exactly as if it had never been set.
final class PluginSettingsViewController: NSViewController {

    private let pluginName: String
    private let fields: [PluginSettingField]
    private var textFields: [NSTextField] = []

    init(pluginName: String, fields: [PluginSettingField]) {
        self.pluginName = pluginName
        self.fields = fields
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let width: CGFloat = 320

        let headerLabel = NSTextField(labelWithString: String(format: NSLocalizedString("Configure %@", comment: ""), pluginName))
        headerLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let fieldsStack = NSStackView()
        fieldsStack.orientation = .vertical
        fieldsStack.alignment = .leading
        fieldsStack.spacing = 12
        fieldsStack.translatesAutoresizingMaskIntoConstraints = false

        textFields = []
        for field in fields {
            let label = NSTextField(labelWithString: field.label)
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false

            let textField: NSTextField = field.isSecure ? NSSecureTextField() : NSTextField()
            textField.placeholderString = field.placeholder
            textField.stringValue = UserDefaults.standard.string(forKey: field.key) ?? ""
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.widthAnchor.constraint(equalToConstant: width - 40).isActive = true
            textFields.append(textField)

            let rowStack = NSStackView(views: [label, textField])
            rowStack.orientation = .vertical
            rowStack.alignment = .leading
            rowStack.spacing = 2
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            fieldsStack.addArrangedSubview(rowStack)
        }

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancel(_:)))
        let saveButton = NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"

        let buttonsStack = NSStackView(views: [cancelButton, saveButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 8
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()

        container.addSubview(headerLabel)
        container.addSubview(fieldsStack)
        container.addSubview(buttonsStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),

            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            fieldsStack.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 14),
            fieldsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            fieldsStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),

            buttonsStack.topAnchor.constraint(equalTo: fieldsStack.bottomAnchor, constant: 18),
            buttonsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttonsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])

        self.view = container
    }

    @objc private func cancel(_ sender: NSButton) {
        dismiss(sender)
    }

    @objc private func save(_ sender: NSButton) {
        let ud = UserDefaults.standard
        for (field, textField) in zip(fields, textFields) {
            let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                ud.removeObject(forKey: field.key)
            } else {
                ud.set(value, forKey: field.key)
            }
        }
        dismiss(sender)
    }
}
