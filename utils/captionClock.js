/**
 * Pure caption timing math.
 *
 * The native player only reports currentTime once per second, which is far too
 * coarse for word-level highlighting. Rather than polling native harder, we treat
 * each report as an ANCHOR and interpolate locally against wall-clock time,
 * re-anchoring on every report. Drift is therefore bounded by the poll interval.
 *
 * No Vue, no Capacitor, no side effects.
 */

/**
 * @param {{ bookTime: number, rate: number, isPlaying: boolean, now: number }} params
 *   `now` is a performance.now() reading, in milliseconds.
 */
export function createAnchor({ bookTime, rate, isPlaying, now }) {
  return {
    bookTime: Number(bookTime) || 0,
    rate: Number(rate) > 0 ? Number(rate) : 1,
    isPlaying: !!isPlaying,
    wallClock: Number(now) || 0
  }
}

/** Estimated book time at `now`. A paused anchor never advances. */
export function estimateBookTime(anchor, now) {
  if (!anchor) return 0
  if (!anchor.isPlaying) return anchor.bookTime
  const elapsedSeconds = (now - anchor.wallClock) / 1000
  return anchor.bookTime + elapsedSeconds * anchor.rate
}

/**
 * Find the word covering `bookTime` in `segments` (sorted by start).
 * Returns `{ segmentIndex, wordIndex }`, or null when nothing covers it.
 *
 * Rule: show the MOST-RECENTLY-STARTED line at or behind the playhead (greatest
 * start <= bookTime). ASR over music/effects inflates some segments' `end` so an
 * older line overruns into the current one; anchoring on start (not coverage)
 * means such an overrunning older segment can never win once a newer line has
 * begun. If the playhead has run more than `holdLimit` seconds past that line's
 * end — a long pause or a seek into not-yet-transcribed audio — show nothing
 * ("Catching up") rather than a stale line.
 */
export function findActiveWord(segments, bookTime, holdLimit = 3) {
  if (!segments || !segments.length) return null

  // Rightmost segment whose start <= bookTime (binary search on the sorted starts).
  let lo = 0
  let hi = segments.length - 1
  let rightmost = -1
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (segments[mid].start <= bookTime) {
      rightmost = mid
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  if (rightmost === -1) return null // before the first segment

  const found = rightmost
  // Past this line's end by more than the hold window → a real gap, not this line.
  if (bookTime > segments[found].end + holdLimit) return null

  const words = segments[found].words || []
  for (let i = 0; i < words.length; i++) {
    if (bookTime >= words[i].start && bookTime <= words[i].end) {
      return { segmentIndex: found, wordIndex: i }
    }
  }
  // Inside the segment but in a gap between words — hold the previous word.
  let previous = -1
  for (let i = 0; i < words.length; i++) {
    if (words[i].start <= bookTime) previous = i
  }
  return previous === -1 ? { segmentIndex: found, wordIndex: 0 } : { segmentIndex: found, wordIndex: previous }
}

/**
 * Drop segments further than `radius` seconds from `bookTime`, so a long
 * session cannot accumulate a whole book's text in the WebView.
 */
export function pruneSegments(segments, bookTime, radius) {
  if (!segments) return []
  return segments.filter((s) => s.end >= bookTime - radius && s.start <= bookTime + radius)
}

/** Merge new segments into a sorted list, replacing any with the same start. */
export function mergeSegments(existing, incoming) {
  const byStart = new Map()
  for (const segment of existing || []) byStart.set(Math.round((Number(segment.start) || 0) * 1000), segment)
  for (const segment of incoming || []) byStart.set(Math.round((Number(segment.start) || 0) * 1000), segment)
  return Array.from(byStart.values()).sort((a, b) => a.start - b.start)
}
