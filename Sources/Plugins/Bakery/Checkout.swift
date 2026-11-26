import BaguetteDevice
import BaguetteDeviceFamilies
import Foundation
import Mockable

/// The ability to fetch a bakery's files onto disk — the boundary
/// between "decide what to install" (pure Domain) and "actually talk to
/// git" (Infrastructure).
///
/// Conversational I/O with an external tool (clone, resolve HEAD,
/// later pull), so it's a `@Mockable` collaborator per the codebase's
/// adapter-splitting rule: the orchestrator (`BakeryInstall`) depends
/// on `any Checkout`, tests inject a fake pointing at a pre-populated
/// temp dir, and the concrete `GitCheckout` stays integration-only.
@Mockable
protocol Checkout: Sendable {
    /// Shallow-clone `ref` into `directory`, returning the directory
    /// and the commit that landed.
    ///
    /// `commit` is the pin. Pass `nil` on first contact — there is
    /// nothing to demand yet, so the default branch is taken and what
    /// arrived is reported back to be recorded. Pass a recorded sha
    /// afterwards and that exact commit is fetched: a shallow clone of
    /// a moving branch otherwise hands back whatever HEAD is today, so
    /// without this the recorded sha would only ever *describe* what we
    /// happened to get rather than constrain it.
    ///
    /// Throws if the remote won't serve the pin — a bakery that force-
    /// pushed it away must not quietly become whatever replaced it.
    func clone(_ ref: BakeryRef, into directory: URL, at commit: String?) async throws -> CheckoutResult

    /// Re-pull an existing clone in place, returning the new commit.
    func pull(at directory: URL) async throws -> String

    /// What the remote's default branch points at right now, without
    /// cloning anything. Backs `bakery outdated`, which would otherwise
    /// have to clone every trusted source to answer a question about
    /// one sha.
    func head(of ref: BakeryRef) async throws -> String
}

/// Where a bakery's files landed, and at what commit.
struct CheckoutResult: Equatable, Sendable {
    let directory: URL
    let commit: String
}
