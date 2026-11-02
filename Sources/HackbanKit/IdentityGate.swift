import Foundation

/// Who an account's queued changes may be sent as, and whether what's kept on this Mac for it may be shown.
///
/// Fails closed. Changes go out only as the user who made them, and only once a profile fetched with the
/// current tokens has confirmed who that is: a cached profile doesn't count. After a new sign-in nothing kept
/// on this Mac is shown until it's confirmed, and if it turns out to be someone else (or whose the data was
/// isn't known), it has to be forgotten.
public struct IdentityGate: Equatable, Sendable {
    /// The user the current tokens belong to, from a profile fetched with them. Nil until then.
    public private(set) var verified: String?
    /// Whose data is kept on this Mac (nil: unknown, or nothing kept).
    public var cacheOwner: String?
    /// New tokens are in and haven't been confirmed yet.
    public private(set) var signingIn = false
    /// Goes up whenever the tokens change (a sign-in starts, its tokens go in, a sign-out). A profile fetched
    /// under an older generation says nothing about the current tokens and is ignored.
    public private(set) var generation = 0

    public init(cacheOwner: String? = nil) {
        self.cacheOwner = cacheOwner
    }

    /// Whether what's kept on this Mac can be shown.
    public var showsCache: Bool { !signingIn }

    public enum Send: Equatable, Sendable {
        case send
        /// Not confirmed with the current tokens yet: wait.
        case hold
        /// Made as someone else: never send.
        case wrongUser
        /// Nobody knows who made them: never send.
        case unknownMaker
    }

    /// Whether changes made by `madeBy` may be sent now.
    public func send(madeBy: String?) -> Send {
        guard let verified, !signingIn else { return .hold }
        guard let madeBy else { return .unknownMaker }
        return madeBy == verified ? .send : .wrongUser
    }

    /// New tokens are about to replace the account's. Until they're confirmed nothing is sent or shown, and
    /// the previous confirmation no longer counts.
    public mutating func beginSignIn() {
        verified = nil
        signingIn = true
        generation += 1
    }

    /// The new tokens are in. Anything fetched before now used the old ones.
    public mutating func tokensInstalled() {
        generation += 1
    }

    /// After a relaunch, a sign-in that was never confirmed is still unconfirmed.
    public mutating func resumeSignIn() {
        verified = nil
        signingIn = true
    }

    public enum Confirmed: Equatable, Sendable {
        case same
        /// What's kept on this Mac belonged to someone else (or to nobody known) and must be forgotten.
        case someoneElse
    }

    /// A profile says who this is. `generation`: the gate's generation when that fetch started. If the
    /// tokens have changed since, it's ignored (nil).
    @discardableResult
    public mutating func confirm(_ userId: String, generation fetched: Int) -> Confirmed? {
        guard fetched == generation else { return nil }
        let owner = cacheOwner ?? verified
        // After a new sign-in, data of unknown ownership is treated as someone else's.
        let result: Confirmed = owner == userId || (owner == nil && !signingIn) ? .same : .someoneElse
        verified = userId
        cacheOwner = userId
        signingIn = false
        return result
    }

    /// Signed out: nothing is confirmed, and nothing is kept.
    public mutating func reset() {
        verified = nil
        cacheOwner = nil
        signingIn = false
        generation += 1
    }
}
