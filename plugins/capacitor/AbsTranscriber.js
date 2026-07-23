import { registerPlugin, WebPlugin } from '@capacitor/core'

class AbsTranscriberWeb extends WebPlugin {
  constructor() {
    super()
  }

  async isSupported() {
    return { supported: false, reason: 'os' }
  }

  async enable() {}
  async updateTime() {}
  async disable() {}
}

const AbsTranscriber = registerPlugin('AbsTranscriber', {
  web: () => new AbsTranscriberWeb()
})

export { AbsTranscriber }
