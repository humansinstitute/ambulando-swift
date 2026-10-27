import Foundation

/// Which channel Deck's New thread composer starts in. Deck shows a Scope | Channel context; a new thread goes to one
/// channel the member can see there. The composer never guesses between several: with no single obvious channel it
/// asks, and the message cannot be sent until one is chosen.
public enum DeckCompose {
    /// The channel to preselect when the composer opens: the context's own channel when it is still eligible, else the
    /// only eligible channel, else none ("Choose channel").
    public static func initialChannel(context: WorkContext, eligible: [String]) -> String? {
        if let id = context.channelId, eligible.contains(id) { return id }
        return eligible.count == 1 ? eligible[0] : nil
    }

    /// The channel after the context or the eligible list changed while the composer is open. A channel the user chose
    /// is kept while the scope stays the same and it is still eligible; a scope change starts the choice again.
    public static func reconcile(chosen: String?, from previous: WorkContext, to context: WorkContext, eligible: [String]) -> String? {
        if previous.scopeId == context.scopeId, let chosen, eligible.contains(chosen) { return chosen }
        return initialChannel(context: context, eligible: eligible)
    }
}
