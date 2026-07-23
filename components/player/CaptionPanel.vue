<template>
  <div class="caption-panel w-full h-full flex items-center justify-center px-4" :style="{ width: width + 'px' }">
    <p v-if="status === 'error'" class="text-center text-fg text-opacity-75 text-sm">{{ statusMessage }}</p>
    <p v-else-if="status === 'downloading-model'" class="text-center text-fg text-opacity-75 text-sm">{{ $strings.MessageDownloadingLanguageSupport }}</p>
    <p v-else-if="!visibleWords.length" class="text-center text-fg text-opacity-50 text-sm">{{ $strings.MessagePreparingCaptions }}</p>
    <p v-else class="caption-text text-center text-fg leading-relaxed">
      <span v-for="(word, index) in visibleWords" :key="index" :class="word.isActive ? 'text-fg font-semibold' : 'text-fg text-opacity-60'">{{ word.text }}</span>
    </p>
  </div>
</template>

<script>
import { AbsTranscriber } from '@/plugins/capacitor'
import { createAnchor, estimateBookTime, findActiveWord, mergeSegments, pruneSegments } from '@/utils/captionClock'

export default {
  props: {
    currentTime: { type: Number, default: 0 },
    isPlaying: { type: Boolean, default: false },
    playbackRate: { type: Number, default: 1 },
    libraryItemId: { type: String, default: null },
    width: { type: Number, default: 300 }
  },
  data() {
    return {
      segments: [],
      anchor: null,
      estimatedTime: 0,
      status: 'preparing',
      statusMessage: '',
      rafHandle: null
    }
  },
  computed: {
    // Show the active segment's words, so the reader gets a sentence of context.
    visibleWords() {
      const active = findActiveWord(this.segments, this.estimatedTime)
      if (!active) return []
      const segment = this.segments[active.segmentIndex]
      return (segment.words || []).map((word, index) => ({
        text: index === 0 ? word.text : ' ' + word.text,
        isActive: index === active.wordIndex
      }))
    }
  },
  watch: {
    // Every native time report re-anchors the clock (bounding drift) and tells
    // the scheduler where we are, so the window keeps topping up as we listen.
    currentTime() {
      this.reanchor()
      AbsTranscriber.updateTime({ currentTime: this.currentTime })
    },
    isPlaying() {
      this.reanchor()
    },
    playbackRate() {
      this.reanchor()
    }
  },
  methods: {
    reanchor() {
      this.anchor = createAnchor({
        bookTime: this.currentTime,
        rate: this.playbackRate,
        isPlaying: this.isPlaying,
        now: performance.now()
      })
    },
    tick() {
      this.estimatedTime = estimateBookTime(this.anchor, performance.now())
      this.rafHandle = requestAnimationFrame(this.tick)
    },
    onCaptionSegments(data) {
      const merged = mergeSegments(this.segments, data.segments || [])
      this.segments = pruneSegments(merged, this.estimatedTime, 1800)
    },
    onCaptionStatus(data) {
      this.status = data.status
      this.statusMessage = data.message || ''
    }
  },
  async mounted() {
    this.reanchor()
    this.tick()

    this.captionSegmentsListener = await AbsTranscriber.addListener('onCaptionSegments', this.onCaptionSegments)
    this.captionStatusListener = await AbsTranscriber.addListener('onCaptionStatus', this.onCaptionStatus)

    try {
      await AbsTranscriber.enable({ libraryItemId: this.libraryItemId, currentTime: this.currentTime })
    } catch (error) {
      this.status = 'error'
      this.statusMessage = error.message || 'Captions unavailable'
    }
  },
  beforeDestroy() {
    if (this.rafHandle) cancelAnimationFrame(this.rafHandle)
    this.captionSegmentsListener?.remove()
    this.captionStatusListener?.remove()
    AbsTranscriber.disable()
  }
}
</script>

<style scoped>
.caption-text {
  font-size: 1.05rem;
  max-height: 100%;
  overflow: hidden;
}
</style>
