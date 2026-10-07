import Testing
import ZenithBarKit

/// A drawing is made again only when what it shows changes, each slot at each scale on its own.
@Test func drawsOnlyWhenWhatItShowsChanges() {
    var cache = DrawingCache<Int>()
    var draws = 0
    let draw = { () -> Int in
        draws += 1
        return draws
    }
    #expect(cache.drawing("volume", scale: 2, shows: "speaker.wave.2.fill", draw: draw) == 1)
    #expect(cache.drawing("volume", scale: 2, shows: "speaker.wave.2.fill", draw: draw) == 1)
    #expect(cache.drawing("volume", scale: 1, shows: "speaker.wave.2.fill", draw: draw) == 2)
    #expect(cache.drawing("mic", scale: 2, shows: "speaker.wave.2.fill", draw: draw) == 3)
    #expect(cache.drawing("volume", scale: 2, shows: "speaker.wave.3.fill", draw: draw) == 4)
    #expect(cache.drawing("volume", scale: 1, shows: "speaker.wave.2.fill", draw: draw) == 2)
    // What a slot shows may change type, as no item's does today.
    #expect(cache.drawing("volume", scale: 1, shows: 1, draw: draw) == 5)
    #expect(draws == 5)
}
