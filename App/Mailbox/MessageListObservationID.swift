struct MessageListObservationID: Hashable {
    let keys: [ThreadKey]
    let query: String
    let remoteRevision: Int
    let conversations: Bool
}
