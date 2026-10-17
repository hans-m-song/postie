import Darwin
import Dispatch
import Foundation
import XCTest
@testable import PostieCore

final class HTTPIntegrationTests: XCTestCase {
    func testGETAndPOSTTransmitPreparedQueryHeadersAndBody() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))

        let get = HTTPRequestConfiguration(
            method: "GET",
            url: fixture.baseURL + "/echo?token=a%2Bb%2Fc&x=1",
            query: [
                HTTPField(name: "tag", value: "first value"),
                HTTPField(name: "disabled", value: "ignored", isEnabled: false),
                HTTPField(name: "tag", value: "second")
            ],
            headers: [HTTPField(name: "X-Integration", value: "get")]
        )
        let getEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: get.id),
            configuration: get
        ))
        let getResponse = try completedResponse(in: getEvents)
        XCTAssertEqual(getResponse.effectiveMethod, "GET")
        let getPayload = try responseJSON(getResponse)
        let rawQuery = try XCTUnwrap(getPayload["query"] as? String)
        let returnedURL = try XCTUnwrap(URLComponents(string: fixture.baseURL + (getPayload["path"] as? String ?? "") + "?" + rawQuery))
        XCTAssertEqual(returnedURL.queryItems?.map(\.name), ["token", "x", "tag", "tag"])
        XCTAssertEqual(returnedURL.queryItems?.map(\.value), ["a+b/c", "1", "first value", "second"])
        XCTAssertTrue(rawQuery.hasPrefix("token=a%2Bb%2Fc&x=1&"), "Existing percent-encoded query bytes must be preserved when fields are appended.")
        XCTAssertEqual(try XCTUnwrap(requestHeader("X-Integration", in: getPayload)), "get")
        XCTAssertEqual(getPayload["method"] as? String, "GET")
        XCTAssertEqual(getPayload["body"] as? String, "")
        try await manager.discardBody(at: getResponse.bodyFileURL)

        let post = HTTPRequestConfiguration(
            method: "POST",
            url: fixture.baseURL + "/echo",
            headers: [HTTPField(name: "X-Integration", value: "post")],
            body: "payload from Postie",
            bodyEnabled: true
        )
        let postEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: post.id),
            configuration: post
        ))
        let postResponse = try completedResponse(in: postEvents)
        XCTAssertEqual(postResponse.effectiveMethod, "POST")
        let postPayload = try responseJSON(postResponse)
        XCTAssertEqual(postPayload["method"] as? String, "POST")
        XCTAssertEqual(postPayload["body"] as? String, "payload from Postie")
        XCTAssertEqual(try XCTUnwrap(requestHeader("X-Integration", in: postPayload)), "post")
        try await manager.discardBody(at: postResponse.bodyFileURL)
    }

    func testPreparedStartSendsResolvedRequestAndRetainsOriginalConfiguration() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))
        let configuration = HTTPRequestConfiguration(
            method: "POST",
            url: fixture.baseURL + "/echo",
            headers: [HTTPField(name: "X-Prepared", value: "{{headerValue}}")],
            body: "{{bodyValue}}",
            bodyEnabled: true
        )
        let prepared = try await RequestPreparer.prepare(
            configuration,
            context: VariableContext(request: [
                "headerValue": .plain("resolved header"),
                "bodyValue": .plain("resolved body")
            ]),
            decryptor: nil
        )
        let identity = RequestIdentity(collectionID: UUID(), requestID: configuration.id)

        let response = try completedResponse(in: await collect(try await manager.start(identity: identity, prepared: prepared)))
        let payload = try responseJSON(response)

        XCTAssertEqual(response.request, configuration)
        XCTAssertEqual(payload["body"] as? String, "resolved body")
        XCTAssertEqual(try XCTUnwrap(requestHeader("X-Prepared", in: payload)), "resolved header")
        try await manager.discardBody(at: response.bodyFileURL)
    }

    func testRedirectCanBeDisabledAndFollowed() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))
        let redirectURL = try fixture.url(path: "/redirect", query: [
            URLQueryItem(name: "to", value: "/echo"),
            URLQueryItem(name: "status", value: "302")
        ])

        let stoppedRequest = HTTPRequestConfiguration(url: redirectURL)
        let stoppedEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: stoppedRequest.id),
            configuration: stoppedRequest
        ))
        let stopped = try completedResponse(in: stoppedEvents)
        XCTAssertEqual(stopped.statusCode, 302)
        XCTAssertEqual(stopped.effectiveMethod, "GET")
        XCTAssertFalse(stopped.redirectLimitReached)
        XCTAssertEqual(stopped.redirects.count, 1)
        XCTAssertEqual(stopped.redirects[0].statusCode, 302)
        XCTAssertEqual(stopped.redirects[0].nextURL.path, "/echo")
        XCTAssertTrue(stopped.redirects[0].responseHeaders.contains { $0.name.caseInsensitiveCompare("Location") == .orderedSame })
        try await manager.discardBody(at: stopped.bodyFileURL)

        var followOptions = HTTPOptions()
        followOptions.followRedirects = true
        let followedRequest = HTTPRequestConfiguration(url: redirectURL, options: followOptions)
        let followedEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: followedRequest.id),
            configuration: followedRequest
        ))
        let followed = try completedResponse(in: followedEvents)
        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertEqual(followed.finalURL.path, "/echo")
        XCTAssertEqual(followed.redirects.count, 1)
        try await manager.discardBody(at: followed.bodyFileURL)

        let post302 = HTTPRequestConfiguration(
            method: "POST",
            url: try fixture.url(path: "/redirect", query: [
                URLQueryItem(name: "to", value: "/echo"),
                URLQueryItem(name: "status", value: "302")
            ]),
            body: "redirect payload",
            bodyEnabled: true,
            options: followOptions
        )
        let post302Response = try completedResponse(in: await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: post302.id),
            configuration: post302
        )))
        let post302Payload = try responseJSON(post302Response)
        XCTAssertEqual(post302Response.redirects.first?.method, "POST")
        XCTAssertEqual(post302Response.redirects.first?.nextMethod, "GET")
        XCTAssertEqual(post302Response.effectiveMethod, "GET")
        XCTAssertEqual(post302Payload["method"] as? String, "GET")
        try await manager.discardBody(at: post302Response.bodyFileURL)

        let post307 = HTTPRequestConfiguration(
            method: "POST",
            url: try fixture.url(path: "/redirect", query: [
                URLQueryItem(name: "to", value: "/echo"),
                URLQueryItem(name: "status", value: "307")
            ]),
            body: "redirect payload",
            bodyEnabled: true,
            options: followOptions
        )
        let post307Response = try completedResponse(in: await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: post307.id),
            configuration: post307
        )))
        let post307Payload = try responseJSON(post307Response)
        XCTAssertEqual(post307Response.redirects.first?.method, "POST")
        XCTAssertEqual(post307Response.redirects.first?.nextMethod, "POST")
        XCTAssertEqual(post307Response.effectiveMethod, "POST")
        XCTAssertEqual(post307Payload["method"] as? String, "POST")
        XCTAssertEqual(post307Payload["body"] as? String, "redirect payload")
        try await manager.discardBody(at: post307Response.bodyFileURL)
    }

    func testManualRedirectUsesCapturedMethodAnd307Body() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))

        let post302 = HTTPRequestConfiguration(
            method: "POST",
            url: try fixture.url(path: "/redirect", query: [
                URLQueryItem(name: "to", value: "/echo"),
                URLQueryItem(name: "status", value: "302")
            ]),
            body: "captured 302 body",
            bodyEnabled: true
        )
        let post302Identity = RequestIdentity(collectionID: UUID(), requestID: post302.id)
        let post302Response = try completedResponse(in: await collect(try await manager.start(
            identity: post302Identity,
            configuration: post302
        )))
        XCTAssertEqual(post302Response.redirectRequest?.httpMethod, "GET")
        XCTAssertEqual(post302Response.pendingRedirect?.nextMethod, "GET")
        let post302Follow = try await manager.followRedirect(identity: post302Identity, response: post302Response)
        let post302Result = try completedResponse(in: await collect(post302Follow))
        XCTAssertEqual(post302Result.effectiveMethod, "GET")
        XCTAssertEqual(try responseJSON(post302Result)["method"] as? String, "GET")
        XCTAssertEqual(post302Result.redirects.count, 1, "The pending first hop must not be duplicated by manual continuation.")
        try await manager.discardBody(at: post302Response.bodyFileURL)
        try await manager.discardBody(at: post302Result.bodyFileURL)

        let post307 = HTTPRequestConfiguration(
            method: "POST",
            url: try fixture.url(path: "/redirect", query: [
                URLQueryItem(name: "to", value: "/echo"),
                URLQueryItem(name: "status", value: "307")
            ]),
            body: "captured 307 body",
            bodyEnabled: true
        )
        let post307Identity = RequestIdentity(collectionID: UUID(), requestID: post307.id)
        let post307Response = try completedResponse(in: await collect(try await manager.start(
            identity: post307Identity,
            configuration: post307
        )))
        XCTAssertEqual(post307Response.redirectRequest?.httpMethod, "POST")
        XCTAssertEqual(post307Response.redirectRequest?.httpBody, Data("captured 307 body".utf8))
        let post307Follow = try await manager.followRedirect(identity: post307Identity, response: post307Response)
        let post307Result = try completedResponse(in: await collect(post307Follow))
        let post307Payload = try responseJSON(post307Result)
        XCTAssertEqual(post307Result.effectiveMethod, "POST")
        XCTAssertEqual(post307Payload["method"] as? String, "POST")
        XCTAssertEqual(post307Payload["body"] as? String, "captured 307 body")
        try await manager.discardBody(at: post307Response.bodyFileURL)
        try await manager.discardBody(at: post307Result.bodyFileURL)
    }

    func testManualRedirectPreservesTwoHopChainAndStopsAtTenFollowedHops() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))
        let finalURL = try fixture.url(path: "/echo")
        let secondHop = try fixture.url(path: "/redirect", query: [URLQueryItem(name: "to", value: finalURL)])
        let firstHop = try fixture.url(path: "/redirect", query: [URLQueryItem(name: "to", value: secondHop)])
        let chainedRequest = HTTPRequestConfiguration(url: firstHop)
        let chainedIdentity = RequestIdentity(collectionID: UUID(), requestID: chainedRequest.id)

        let firstResponse = try completedResponse(in: await collect(try await manager.start(
            identity: chainedIdentity,
            configuration: chainedRequest
        )))
        let secondRun = try await manager.followRedirect(identity: chainedIdentity, response: firstResponse)
        try await manager.discardBody(at: firstResponse.bodyFileURL)
        let secondResponse = try completedResponse(in: await collect(secondRun))
        XCTAssertEqual(secondResponse.statusCode, 302)
        XCTAssertEqual(secondResponse.redirects.count, 2)
        XCTAssertEqual(secondResponse.redirects.map { $0.url.absoluteString }, [firstHop, secondHop])

        let finalRun = try await manager.followRedirect(identity: chainedIdentity, response: secondResponse)
        try await manager.discardBody(at: secondResponse.bodyFileURL)
        let finalResponse = try completedResponse(in: await collect(finalRun))
        XCTAssertEqual(finalResponse.finalURL.absoluteString, finalURL)
        XCTAssertEqual(finalResponse.redirects.count, 2)
        try await manager.discardBody(at: finalResponse.bodyFileURL)

        let loopRequest = HTTPRequestConfiguration(url: fixture.baseURL + "/loop")
        let loopIdentity = RequestIdentity(collectionID: UUID(), requestID: loopRequest.id)
        var loopResponse = try completedResponse(in: await collect(try await manager.start(
            identity: loopIdentity,
            configuration: loopRequest
        )))
        for _ in 0..<10 {
            let nextRun = try await manager.followRedirect(identity: loopIdentity, response: loopResponse)
            try await manager.discardBody(at: loopResponse.bodyFileURL)
            loopResponse = try completedResponse(in: await collect(nextRun))
        }
        XCTAssertTrue(loopResponse.redirectLimitReached)
        XCTAssertEqual(loopResponse.redirects.count, 11)
        do {
            _ = try await manager.followRedirect(identity: loopIdentity, response: loopResponse)
            XCTFail("A refused redirect after ten followed hops must not be followable.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("followable redirect"))
        }
        try await manager.discardBody(at: loopResponse.bodyFileURL)
    }

    func testManualRedirectStripsCrossOriginCredentialsAndRejectsUnsupportedLocation() async throws {
        let source = try LocalHTTPFixture()
        let destination = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))
        let destinationURL = try destination.url(path: "/echo")
        let sourceURL = try source.url(path: "/redirect", query: [URLQueryItem(name: "to", value: destinationURL)])
        let request = HTTPRequestConfiguration(
            url: sourceURL,
            headers: [
                HTTPField(name: "Authorization", value: "Bearer fixture-token"),
                HTTPField(name: "Proxy-Authorization", value: "Basic fixture-token"),
                HTTPField(name: "Cookie", value: "session=fixture"),
                HTTPField(name: "Cookie2", value: "legacy=fixture")
            ]
        )
        let identity = RequestIdentity(collectionID: UUID(), requestID: request.id)
        let response = try completedResponse(in: await collect(try await manager.start(identity: identity, configuration: request)))
        for header in ["Authorization", "Proxy-Authorization", "Cookie", "Cookie2"] {
            XCTAssertNil(response.redirectRequest?.value(forHTTPHeaderField: header))
        }

        let followed = try await manager.followRedirect(identity: identity, response: response)
        let destinationResponse = try completedResponse(in: await collect(followed))
        let payload = try responseJSON(destinationResponse)
        for header in ["Authorization", "Proxy-Authorization", "Cookie", "Cookie2"] {
            XCTAssertNil(try requestHeader(header, in: payload), "\(header) must be absent at a different origin.")
        }
        try await manager.discardBody(at: response.bodyFileURL)
        try await manager.discardBody(at: destinationResponse.bodyFileURL)

        var unsupportedOptions = HTTPOptions()
        unsupportedOptions.inactivityTimeout = 1
        unsupportedOptions.overallTimeout = 2
        let unsupportedRequest = HTTPRequestConfiguration(
            url: try source.url(path: "/redirect", query: [URLQueryItem(name: "to", value: "file:///tmp/postie-redirect-target")]),
            options: unsupportedOptions
        )
        let unsupportedIdentity = RequestIdentity(collectionID: UUID(), requestID: unsupportedRequest.id)
        let unsupportedRun = try await manager.start(
            identity: unsupportedIdentity,
            configuration: unsupportedRequest
        )
        guard let unsupportedEvents = await collect(
            unsupportedRun,
            within: 4,
            manager: manager,
            identity: unsupportedIdentity
        ) else {
            XCTFail("The unsupported redirect request did not settle within four seconds; it was cancelled.")
            return
        }
        let unsupportedRedirects = unsupportedEvents.compactMap { event -> HTTPRedirect? in
            guard case .redirect(let redirect) = event else { return nil }
            return redirect
        }
        let unsupportedResponse = unsupportedEvents.compactMap { event -> HTTPResponseRecord? in
            guard case .completed(let response) = event else { return nil }
            return response
        }.first

        // URLSession can reject an unsupported Location before it invokes the redirect delegate.
        if let unsupportedResponse {
            XCTAssertEqual(unsupportedRedirects.count, 1)
            XCTAssertEqual(unsupportedRedirects.first?.nextURL.scheme, "file")
            XCTAssertNil(unsupportedResponse.redirectRequest)
            XCTAssertNil(unsupportedResponse.pendingRedirect)
            do {
                _ = try await manager.followRedirect(identity: unsupportedIdentity, response: unsupportedResponse)
                XCTFail("Non-HTTP redirect destinations must be rejected.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("followable redirect"))
            }
            try await manager.discardBody(at: unsupportedResponse.bodyFileURL)
        } else {
            XCTAssertTrue(unsupportedRedirects.isEmpty, "A refused unsupported destination must not emit a followable redirect.")
            XCTAssertFalse(unsupportedEvents.contains { if case .cancelled = $0 { return true }; return false })
            let safeTerminalFailures = [
                "The request could not be completed. Check the URL and try again.",
                "The request timed out."
            ]
            let failures = failureMessages(in: unsupportedEvents)
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(safeTerminalFailures.contains(failures.first ?? ""), "Unsupported redirects must end with a known safe failure.")
        }
    }

    func testRedirectFollowingStopsAfterTenHopsAndKeepsRefusedResponse() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))
        var options = HTTPOptions()
        options.followRedirects = true
        let request = HTTPRequestConfiguration(url: fixture.baseURL + "/loop", options: options)

        let response = try completedResponse(in: await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: request.id),
            configuration: request
        )))

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertTrue(response.redirectLimitReached)
        XCTAssertEqual(response.redirects.count, 11, "The refused eleventh response remains observable after ten followed hops.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: response.bodyFileURL.path))
        try await manager.discardBody(at: response.bodyFileURL)
    }

    func testCrossOriginRedirectDoesNotForwardSensitiveHeaders() async throws {
        let source = try LocalHTTPFixture()
        let destination = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))
        var redirectComponents = URLComponents(string: source.baseURL + "/redirect")!
        redirectComponents.queryItems = [URLQueryItem(name: "to", value: destination.baseURL + "/echo")]
        var options = HTTPOptions()
        options.followRedirects = true
        let request = HTTPRequestConfiguration(
            url: try XCTUnwrap(redirectComponents.url?.absoluteString),
            headers: [
                HTTPField(name: "Authorization", value: "Bearer fixture-token"),
                HTTPField(name: "Proxy-Authorization", value: "Basic fixture-token"),
                HTTPField(name: "Cookie", value: "session=fixture"),
                HTTPField(name: "Cookie2", value: "legacy=fixture")
            ],
            options: options
        )

        let response = try completedResponse(in: await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: request.id),
            configuration: request
        )))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.redirects.count, 1)
        let payload = try responseJSON(response)
        for name in ["Authorization", "Proxy-Authorization", "Cookie", "Cookie2"] {
            XCTAssertNil(try requestHeader(name, in: payload), "\(name) must be absent at a different origin.")
        }
        try await manager.discardBody(at: response.bodyFileURL)
    }

    func testIdentityIsSingleFlightWhileDifferentIdentitiesRunConcurrently() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))
        let collectionID = UUID()
        let first = HTTPRequestConfiguration(url: try fixture.url(path: "/delay", query: [URLQueryItem(name: "seconds", value: "0.8")]))
        let firstIdentity = RequestIdentity(collectionID: collectionID, requestID: first.id)
        let firstRun = try await manager.start(identity: firstIdentity, configuration: first)
        let firstFinished = CompletionLatch()
        let firstObserver = Task {
            var events: [HTTPExecutionEvent] = []
            for await event in firstRun.events {
                events.append(event)
            }
            await firstFinished.markFinished()
            return events
        }

        do {
            _ = try await manager.start(identity: firstIdentity, configuration: first)
            XCTFail("A second run of the same request identity must be rejected while the first is active.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already running"))
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let second = HTTPRequestConfiguration(url: try fixture.url(path: "/delay", query: [URLQueryItem(name: "seconds", value: "0.1")]))
        let secondRun = try await manager.start(
            identity: RequestIdentity(collectionID: collectionID, requestID: second.id),
            configuration: second
        )
        let secondEvents = await collect(secondRun)
        let secondResponse = try completedResponse(in: secondEvents)
        let didFirstFinishBeforeSecond = await firstFinished.isFinished
        XCTAssertFalse(didFirstFinishBeforeSecond, "The shorter independent run must finish while the first identity is still active.")
        XCTAssertTrue(firstRun.id != secondRun.id)

        let firstEvents = await firstObserver.value
        let firstResponse = try completedResponse(in: firstEvents)
        XCTAssertTrue(firstResponse.duration > secondResponse.duration)
        try await manager.discardBody(at: firstResponse.bodyFileURL)
        try await manager.discardBody(at: secondResponse.bodyFileURL)
    }

    func testCancellationSettlesIdentityForRerunAndDoesNotRetainPartialBody() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        let manager = try HTTPExecutionManager(bodyDirectory: bodyDirectory)
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let slow = HTTPRequestConfiguration(url: try fixture.url(path: "/stream", query: [
            URLQueryItem(name: "bytes", value: "8388608"),
            URLQueryItem(name: "chunk_delay", value: "0.02")
        ]))
        let cancelledRun = try await manager.start(identity: identity, configuration: slow)

        var iterator = cancelledRun.events.makeAsyncIterator()
        while let event = await iterator.next() {
            if case .progress(let progress) = event, progress.receivedBytes > 0 {
                await manager.cancel(identity: identity)
                break
            }
        }
        let cancelledEvents = await collectRemaining(iterator)
        XCTAssertEqual(cancelledEvents.filter { if case .cancelled = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(cancelledEvents.filter { if case .completed = $0 { return true }; return false }.count, 0)

        let rerun = HTTPRequestConfiguration(url: fixture.baseURL + "/echo")
        let rerunRun = try await manager.start(identity: identity, configuration: rerun)
        let rerunEvents = await collect(rerunRun)
        let response = try completedResponse(in: rerunEvents)
        XCTAssertEqual(response.runID, rerunRun.id)
        XCTAssertEqual(rerunEvents.filter { if case .completed = $0 { return true }; return false }.count, 1)
        let bodies = try responseBodyFiles(under: bodyDirectory)
        XCTAssertEqual(
            bodies.map { $0.standardizedFileURL.resolvingSymlinksInPath() },
            [response.bodyFileURL.standardizedFileURL.resolvingSymlinksInPath()]
        )
        try await manager.discardBody(at: response.bodyFileURL)
    }

    func testByteLimitBoundaryAndFailureCleanup() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        let manager = try HTTPExecutionManager(bodyDirectory: bodyDirectory)

        var exactOptions = HTTPOptions()
        exactOptions.maximumResponseBytes = 1024
        let exact = HTTPRequestConfiguration(
            url: try fixture.url(path: "/large", query: [URLQueryItem(name: "bytes", value: "1024")]),
            options: exactOptions
        )
        let exactResponse = try completedResponse(in: await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: exact.id),
            configuration: exact
        )))
        XCTAssertEqual(exactResponse.bodyByteCount, 1024)
        try await manager.discardBody(at: exactResponse.bodyFileURL)

        var cappedOptions = HTTPOptions()
        cappedOptions.maximumResponseBytes = 1023
        let capped = HTTPRequestConfiguration(
            url: try fixture.url(path: "/large", query: [URLQueryItem(name: "bytes", value: "1024")]),
            options: cappedOptions
        )
        let cappedEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: capped.id),
            configuration: capped
        ))
        XCTAssertEqual(failureMessages(in: cappedEvents), ["The response exceeded the configured byte limit."])
        XCTAssertTrue(try responseBodyFiles(under: bodyDirectory).isEmpty)
    }

    func testIdleAndOverallTimeoutsFailWithoutRetainingBodies() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        let manager = try HTTPExecutionManager(bodyDirectory: bodyDirectory)

        var idleOptions = HTTPOptions()
        idleOptions.inactivityTimeout = 0.2
        idleOptions.overallTimeout = nil
        idleOptions.maximumResponseBytes = nil
        let idle = HTTPRequestConfiguration(
            url: try fixture.url(path: "/delay", query: [URLQueryItem(name: "seconds", value: "0.8")]),
            options: idleOptions
        )
        let idleEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: idle.id),
            configuration: idle
        ))
        XCTAssertEqual(failureMessages(in: idleEvents), ["The request timed out."])

        var overallOptions = HTTPOptions()
        overallOptions.inactivityTimeout = 2
        overallOptions.overallTimeout = 0.35
        overallOptions.maximumResponseBytes = nil
        let overall = HTTPRequestConfiguration(
            url: try fixture.url(path: "/stream", query: [
                URLQueryItem(name: "bytes", value: "1048576"),
                URLQueryItem(name: "chunk_delay", value: "0.05")
            ]),
            options: overallOptions
        )
        let overallEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: overall.id),
            configuration: overall
        ))
        XCTAssertEqual(failureMessages(in: overallEvents), ["The request timed out."])
        XCTAssertTrue(try responseBodyFiles(under: bodyDirectory).isEmpty)
    }

    func testLargeChunkedAndBinaryResponsesStayFileBackedWithBoundedPreviews() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root.appendingPathComponent("bodies", isDirectory: true))

        var largeOptions = HTTPOptions()
        largeOptions.maximumResponseBytes = 3 * 1_048_576
        let large = HTTPRequestConfiguration(
            url: try fixture.url(path: "/large", query: [URLQueryItem(name: "bytes", value: "2097152")]),
            options: largeOptions
        )
        let largeEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: large.id),
            configuration: large
        ))
        let largeResponse = try completedResponse(in: largeEvents)
        XCTAssertEqual(largeResponse.bodyByteCount, 2_097_152)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: largeResponse.bodyFileURL.path)[.size] as? NSNumber)?.int64Value, 2_097_152)
        let largePreview = try ResponseBodyReader.preview(at: largeResponse.bodyFileURL, maximumBytes: 1_048_576)
        XCTAssertEqual(largePreview.text.utf8.count, 1_048_576)
        XCTAssertTrue(largePreview.isTruncated)
        XCTAssertFalse(largePreview.isBinary)
        try await manager.discardBody(at: largeResponse.bodyFileURL)

        var chunkedOptions = HTTPOptions()
        chunkedOptions.maximumResponseBytes = nil
        let chunked = HTTPRequestConfiguration(
            url: try fixture.url(path: "/stream", query: [URLQueryItem(name: "bytes", value: "4096")]),
            options: chunkedOptions
        )
        let chunkedEvents = await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: chunked.id),
            configuration: chunked
        ))
        let chunkedResponse = try completedResponse(in: chunkedEvents)
        XCTAssertEqual(chunkedResponse.bodyByteCount, 4096)
        XCTAssertTrue(chunkedEvents.contains { event in
            guard case .progress(let progress) = event else { return false }
            return progress.expectedBytes == nil
        }, "Chunked responses must keep expected progress unknown when the platform reports no length.")
        try await manager.discardBody(at: chunkedResponse.bodyFileURL)

        let binary = HTTPRequestConfiguration(url: fixture.baseURL + "/binary")
        let binaryResponse = try completedResponse(in: await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: binary.id),
            configuration: binary
        )))
        XCTAssertEqual(binaryResponse.bodyByteCount, 1024)
        let binaryPreview = try ResponseBodyReader.preview(at: binaryResponse.bodyFileURL, maximumBytes: 32)
        XCTAssertTrue(binaryPreview.isBinary)
        XCTAssertEqual(binaryPreview.text, "")
        XCTAssertTrue(binaryPreview.isTruncated)
        try await manager.discardBody(at: binaryResponse.bodyFileURL)
    }

    func testManagerRejectsBodyDeletionOutsideItsOwnershipAndDiscardsRetainedFiles() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        let manager = try HTTPExecutionManager(bodyDirectory: bodyDirectory)
        let foreignURL = root.appendingPathComponent("foreign.body")
        try Data("foreign".utf8).write(to: foreignURL)

        do {
            try await manager.discardBody(at: foreignURL)
            XCTFail("The manager must reject files outside its body directory.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a retained response body"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignURL.path))

        let request = HTTPRequestConfiguration(url: fixture.baseURL + "/echo")
        let response = try completedResponse(in: await collect(try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: request.id),
            configuration: request
        )))
        XCTAssertTrue(FileManager.default.fileExists(atPath: response.bodyFileURL.path))
        try await manager.discardBody(at: response.bodyFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: response.bodyFileURL.path))
    }

    func testAbandonedSessionIsCleanedOnRestartWithoutTouchingAnotherOwner() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        var abandonedManager: HTTPExecutionManager? = try HTTPExecutionManager(bodyDirectory: bodyDirectory)
        let abandonedRequest = HTTPRequestConfiguration(url: fixture.baseURL + "/echo")
        let abandonedRun = try await XCTUnwrap(abandonedManager).start(
            identity: RequestIdentity(collectionID: UUID(), requestID: abandonedRequest.id),
            configuration: abandonedRequest
        )
        let abandonedResponse = try completedResponse(in: await collect(abandonedRun))
        let abandonedBody = abandonedResponse.bodyFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandonedBody.path))

        let unrelatedFile = bodyDirectory.appendingPathComponent("unmarked-user-file.bin")
        try Data("preserve".utf8).write(to: unrelatedFile)
        let activeManager = try HTTPExecutionManager(bodyDirectory: bodyDirectory)
        let activeRequest = HTTPRequestConfiguration(url: fixture.baseURL + "/echo")
        let activeResponse = try completedResponse(in: await collect(try await activeManager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: activeRequest.id),
            configuration: activeRequest
        )))
        let activeSession = activeResponse.bodyFileURL.deletingLastPathComponent()

        abandonedManager = nil
        let restartedManager = try HTTPExecutionManager(bodyDirectory: bodyDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedBody.path), "A session with no live owner must be reclaimed on restart.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeResponse.bodyFileURL.path), "A live manager's body must survive another manager's startup sweep.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeSession.path))
        XCTAssertEqual(try Data(contentsOf: unrelatedFile), Data("preserve".utf8))
        try await activeManager.discardBody(at: activeResponse.bodyFileURL)

        let restartedRequest = HTTPRequestConfiguration(url: fixture.baseURL + "/echo")
        let restartedResponse = try completedResponse(in: await collect(try await restartedManager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: restartedRequest.id),
            configuration: restartedRequest
        )))
        try await restartedManager.discardBody(at: restartedResponse.bodyFileURL)
        await restartedManager.shutdown()
        await activeManager.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeSession.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    func testShutdownCancelsActiveRunBeforeRemovingItsSession() async throws {
        let fixture = try LocalHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        let manager = try HTTPExecutionManager(bodyDirectory: bodyDirectory)
        let unrelatedFile = bodyDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelatedFile)
        let request = HTTPRequestConfiguration(url: try fixture.url(path: "/delay", query: [URLQueryItem(name: "seconds", value: "2")]))
        let run = try await manager.start(
            identity: RequestIdentity(collectionID: UUID(), requestID: request.id),
            configuration: request
        )
        let sessionDirectory = try XCTUnwrap(try childDirectories(under: bodyDirectory).first)

        await manager.shutdown()

        let events = await collect(run)
        XCTAssertEqual(events.filter { if case .cancelled = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events.filter { if case .completed = $0 { return true }; return false }.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    private func collect(_ run: HTTPRun) async -> [HTTPExecutionEvent] {
        var events: [HTTPExecutionEvent] = []
        for await event in run.events {
            events.append(event)
        }
        return events
    }

    private func collect(
        _ run: HTTPRun,
        within timeout: TimeInterval,
        manager: HTTPExecutionManager,
        identity: RequestIdentity
    ) async -> [HTTPExecutionEvent]? {
        await withTaskGroup(of: [HTTPExecutionEvent]?.self) { group in
            group.addTask {
                var events: [HTTPExecutionEvent] = []
                for await event in run.events {
                    events.append(event)
                }
                return events
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return nil
                }
                await manager.cancel(identity: identity)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func collectRemaining(_ iterator: AsyncStream<HTTPExecutionEvent>.AsyncIterator) async -> [HTTPExecutionEvent] {
        var iterator = iterator
        var events: [HTTPExecutionEvent] = []
        while let event = await iterator.next() {
            events.append(event)
        }
        return events
    }

    private func completedResponse(in events: [HTTPExecutionEvent]) throws -> HTTPResponseRecord {
        try XCTUnwrap(events.compactMap { event -> HTTPResponseRecord? in
            guard case .completed(let response) = event else { return nil }
            return response
        }.first)
    }

    private func failureMessages(in events: [HTTPExecutionEvent]) -> [String] {
        events.compactMap { event in
            guard case .failed(let message) = event else { return nil }
            return message
        }
    }

    private func responseJSON(_ response: HTTPResponseRecord) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: response.bodyFileURL))
        return try XCTUnwrap(value as? [String: Any])
    }

    private func requestHeader(_ name: String, in payload: [String: Any]) throws -> String? {
        let headers = try XCTUnwrap(payload["headers"] as? [[String]])
        return headers.first { $0.count == 2 && $0[0].caseInsensitiveCompare(name) == .orderedSame }?.last
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieHTTPIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func responseBodyFiles(under directory: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "body" }
    }

    private func childDirectories(under directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    }
}

private final class LocalHTTPFixture {
    private let process: Process
    private let termination: DispatchSemaphore
    let port: Int

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let fixtureExecutable = Bundle(for: HTTPIntegrationTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PostieHTTPFixture")
        let output = Pipe()
        let process = Process()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = fixtureExecutable
        process.arguments = ["--port", "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { @Sendable _ in termination.signal() }
        self.process = process
        self.termination = termination
        try process.run()

        do {
            let line = try Self.readLine(from: output.fileHandleForReading)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Int])
            self.port = try XCTUnwrap(value["port"])
        } catch {
            Self.stop(process: process, termination: termination)
            throw error
        }
    }

    deinit {
        Self.stop(process: process, termination: termination)
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> String {
        var components = URLComponents(string: baseURL + path)
        components?.queryItems = query.isEmpty ? nil : query
        return try XCTUnwrap(components?.url?.absoluteString)
    }

    private static func readLine(from handle: FileHandle) throws -> String {
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: 1) ?? Data()
            guard let byte = chunk.first else { throw FixtureError.didNotStart }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private static func stop(process: Process, termination: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }

        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut,
              process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut,
              process.isRunning else { return }
        XCTFail("The HTTP fixture process did not terminate after SIGKILL.")
    }

    private enum FixtureError: Error {
        case didNotStart
    }
}

private actor CompletionLatch {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}
