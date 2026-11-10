// Signposts for Instruments (the "Points of Interest" and os_signpost
// instruments, subsystem app.heypigeon): where the time goes between a key
// or a tap and the frame that answers it. The performance work so far was
// done by reading the code; these are what makes the next round a
// measurement. An interval costs nothing to speak of when no one records.
//
//   reload         the list's synchronous re-read on the main actor
//   reload.apply   landing a snapshot (regroup, counts, the open thread)
//   thread.open    a thread asked for → its messages on screen
//   thread.fetch   …and → Gmail's copy in place of the stored one
//   search         a typed query → its results
//   key            one key of the Mac's keyboard map, handled
//   sync           a sync round

import Foundation
import os

enum Trace {
    static let signposter = OSSignposter(subsystem: "app.heypigeon", category: .pointsOfInterest)

    /// Time `body` under `name`.
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// An interval that spans awaits: `end` it with what this returns.
    /// Its own id: two of a name overlap (a second thread opened while
    /// the first is still being fetched), and the default id is for
    /// intervals that never do — Instruments paired them wrongly.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// A moment worth a mark (a key went down).
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
