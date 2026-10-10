//
//  AdditionalMetadataSource.swift
//  Subler
//

import Foundation

/// A user-configured additional metadata source: a display name, the
/// location of the service (its API base URL), and the personal API key
/// the user registered for with that provider.
public struct AdditionalMetadataSource: Codable, Equatable {
    public var name: String
    public var sourceLocation: String
    public var apiKey: String

    public init(name: String, sourceLocation: String, apiKey: String) {
        self.name = name
        self.sourceLocation = sourceLocation
        self.apiKey = apiKey
    }
}
