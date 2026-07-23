// Builds the caption-biasing vocabulary when a book finishes downloading (iOS only).
//
// New downloads only (this fires solely off the native onItemDownloadComplete event),
// best-effort: offline or any fetch failure degrades to current-book context (or none)
// and never throws to the user. Registered AFTER nativeHttp.js so $nativeHttp exists.
import { Capacitor } from '@capacitor/core'
import { AbsDownloader, AbsTranscriber, AbsLogger } from '@/plugins/capacitor'

const MAX_SERIES_SIBLINGS = 12

// Matches the app's $encode (plugins/init.client.js): base64 then URI-encode.
// Used for the library-items `filter=series.<encoded seriesId>` query.
const encodeFilterValue = (text) => encodeURIComponent(Buffer.from(String(text)).toString('base64'))

export default function (context) {
  // $platform is only on the Vue prototype, not the plugin context — read it directly.
  if (Capacitor.getPlatform() !== 'ios') return

  const $nativeHttp = context.$nativeHttp
  if (!$nativeHttp) {
    console.warn('[captionContext] $nativeHttp not available; skipping context build')
    return
  }

  const gatherAndBuild = async (data) => {
    try {
      // Only successful downloads carry a localLibraryItem; a failed download has just libraryItemId.
      const localLibraryItem = data?.localLibraryItem
      if (!localLibraryItem) return
      if (localLibraryItem.mediaType !== 'book') return

      // downloadDirectory(for:) on the native side resolves either the local ("local_…") id
      // or the server id, but the local id is unambiguous — prefer it.
      const localItemId = localLibraryItem.id
      const serverItemId = data?.libraryItemId || localLibraryItem.libraryItemId
      if (!localItemId) return

      // A connected socket means the auth token is currently valid, so a server 401 →
      // token-refresh-failure → forced `/connect` redirect (logout, inside $nativeHttp) is
      // not reachable. Without a live connection we never touch the server: current-book
      // context is built from the local download snapshot and series enrichment is skipped.
      const socketConnected = !!context.store?.state?.socketConnected

      // Full metadata for the current book (description, series, authors, narrators).
      // Fall back to the metadata already in the download payload when not live-connected.
      let item = null
      if (serverItemId && socketConnected) {
        item = await $nativeHttp.get(`/api/items/${serverItemId}?expanded=1`).catch(() => null)
      }
      const md = item?.media?.metadata || localLibraryItem?.media?.metadata || {}

      // Biasing terms: title/subtitle/series are real content nouns worth biasing toward.
      const fields = []
      if (md.title) fields.push(md.title)
      if (md.subtitle) fields.push(md.subtitle)
      ;(md.series || []).forEach((s) => s?.name && fields.push(s.name))

      // Blacklist: author & narrator names are real people, not spoken characters —
      // and for dramatized / GraphicAudio titles the narrators list is the entire
      // voice cast. Pass them so the native builder subtracts them from the vocabulary
      // (and never biases toward them) rather than adding them as terms.
      const excludeNames = []
      ;(md.authors || []).forEach((a) => a?.name && excludeNames.push(a.name))
      if (md.authorName) excludeNames.push(md.authorName)
      ;(md.narrators || []).forEach((n) => n && excludeNames.push(n))

      const bookBlurb = md.description || md.desc || ''

      // Series siblings' blurbs (best-effort, capped). Needs the server-side libraryId and seriesId,
      // which only come from the expanded item fetch, so this is skipped when offline.
      const seriesBlurbs = []
      const libraryId = item?.libraryId || localLibraryItem?.libraryId
      const firstSeries = (md.series || [])[0]
      if (socketConnected && serverItemId && libraryId && firstSeries?.id) {
        const filter = `series.${encodeFilterValue(firstSeries.id)}`
        const res = await $nativeHttp
          .get(`/api/libraries/${libraryId}/items?filter=${filter}&limit=${MAX_SERIES_SIBLINGS}&expanded=1`)
          .catch(() => null)
        const siblings = res?.results || res?.libraryItems || []
        for (const sib of siblings) {
          const sid = sib?.id
          if (!sid || sid === serverItemId) continue
          // Prefer the description already in the (expanded) list response; if the server returned a
          // minified list without it, fetch the item detail (still bounded by MAX_SERIES_SIBLINGS).
          let desc = sib?.media?.metadata?.description || sib?.media?.metadata?.desc
          if (!desc) {
            const detail = await $nativeHttp.get(`/api/items/${sid}?expanded=1`).catch(() => null)
            desc = detail?.media?.metadata?.description || detail?.media?.metadata?.desc
          }
          if (desc) seriesBlurbs.push(desc)
        }
      }

      const result = await AbsTranscriber.buildContext({ libraryItemId: localItemId, fields, bookBlurb, seriesBlurbs, excludeNames })
      // Surface the extracted biasing vocabulary to the in-app Logs page so
      // caption accuracy can be evaluated (title + the terms it will bias toward).
      const terms = result?.terms || []
      const title = md.title || localItemId
      AbsLogger.info({
        tag: 'CaptionContext',
        message: `"${title}" → ${terms.length} biasing terms (${seriesBlurbs.length} series blurbs): ${terms.join(', ')}`
      })
    } catch (e) {
      console.warn('[captionContext] build failed (non-fatal)', e)
    }
  }

  AbsDownloader.addListener('onItemDownloadComplete', (data) => gatherAndBuild(data))
}
