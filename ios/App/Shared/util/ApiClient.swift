//
//  ApiClient.swift
//  App
//
//  Created by Rasmus Krämer on 13.04.22.
//

import Foundation
import Alamofire

class ApiClient {
    public static func getData(from url: URL, completion: @escaping (UIImage?) -> Void) {
        URLSession.shared.dataTask(with: url, completionHandler: {(data, response, error) in
            if let data = data {
                completion(UIImage(data:data))
            }
        }).resume()
    }
    
    public static func postResource<T: Decodable>(endpoint: String, parameters: [String: Any], decodable: T.Type = T.self, callback: ((_ param: T) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: headers).responseDecodable(of: decodable) { response in
            switch response.result {
            case .success(let obj):
                callback?(obj)
            case .failure(let error):
                AbsLogger.error(message: "api request to \(endpoint) failed")
                print(error)
            }
        }
    }
    
    public static func postResource<T: Encodable, U: Decodable>(endpoint: String, parameters: T, decodable: U.Type = U.self, callback: ((_ param: U) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, headers: headers).responseDecodable(of: decodable) { response in
            switch response.result {
            case .success(let obj):
                callback?(obj)
            case .failure(let error):
                AbsLogger.error(message: "api request to \(endpoint) failed")
                print(error)
            }
        }
    }
    
    public static func postResource<T:Encodable>(endpoint: String, parameters: T) async -> Bool {
        return await withCheckedContinuation { continuation in
            postResource(endpoint: endpoint, parameters: parameters) { success in
                continuation.resume(returning: success)
            }
        }
    }
    
    public static func postResource<T:Encodable>(endpoint: String, parameters: T, callback: ((_ success: Bool) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            callback?(false)
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, headers: headers).response { response in
            switch response.result {
            case .success(_):
                callback?(true)
            case .failure(let error):
                AbsLogger.error(message: "api request to \(endpoint) failed")
                print(error)
                
                callback?(false)
            }
        }
    }
    
    public static func patchResource<T: Encodable>(endpoint: String, parameters: T, callback: ((_ success: Bool) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            callback?(false)
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .patch, parameters: parameters, encoder: JSONParameterEncoder.default, headers: headers).response { response in
            switch response.result {
            case .success(_):
                callback?(true)
            case .failure(let error):
                AbsLogger.error(message: "api request to \(endpoint) failed")
                print(error)
                callback?(false)
            }
        }
    }
    
    public static func getResource<T: Decodable>(endpoint: String, decodable: T.Type = T.self) async -> T? {
        return await withCheckedContinuation { continuation in
            getResource(endpoint: endpoint, decodable: decodable) { result in
                continuation.resume(returning: result)
            }
        }
    }
    
    public static func getResource<T: Decodable>(endpoint: String, decodable: T.Type = T.self, callback: ((_ param: T?) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            callback?(nil)
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .get, encoding: JSONEncoding.default, headers: headers).responseDecodable(of: decodable) { response in
            switch response.result {
                case .success(let obj):
                    callback?(obj)
                case .failure(let error):
                    AbsLogger.error(message: "api request to \(endpoint) failed")
                    print(error)
            }
        }
    }
    
    // MARK: - Token Refresh Handling
    
    /**
     * Handles token refresh when a 401 Unauthorized response is received
     * This function will:
     * 1. Get the refresh token from secure storage for the current server connection
     * 2. Make a request to /auth/refresh endpoint with the refresh token
     * 3. Update the connection config with the new accessToken and put the refreshToken in secure storage
     * 4. Retry the original request with the new access token
     * 5. If refresh fails, handle logout
     */
    private static func handleTokenRefresh<T: Decodable>(originalRequest: DataRequest, endpoint: String, method: HTTPMethod, parameters: Any?, decodable: T.Type, callback: ((_ param: T?) -> Void)?) {
        // Route through the shared coordinator so this legacy refresh is single-flighted together
        // with the generated client's refreshes: a burst of concurrent 401s produces exactly one
        // /auth/refresh round-trip (the coordinator persists the tokens + notifies the WebView).
        Task {
            guard let newAccessToken = await ABSTokenRefreshCoordinator.shared.refreshAccessToken() else {
                AbsLogger.error(message: "handleTokenRefresh: Refresh failed")
                callback?(nil)
                return
            }
            AbsLogger.info(message: "handleTokenRefresh: Retrying original request with new token")
            retryOriginalRequest(endpoint: endpoint, method: method, parameters: parameters, decodable: decodable, newAccessToken: newAccessToken, callback: callback)
        }
    }
    
    /**
     * Retries the original request with the new access token
     */
    private static func retryOriginalRequest<T: Decodable>(endpoint: String, method: HTTPMethod, parameters: Any?, decodable: T.Type, newAccessToken: String, callback: ((_ param: T?) -> Void)?) {
        guard let serverConfig = Store.serverConfig else {
            AbsLogger.error(message: "retryOriginalRequest: No server config available")
            callback?(nil)
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(newAccessToken)"
        ]
        
        let retryRequest: DataRequest
        
        switch method {
        case .get:
            retryRequest = AF.request("\(serverConfig.address)/\(endpoint)", method: .get, headers: headers)
        case .post:
            if let parameters = parameters as? [String: Any] {
                retryRequest = AF.request("\(serverConfig.address)/\(endpoint)", method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: headers)
            } else if let encodableParams = parameters as? Encodable {
                retryRequest = AF.request("\(serverConfig.address)/\(endpoint)", method: .post, parameters: encodableParams, encoder: JSONParameterEncoder.default, headers: headers)
            } else {
                retryRequest = AF.request("\(serverConfig.address)/\(endpoint)", method: .post, headers: headers)
            }
        case .patch:
            if let encodableParams = parameters as? Encodable {
                retryRequest = AF.request("\(serverConfig.address)/\(endpoint)", method: .patch, parameters: encodableParams, encoder: JSONParameterEncoder.default, headers: headers)
            } else {
                retryRequest = AF.request("\(serverConfig.address)/\(endpoint)", method: .patch, headers: headers)
            }
        default:
            AbsLogger.error(message: "retryOriginalRequest: Unsupported method \(method)")
            callback?(nil)
            return
        }
        
        // Handle the response
        retryRequest.response { response in
            if let statusCode = response.response?.statusCode, (200...299).contains(statusCode) {
                // Check if response has data
                if let data = response.data, !data.isEmpty {
                    // If it is a string return nil (e.g. express returns OK for 200 status codes)
                    if let responseString = String(data: data, encoding: .utf8) {
                        AbsLogger.info(message: "retryOriginalRequest: Got string response '\(responseString)'")
                        callback?(nil)
                        return
                    }
                    
                    // If not a string, try JSON
                    do {
                        let decodedObject = try JSONDecoder().decode(decodable, from: data)
                        callback?(decodedObject)
                    } catch {
                        AbsLogger.error(message: "retryOriginalRequest: JSON decode failed: \(error)", error: error)
                        callback?(nil)
                    }
                } else {
                    // Empty response
                    AbsLogger.info(message: "retryOriginalRequest: Empty response with success status \(statusCode)")
                    callback?(nil)
                }
            } else {
                AbsLogger.error(message: "retryOriginalRequest: Request failed with status \(response.response?.statusCode ?? 0)")
                callback?(nil)
            }
        }
    }
    
    // MARK: - Enhanced API Methods with Token Refresh
    
    public static func getResourceWithTokenRefresh<T: Decodable>(endpoint: String, decodable: T.Type = T.self, callback: ((_ param: T?) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            callback?(nil)
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        let request = AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .get, headers: headers)
        
        request.responseDecodable(of: decodable) { response in
            if let statusCode = response.response?.statusCode, statusCode == 401 {
                AbsLogger.info(message: "getResourceWithTokenRefresh: 401 Unauthorized for request to \(endpoint) - attempting token refresh")
                handleTokenRefresh(originalRequest: request, endpoint: endpoint, method: .get, parameters: nil, decodable: decodable, callback: callback)
            } else {
                switch response.result {
                case .success(let obj):
                    callback?(obj)
                case .failure(let error):
                    AbsLogger.error(message: "api request to \(endpoint) failed")
                    print(error)
                    callback?(nil)
                }
            }
        }
    }
    
    public static func postResourceWithTokenRefresh<T: Encodable, U: Decodable>(endpoint: String, parameters: T, decodable: U.Type = U.self, callback: ((_ param: U?) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            callback?(nil)
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        let request = AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, headers: headers)
        
        request.responseDecodable(of: decodable) { response in
            if let statusCode = response.response?.statusCode, statusCode == 401 {
                AbsLogger.info(message: "postResourceWithTokenRefresh: 401 Unauthorized for request to \(endpoint) - attempting token refresh")
                handleTokenRefresh(originalRequest: request, endpoint: endpoint, method: .post, parameters: parameters, decodable: decodable, callback: callback)
            } else {
                switch response.result {
                case .success(let obj):
                    callback?(obj)
                case .failure(let error):
                    AbsLogger.error(message: "api request to \(endpoint) failed")
                    print(error)
                    callback?(nil)
                }
            }
        }
    }

    /**
     * POST request for endpoints that only return success/failure
     */
    public static func postResourceWithTokenRefresh<T: Encodable>(endpoint: String, parameters: T, callback: ((_ success: Bool) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            callback?(false)
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        let request = AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, headers: headers)
        
        request.response { response in
            if let statusCode = response.response?.statusCode, statusCode == 401 {
                AbsLogger.info(message: "postResourceWithTokenRefresh: 401 Unauthorized for request to \(endpoint) - attempting token refresh")
                handleTokenRefresh(originalRequest: request, endpoint: endpoint, method: .post, parameters: parameters, decodable: EmptyResponse.self) { result in
                    callback?(result != nil)
                }
            } else {
                switch response.result {
                case .success(_):
                    callback?(true)
                case .failure(let error):
                    AbsLogger.error(message: "api request to \(endpoint) failed")
                    print(error)
                    callback?(false)
                }
            }
        }
    }
    
    public static func patchResourceWithTokenRefresh<T: Encodable>(endpoint: String, parameters: T, callback: ((_ success: Bool) -> Void)?) {
        if (Store.serverConfig == nil) {
            AbsLogger.error(message: "Server config not set")
            callback?(false)
            return
        }
        
        let headers: HTTPHeaders = [
            "Authorization": "Bearer \(Store.serverConfig!.token)"
        ]
        
        let request = AF.request("\(Store.serverConfig!.address)/\(endpoint)", method: .patch, parameters: parameters, encoder: JSONParameterEncoder.default, headers: headers)
        
        request.response { response in
            if let statusCode = response.response?.statusCode, statusCode == 401 {
                AbsLogger.info(message: "patchResourceWithTokenRefresh: 401 Unauthorized for request to \(endpoint) - attempting token refresh")
                handleTokenRefresh(originalRequest: request, endpoint: endpoint, method: .patch, parameters: parameters, decodable: EmptyResponse.self) { result in
                    callback?(result != nil)
                }
            } else {
                switch response.result {
                case .success(_):
                    callback?(true)
                case .failure(let error):
                    AbsLogger.error(message: "api request to \(endpoint) failed")
                    print(error)
                    callback?(false)
                }
            }
        }
    }
    
    // MARK: - API Functions
    
    public static func startPlaybackSession(libraryItemId: String, episodeId: String?, forceTranscode:Bool, callback: @escaping (_ param: PlaybackSession) -> Void) {
        // Phase 4 migration: served solely by the generated ABSApiClient (no legacy fallback).
        // The DTO is fetched off-thread, but the Realm PlaybackSession is built AND consumed on the
        // main actor: it is saved to Realm and used by the player on the main thread immediately
        // after, and Realm object graphs must be constructed and used on the same thread. (The
        // legacy Alamofire path decoded on the main queue, preserving this.)
        Task {
            let dto = await ABSApi.startPlaybackSessionDTO(libraryItemId: libraryItemId, episodeId: episodeId, forceTranscode: forceTranscode)
            await MainActor.run {
                guard let dto = dto else {
                    AbsLogger.error(message: "startPlaybackSession: Failed to create playback session")
                    callback(PlaybackSession()) // Empty session on failure, per the contract
                    return
                }
                let session = PlaybackSession.from(dto: dto)
                session.serverConnectionConfigId = Store.serverConfig?.id
                session.serverAddress = Store.serverConfig?.address
                callback(session)
            }
        }
    }
    
    public static func reportPlaybackProgress(report: PlaybackReport, sessionId: String) async -> Bool {
        // Phase 3 migration: served solely by the generated ABSApiClient (no legacy fallback).
        return await ABSApi.reportPlaybackProgress(report: report, sessionId: sessionId)
    }

    public static func reportLocalPlaybackProgress(_ session: PlaybackSession) async -> Bool {
        // Phase 3 migration: served solely by the generated ABSApiClient (no legacy fallback).
        return await ABSApi.reportLocalPlaybackProgress(session)
    }

    public static func reportAllLocalPlaybackSessions(_ sessions: [PlaybackSession]) async -> Bool {
        // Phase 3 migration: served solely by the generated ABSApiClient (no legacy fallback).
        return await ABSApi.reportAllLocalPlaybackSessions(sessions)
    }
    
    public static func syncLocalSessionsWithServer(isFirstSync: Bool) async {
        do {
            // Sync server progress with local media progress
            let localMediaProgressList = Database.shared.getAllLocalMediaProgress().filter {
                $0.serverConnectionConfigId == Store.serverConfig?.id
            }.map { $0.freeze() }
            AbsLogger.info(message: "syncLocalSessionsWithServer: Found \(localMediaProgressList.count) local media progress for server")
            
            if (localMediaProgressList.isEmpty) {
                AbsLogger.info(message: "syncLocalSessionsWithServer: No local progress to sync")
            } else {
                let currentUser = await ApiClient.getCurrentUser()
                guard let currentUser = currentUser else {
                    AbsLogger.info(message: "syncLocalSessionsWithServer: No User")
                    return
                }
                try currentUser.mediaProgress.forEach { mediaProgress in
                    let localMediaProgress = localMediaProgressList.first { lmp in
                        if (lmp.episodeId != nil) {
                            return lmp.episodeId == mediaProgress.episodeId
                        } else {
                            return lmp.libraryItemId == mediaProgress.libraryItemId
                        }
                    }
                    if (localMediaProgress != nil && mediaProgress.lastUpdate > localMediaProgress!.lastUpdate) {
                        AbsLogger.info(message: "syncLocalSessionsWithServer: Updating local media progress \(localMediaProgress!.id) with server media progress")
                        if let localMediaProgress = localMediaProgress?.thaw() {
                            try localMediaProgress.updateFromServerMediaProgress(mediaProgress)
                        }
                    } else if (localMediaProgress != nil) {
                        AbsLogger.info(message: "syncLocalSessionsWithServer: Local progress for \(localMediaProgress!.id) is more recent then server progress")
                    }
                }
            }
            
            // Send saved playback sessions to server and remove them from db
            let playbackSessions = Database.shared.getAllPlaybackSessions().filter {
                $0.serverConnectionConfigId == Store.serverConfig?.id
            }.map { $0.freeze() }
            AbsLogger.info(message: "syncLocalSessionsWithServer: Found \(playbackSessions.count) playback sessions for server (first sync: \(isFirstSync))")
            if (!playbackSessions.isEmpty) {
                let success = await ApiClient.reportAllLocalPlaybackSessions(playbackSessions)
                if (success) {
                    // Remove sessions from db
                    try playbackSessions.forEach { session in
                        AbsLogger.info(message: "syncLocalSessionsWithServer: Handling \(session.displayTitle ?? "") (\(session.id)) \(session.isActiveSession)")
                        // On first sync then remove all sessions
                        if (!session.isActiveSession || isFirstSync) {
                            if let session = session.thaw() {
                                try session.delete()
                            }
                        }
                    }
                }
            }
        } catch {
            debugPrint(error)
            return
        }
    }
    
    public static func updateMediaProgress<T:Encodable>(libraryItemId: String, episodeId: String?, payload: T, callback: @escaping () -> Void) {
        AbsLogger.info(message: "updateMediaProgress \(libraryItemId) \(episodeId ?? "NIL") \(payload)")
        // Phase 3 migration: served solely by the generated ABSApiClient (no legacy fallback).
        // Preserves the fire-and-forget callback contract (invoked after the request completes).
        Task {
            _ = await ABSApi.updateMediaProgress(libraryItemId: libraryItemId, episodeId: episodeId, payload: payload)
            callback()
        }
    }
    
    public static func getMediaProgress(libraryItemId: String, episodeId: String?) async -> MediaProgress? {
        AbsLogger.info(message: "getMediaProgress \(libraryItemId) \(episodeId ?? "NIL")")
        // Phase 2 migration: served solely by the generated ABSApiClient (no legacy fallback).
        return await ABSApi.getMediaProgress(libraryItemId: libraryItemId, episodeId: episodeId)
    }

    public static func getCurrentUser() async -> User? {
        AbsLogger.info(message: "getCurrentUser")
        // Phase 2 migration: served solely by the generated ABSApiClient (no legacy fallback).
        return await ABSApi.getCurrentUser()
    }
    
    public static func getLibraryItemWithProgress(libraryItemId: String, episodeId: String?, callback: @escaping (_ param: LibraryItem?) -> Void) {
        // Phase 5 migration: fetched via the generated client as a freeform object, then decoded
        // into the Realm LibraryItem with its own lenient decoder ON THE MAIN THREAD (Realm object,
        // immediately persisted/used by the downloader on main).
        Task {
            let data = await ABSApi.getLibraryItemData(libraryItemId: libraryItemId, episodeId: episodeId)
            await MainActor.run {
                guard let data = data else {
                    callback(nil)
                    return
                }
                do {
                    callback(try JSONDecoder().decode(LibraryItem.self, from: data))
                } catch {
                    AbsLogger.error(message: "getLibraryItemWithProgress: decode failed: \(error)")
                    callback(nil)
                }
            }
        }
    }
    
    public static func pingServer() async -> Bool {
        var status = true
        AF.request("\(Store.serverConfig!.address)/ping", method: .get).responseDecodable(of: PingResponsePayload.self) { response in
            switch response.result {
                case .success:
                    status = true
                case .failure:
                    status = false
            }
        }
        return status
    }
}

struct LocalMediaProgressSyncPayload: Codable {
    var localMediaProgress: [LocalMediaProgress]
}

struct PingResponsePayload: Codable {
    var success: Bool
}

struct MediaProgressSyncResponsePayload: Decodable {
    var numServerProgressUpdates: Int?
    var localProgressUpdates: [LocalMediaProgress]?
    
    private enum CodingKeys : String, CodingKey {
        case numServerProgressUpdates, localProgressUpdates
    }
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        numServerProgressUpdates = try? values.intOrStringDecoder(key: .numServerProgressUpdates)
        localProgressUpdates = try? values.decode([LocalMediaProgress].self, forKey: .localProgressUpdates)
    }
}

struct LocalMediaProgressSyncResultsPayload: Codable {
    var numLocalMediaProgressForServer: Int?
    var numServerProgressUpdates: Int?
    var numLocalProgressUpdates: Int?
}

struct LocalPlaybackSessionSyncAllPayload: Codable {
    var sessions: [PlaybackSession]
    var deviceInfo: [String: String?]?
}

struct Connectivity {
  static private let sharedInstance = NetworkReachabilityManager()!
  static var isConnectedToInternet:Bool {
      return self.sharedInstance.isReachable
    }
}

// MARK: - Response Models

struct EmptyResponse: Decodable {}

struct PlaybackSessionRequest: Encodable {
    let forceDirectPlay: String
    let forceTranscode: String
    let mediaPlayer: String
    let deviceInfo: DeviceInfo
}

struct DeviceInfo: Encodable {
    let deviceId: String?
    let manufacturer: String
    let model: String?
    let clientVersion: String?
}
