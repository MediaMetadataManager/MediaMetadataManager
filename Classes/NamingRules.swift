//
//  NamingRules.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/27/2026.
//
//  A small conditional naming-rule engine for the "Filename" preferences
//  tab's Movie template: an ordered list of NamingRule values, each a
//  (possibly empty) list of metadata conditions -- paired with its own
//  Token-based naming template (the exact same Token type/machinery
//  already used by MetadataPrefs.movieFormatTokens and
//  tvShowFormatTokens). Conditions on *different* fields are AND'd
//  together, e.g. "Rating is Explicit AND Studio is set"; consecutive
//  conditions on the *same* field are OR'd together instead, e.g. "TV
//  Show is Breaking Bad OR TV Show is Better Call Saul" -- a field can
//  only ever hold one value, so AND-ing two conditions on the same field
//  could never match anything (see NamingRule.matches(metadata:) for the
//  exact grouping). Rules are tried top to bottom; the first enabled rule
//  whose conditions all match the file's tagged metadata wins. The last
//  rule always has an empty condition list -- the "Default"/fallback
//  template used when nothing above it matched -- and the Preferences UI
//  (OutputPrefsViewController) never lets it be removed.
//
//  Each rule also carries its own isEnabled flag (OutputPrefsViewController
//  shows this as a checkbox in front of that rule's "Name:" line). This
//  replaced a single standalone "Set filename of Movies" checkbox that
//  used to gate the whole feature -- the Default rule's own checkbox is
//  what that used to be: turn it off and, when nothing else matches
//  either, a Movie file is left with its original filename.
//
//  This exists so a movie can get a different filename convention (e.g.
//  "Title [Studio] (Year)" for scene-style content vs. a plain "Title
//  (Year)" for everything else) driven entirely by *tagged metadata* the
//  Preferences UI lets the user configure -- rather than a hardcoded
//  Swift-side convention. See MP42File.formattedFileName() for where these
//  are actually evaluated.
//

import Foundation
import MP42Foundation

enum NamingConditionOperator: Int, Codable, CaseIterable {
    case equals
    case notEquals
    case contains
    case notContains
    case isSet
    case isNotSet

    var localizedName: String {
        switch self {
        case .equals: return NSLocalizedString("is", comment: "Naming rule condition operator")
        case .notEquals: return NSLocalizedString("is not", comment: "Naming rule condition operator")
        case .contains: return NSLocalizedString("contains", comment: "Naming rule condition operator")
        case .notContains: return NSLocalizedString("doesn't contain", comment: "Naming rule condition operator")
        case .isSet: return NSLocalizedString("is set", comment: "Naming rule condition operator")
        case .isNotSet: return NSLocalizedString("is not set", comment: "Naming rule condition operator")
        }
    }

    /// Whether this operator needs the condition's value field at all --
    /// "is set" / "is not set" only look at whether the field is tagged,
    /// so the Preferences UI hides the value field for those.
    var needsValue: Bool {
        switch self {
        case .isSet, .isNotSet: return false
        case .equals, .notEquals, .contains, .notContains: return true
        }
    }

    func matches(fieldValue: String?, against value: String) -> Bool {
        let field = (fieldValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .isSet:
            return field.isEmpty == false
        case .isNotSet:
            return field.isEmpty
        case .equals:
            return field.isEmpty == false && field.caseInsensitiveCompare(value) == .orderedSame
        case .notEquals:
            return field.caseInsensitiveCompare(value) != .orderedSame
        case .contains:
            return value.isEmpty == false && field.range(of: value, options: .caseInsensitive) != nil
        case .notContains:
            return value.isEmpty || field.range(of: value, options: .caseInsensitive) == nil
        }
    }
}

/// A single "if <field> <operator> <value>" test against a file's tagged
/// metadata -- see NamingRule. Consecutive conditions on the same field
/// are OR'd together, conditions on different fields are AND'd together
/// (see NamingRule.matches(metadata:)); an empty list (the Default rule)
/// is vacuously always true, but NamingRule.isDefault is what the
/// UI/engine actually key off of for that case, not an empty-conditions
/// match result.
struct NamingCondition: Codable {
    var field: String
    var op: NamingConditionOperator
    var value: String

    init(field: String = MP42MetadataKeyRating, op: NamingConditionOperator = .equals, value: String = "") {
        self.field = field
        self.op = op
        self.value = value
    }

    /// Fixed lists of values for fields that only take a few (the same
    /// labels the Metadata tab shows), used to fill a condition's value
    /// dropdown. Nil for fields without one.
    static func fixedValues(for field: String) -> [String]? {
        if field == MP42MetadataKeyMediaKind { return MovieViewController.mediaKinds.map { $0.title } }
        if field == MP42MetadataKeyContentRating { return MovieViewController.contentRatings.map { $0.title } }
        return nil
    }

    func matches(metadata: MP42Metadata) -> Bool {
        let item = metadata.metadataItemsFiltered(byIdentifier: field).first
        let comparableValue = NamingCondition.comparableValue(for: field, item: item)
        return op.matches(fieldValue: comparableValue, against: value)
    }

    /// Some writable metadata fields store a raw value that doesn't look
    /// like what a human would type into a naming condition's value
    /// field, so comparing against the item's raw stringValue would
    /// silently never match a real, tagged file:
    ///
    /// - Rating: once a real metadata provider has tagged the file,
    ///   this is a composite iTunes-style string ("mpaa|NC-17|500|" --
    ///   prefix|code|value|, matching the iTunEXTC atom -- see
    ///   Ratings.swift's Rating.iTunesCode and
    ///   PluginMetadataService.swift), not the plain rating name
    ///   ("NC-17") someone would naturally type. Extract just the
    ///   rating-name component (the second pipe-delimited segment).
    /// - Content Rating: stored as a plain Integer code (0/2/4 --
    ///   MP42MetadataKeyContentRating is MP42MetadataItemDataTypeInteger,
    ///   see MP42MetadataItem.m), not the label it's shown as
    ///   everywhere in this app's own UI ("None"/"Clean"/"Explicit" --
    ///   the Metadata tab's Content Rating popup, see
    ///   MovieViewController.contentRatings). Map the code back to that
    ///   same label so a condition like "Content Rating is Explicit"
    ///   -- the value someone would naturally copy from that same
    ///   popup -- actually matches.
    ///
    /// Without either of these, the affected condition could never
    /// match, and -- being AND'd with every other condition on the same
    /// rule (see NamingRule.matches(metadata:)) -- could take the whole
    /// rule down with it: the naming engine would silently fall through
    /// to the Default rule (or leave the file's name untouched
    /// entirely) no matter how many times the file was saved and
    /// re-tagged. Any other field's value passes through unchanged.
    private static func comparableValue(for field: String, item: MP42MetadataItem?) -> String? {
        if field == MP42MetadataKeyRating,
           let rawValue = item?.stringValue, rawValue.contains("|") {
            let components = rawValue.components(separatedBy: "|")
            return components.count > 1 ? components[1] : rawValue
        }
        if field == MP42MetadataKeyMediaKind, let code = item?.numberValue?.intValue {
            return MovieViewController.mediaKinds.first { $0.value == code }?.title ?? item?.stringValue
        }
        if field == MP42MetadataKeyContentRating, let code = item?.numberValue?.intValue {
            return MovieViewController.contentRatings.first { $0.value == code }?.title ?? item?.stringValue
        }
        return item?.stringValue
    }
}

/// One row of the Movie naming-rule list -- see this file's header comment.
struct NamingRule: Codable {
    /// Empty marks the fallback "Default" rule: always present, matches
    /// unconditionally. Every other rule has one or more conditions --
    /// grouped by field, with each field's group OR'd internally and the
    /// groups themselves AND'd together (see matches(metadata:)) -- and
    /// is tried before the Default rule.
    var conditions: [NamingCondition]
    var tokens: [Token]

    /// Whether this rule is considered at all when picking a filename.
    /// A disabled conditional rule is skipped as if it weren't in the
    /// list; a disabled Default rule means "leave the file's original
    /// name alone" when nothing else matched either -- this is what
    /// replaced the old standalone "Set filename of Movies" checkbox
    /// (see OutputPrefsViewController and matchingTokens(for:) below).
    var isEnabled: Bool

    var isDefault: Bool { conditions.isEmpty }

    init(conditions: [NamingCondition], tokens: [Token], isEnabled: Bool = true) {
        self.conditions = conditions
        self.tokens = tokens
        self.isEnabled = isEnabled
    }

    /// Conditions on different fields are AND'd together, but
    /// *consecutive* conditions on the same field are OR'd together
    /// first -- a field can only hold one value at a time, so two
    /// conditions on, say, TV Show would otherwise never both be true
    /// and the rule could never match. The Preferences UI's condition
    /// row reflects this: a condition's prefix reads "Or" instead of
    /// "And" exactly when it shares its field with the condition right
    /// above it, so what's on screen always matches how this groups.
    func matches(metadata: MP42Metadata) -> Bool {
        guard conditions.isEmpty == false else { return true }

        var index = 0
        while index < conditions.count {
            let field = conditions[index].field
            var groupMatched = false
            while index < conditions.count && conditions[index].field == field {
                if conditions[index].matches(metadata: metadata) {
                    groupMatched = true
                }
                index += 1
            }
            if groupMatched == false {
                return false
            }
        }
        return true
    }

    // MARK: Codable

    /// Reads both the current multi-condition shape and the original
    /// single-optional-`condition` shape saved by earlier versions of
    /// this app, so existing installs' saved rules keep working
    /// unchanged. `isEnabled` is similarly optional on read: it didn't
    /// exist before this per-rule checkbox replaced the old single
    /// global "Set filename of Movies" checkbox, so a missing value
    /// defaults to true -- the same effective state every rule already
    /// had under that old all-or-nothing switch.
    private enum CodingKeys: String, CodingKey {
        case conditions, condition, tokens, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let conditions = try container.decodeIfPresent([NamingCondition].self, forKey: .conditions) {
            self.conditions = conditions
        } else if let legacyCondition = try container.decodeIfPresent(NamingCondition.self, forKey: .condition) {
            self.conditions = [legacyCondition]
        } else {
            self.conditions = []
        }
        self.tokens = try container.decode([Token].self, forKey: .tokens)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conditions, forKey: .conditions)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}

extension Array where Element == NamingRule {
    /// The tokens of the first enabled rule whose conditions all match
    /// `metadata`, falling back to the Default rule's tokens -- or nil if
    /// the Default rule is disabled too (meaning: leave the file's
    /// existing name alone), or if this array somehow has no Default
    /// rule at all (shouldn't happen in practice since the Preferences UI
    /// never allows removing it, but a caller should still treat that as
    /// "nothing to use" rather than crash).
    func matchingTokens(for metadata: MP42Metadata) -> [Token]? {
        for rule in self where rule.isDefault == false && rule.isEnabled {
            if rule.matches(metadata: metadata) {
                return rule.tokens
            }
        }
        return first { $0.isDefault && $0.isEnabled }?.tokens
    }
}
