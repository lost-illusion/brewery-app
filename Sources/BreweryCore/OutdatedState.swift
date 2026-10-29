public enum OutdatedState: Hashable, Codable {
    case upToDate
    case updateAvailable(latest: String)
    case selfUpdating(latestKnown: String?)
    case unknown
}
