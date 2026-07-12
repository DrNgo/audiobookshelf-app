/**
 * Parse the home-screen widget's tap-to-resume deep link.
 *
 * The widget embeds the exact item it is displaying in the URL
 * (`audiobookshelf://resume?libraryItemId=<id>&episodeId=<id>`) so that tapping it resumes THAT book
 * — not whatever session happens to still be loaded in the player from a previous book (which is what
 * the old id-less `audiobookshelf://resume` link caused on a warm launch). Older widget builds still
 * send the id-less form; those resolve to `{ libraryItemId: null, episodeId: null }`, and the caller
 * falls back to the most-recent in-progress item.
 *
 * Plain CommonJS (not a registered Nuxt plugin) so the one-off node test can require() it directly;
 * webpack still resolves the named `import` from the component.
 *
 * @param {string|null|undefined} url
 * @returns {{ libraryItemId: string|null, episodeId: string|null }|null} null when this is not a
 *          widget resume link (caller should ignore it).
 */
function parseWidgetResumeUrl(url) {
  if (!url || !url.startsWith('audiobookshelf://resume')) return null
  try {
    const params = new URL(url).searchParams
    return {
      libraryItemId: params.get('libraryItemId') || null,
      episodeId: params.get('episodeId') || null
    }
  } catch (e) {
    // Malformed but still a resume link — treat as the legacy id-less form.
    return { libraryItemId: null, episodeId: null }
  }
}

module.exports = { parseWidgetResumeUrl }
