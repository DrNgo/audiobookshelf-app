//
//  NowPlaying.swift
//  App
//
//  Created by Rasmus Krämer on 22.03.22.
//

import Foundation
import MediaPlayer

struct NowPlayingMetadata {
    var id: String
    var itemId: String
    var title: String
    var author: String?
    var series: String?
    var isLocal: Bool
    
    var coverUrl: URL? {
        if self.isLocal {
            guard let item = Database.shared.getLocalLibraryItem(byServerLibraryItemId: self.itemId) else { return nil }
            return item.coverUrl
        } else {
            guard let config = Store.serverConfig else { return nil }
            
            // As of v2.17.0 token is not needed with cover image requests. Force JPEG because the
            // server's default WebP decodes unreliably via UIImage(data:), leaving Now Playing artless.
            let coverUrlString: String
            if Store.isServerVersionGreaterThanOrEqualTo("2.17.0") {
                coverUrlString = "\(config.address)/api/items/\(itemId)/cover?format=jpeg"
            } else {
                coverUrlString = "\(config.address)/api/items/\(itemId)/cover?token=\(config.token)&format=jpeg"
            }
            
            return URL(string: coverUrlString)
        }
    }
}

class NowPlayingInfo {
    static var shared = {
        return NowPlayingInfo()
    }()
    
    private var nowPlayingInfo: [String: Any]
    private init() {
        self.nowPlayingInfo = [:]
    }
    
    public func setSessionMetadata(metadata: NowPlayingMetadata) {
        setMetadata(artwork: nil, metadata: metadata)
        guard let url = metadata.coverUrl else { return }
        // For local images, "downloading" is occurring off disk, hence this code path works as expected
        ApiClient.getData(from: url) { [self] image in
            guard let downloadedImage = image else {
                return
            }
            let artwork = MPMediaItemArtwork.init(boundsSize: downloadedImage.size, requestHandler: { _ -> UIImage in
                return downloadedImage
            })

            // The URLSession callback runs off the main thread; setMetadata mutates the shared
            // nowPlayingInfo dictionary that update() also mutates on main, so hop to main to avoid
            // a data race.
            DispatchQueue.main.async {
                self.setMetadata(artwork: artwork, metadata: metadata)
            }
        }
    }
    public func update(duration: Double, currentTime: Double, rate: Float, defaultRate: Float, chapterName: String? = nil, chapterNumber: Int? = nil, chapterCount: Int? = nil) {
        // Update on the main to prevent access collisions
        DispatchQueue.main.async { [weak self] in
            if let self = self {
                self.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
                self.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
                self.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = rate
                self.nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = defaultRate
                    
                
                if let chapterName = chapterName, let chapterNumber = chapterNumber, let chapterCount = chapterCount {
                    self.nowPlayingInfo[MPMediaItemPropertyTitle] = chapterName
                    self.nowPlayingInfo[MPNowPlayingInfoPropertyChapterNumber] = chapterNumber
                    self.nowPlayingInfo[MPNowPlayingInfoPropertyChapterCount] = chapterCount
                } else {
                    // Set the title back to the book title
                    self.nowPlayingInfo[MPMediaItemPropertyTitle] = self.nowPlayingInfo[MPMediaItemPropertyAlbumTitle]
                    self.nowPlayingInfo[MPNowPlayingInfoPropertyChapterNumber] = nil
                    self.nowPlayingInfo[MPNowPlayingInfoPropertyChapterCount] = nil
                }
                
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo
            }
        }
    }

    public func reset() {
        nowPlayingInfo = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    // internal (not private) so unit tests can exercise the published metadata directly,
    // without going through setSessionMetadata's Realm-backed coverUrl lookup.
    func setMetadata(artwork: MPMediaItemArtwork?, metadata: NowPlayingMetadata?) {
        if metadata == nil {
            return
        }
        
        if artwork != nil {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        } else if shouldFetchCover(id: metadata!.id) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = nil
        }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier] = metadata!.id
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false
        // MPNowPlayingInfoPropertyMediaType expects an MPNowPlayingInfoMediaType raw value (a number),
        // not a string. A string is type-mismatched and the system treats the media type as .none,
        // which can change how CarPlay / the lock screen lay out the Now Playing template.
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata!.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = metadata!.author ?? "unknown"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = metadata!.title

        // Publish immediately so the title + cover reach CarPlay / the lock screen right away,
        // instead of only when the next time-observer-driven update() fires — which never happens
        // if playback is stalled or paused. update() later republishes with duration/elapsed/rate.
        let snapshot = nowPlayingInfo
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = snapshot
        }
    }
    
    private func shouldFetchCover(id: String) -> Bool {
        nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String != id || nowPlayingInfo[MPMediaItemPropertyArtwork] == nil
    }
}
