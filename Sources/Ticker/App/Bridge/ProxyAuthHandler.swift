import Foundation

final class ProxyAuthHandler: BridgeMessageHandler {
    let handledTypes: Set<String> = [
        "loadProxyAuth",
        "setProxyDeviceKey",
        "clearProxyDeviceKey",
        "validateProxyDeviceKey",
        "refreshProxyAuth",
        "submitFeedback",
        "getSupportBundle"
    ]

    private let bridgeService: BridgeService
    private let deviceKeyService: DeviceKeyService

    init(container: ServiceContainer) {
        self.bridgeService = container.bridgeService
        self.deviceKeyService = container.deviceKeyService
    }

    func handle(_ message: BridgeMessage) async {
        switch message.type {
        case "loadProxyAuth":
            // Pure read of cached state - no network call
            guard let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid loadProxyAuth payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Missing callbackId for loadProxyAuth")
                return
            }
            Task {
                let auth = await self.deviceKeyService.loadProxyAuth()
                let (limits, usage) = await self.deviceKeyService.getLimitsAndUsage()

                await MainActor.run {
                    var response: [String: AnyCodable] = [
                        "state": AnyCodable(auth.state.rawValue),
                        "supportId": AnyCodable(auth.supportId as Any),
                        "deviceId": AnyCodable(auth.deviceId)
                    ]

                    // Include limits if available
                    if let limits = limits {
                        response["limits"] = AnyCodable([
                            "reqsPerMin": limits.reqsPerMin as Any,
                            "tokensPerDay": limits.tokensPerDay as Any,
                            "tokensPerMonth": limits.tokensPerMonth as Any
                        ])
                    }

                    // Include usage if available
                    if let usage = usage {
                        response["usage"] = AnyCodable([
                            "reqsThisMinute": usage.reqsThisMinute as Any,
                            "tokensToday": usage.tokensToday as Any,
                            "tokensThisMonth": usage.tokensThisMonth as Any,
                            "dayResetAt": usage.dayResetAt as Any,
                            "monthResetAt": usage.monthResetAt as Any
                        ])
                    }

                    bridgeService.respond(to: callbackId, with: response)
                }
            }

        case "setProxyDeviceKey":
            guard let callbackId = message.callbackId else {
                await bridgeService.sendBridgeError(type: message.type, reason: "Missing callbackId for setProxyDeviceKey")
                return
            }
            guard let payload = message.payload,
                  let key = payload["key"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid setProxyDeviceKey payload")
                await bridgeService.respondWithError(to: callbackId, error: "Invalid setProxyDeviceKey payload")
                return
            }
            Task {
                do {
                    let result = try await self.deviceKeyService.setProxyDeviceKey(key)
                    let newAuth = await self.deviceKeyService.loadProxyAuth()
                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "success": AnyCodable(true),
                            "state": AnyCodable(newAuth.state.rawValue),
                            "supportId": AnyCodable(result.supportId),
                            "limits": AnyCodable([
                                "reqsPerMin": result.limits?.reqsPerMin as Any,
                                "tokensPerDay": result.limits?.tokensPerDay as Any,
                                "tokensPerMonth": result.limits?.tokensPerMonth as Any
                            ]),
                            "usage": AnyCodable([
                                "reqsThisMinute": result.usage?.reqsThisMinute as Any,
                                "tokensToday": result.usage?.tokensToday as Any,
                                "tokensThisMonth": result.usage?.tokensThisMonth as Any,
                                "dayResetAt": result.usage?.dayResetAt as Any,
                                "monthResetAt": result.usage?.monthResetAt as Any
                            ])
                        ])
                    }
                } catch {
                    let newAuth = await self.deviceKeyService.loadProxyAuth()
                    await MainActor.run {
                        bridgeService.respondWithError(to: callbackId, error: error.localizedDescription)
                        // Also push state change
                        bridgeService.send(BridgeMessage(
                            type: "proxyAuthState",
                            payload: ["state": AnyCodable(newAuth.state.rawValue)]
                        ))
                    }
                }
            }

        case "clearProxyDeviceKey":
            guard let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid clearProxyDeviceKey payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Missing callbackId for clearProxyDeviceKey")
                return
            }
            Task {
                do {
                    try await self.deviceKeyService.clearProxyDeviceKey()
                    let newAuth = await self.deviceKeyService.loadProxyAuth()
                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "success": AnyCodable(true),
                            "state": AnyCodable(newAuth.state.rawValue)
                        ])
                    }
                } catch {
                    await MainActor.run {
                        bridgeService.respondWithError(to: callbackId, error: error.localizedDescription)
                    }
                }
            }

        case "validateProxyDeviceKey", "refreshProxyAuth":
            // Re-validate cached key with server and return fresh limits/usage
            guard let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid validateProxyDeviceKey/refreshProxyAuth payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Missing callbackId for validateProxyDeviceKey/refreshProxyAuth")
                return
            }
            Task {
                await self.deviceKeyService.revalidate()
                let newAuth = await self.deviceKeyService.loadProxyAuth()
                let (limits, usage) = await self.deviceKeyService.getLimitsAndUsage()

                await MainActor.run {
                    var response: [String: AnyCodable] = [
                        "state": AnyCodable(newAuth.state.rawValue),
                        "supportId": AnyCodable(newAuth.supportId as Any),
                        "deviceId": AnyCodable(newAuth.deviceId)
                    ]

                    if let limits = limits {
                        response["limits"] = AnyCodable([
                            "reqsPerMin": limits.reqsPerMin as Any,
                            "tokensPerDay": limits.tokensPerDay as Any,
                            "tokensPerMonth": limits.tokensPerMonth as Any
                        ])
                    }

                    if let usage = usage {
                        response["usage"] = AnyCodable([
                            "reqsThisMinute": usage.reqsThisMinute as Any,
                            "tokensToday": usage.tokensToday as Any,
                            "tokensThisMonth": usage.tokensThisMonth as Any,
                            "dayResetAt": usage.dayResetAt as Any,
                            "monthResetAt": usage.monthResetAt as Any
                        ])
                    }

                    bridgeService.respond(to: callbackId, with: response)
                }
            }

        case "submitFeedback":
            guard let callbackId = message.callbackId else {
                await bridgeService.sendBridgeError(type: message.type, reason: "Missing callbackId for submitFeedback")
                return
            }
            guard let payload = message.payload,
                  let feedbackType = payload["type"]?.value as? String,
                  let title = payload["title"]?.value as? String else {
                DebugLog.log("[WebViewManager] Invalid submitFeedback payload")
                await bridgeService.respondWithError(to: callbackId, error: "Invalid submitFeedback payload")
                return
            }
            let description = payload["description"]?.value as? String
            let screenshotBase64 = payload["screenshot"]?.value as? String
            let screenshotContentType = payload["screenshotContentType"]?.value as? String

            Task {
                do {
                    let feedbackId = try await self.deviceKeyService.submitFeedback(
                        type: feedbackType,
                        title: title,
                        description: description,
                        screenshotBase64: screenshotBase64,
                        screenshotContentType: screenshotContentType
                    )
                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "success": AnyCodable(true),
                            "feedbackId": AnyCodable(feedbackId)
                        ])
                    }
                } catch {
                    await MainActor.run {
                        bridgeService.respond(to: callbackId, with: [
                            "success": AnyCodable(false),
                            "error": AnyCodable(error.localizedDescription)
                        ])
                    }
                }
            }

        case "getSupportBundle":
            guard let callbackId = message.callbackId else {
                DebugLog.log("[WebViewManager] Invalid getSupportBundle payload")
                await bridgeService.sendBridgeError(type: message.type, reason: "Missing callbackId for getSupportBundle")
                return
            }
            Task {
                let bundle = await self.deviceKeyService.getSupportBundle()
                await MainActor.run {
                    bridgeService.respond(to: callbackId, with: [
                        "bundle": AnyCodable(bundle)
                    ])
                }
            }

        default:
            DebugLog.log("[ProxyAuthHandler] Unknown message type: \(message.type)")
        }
    }
}
