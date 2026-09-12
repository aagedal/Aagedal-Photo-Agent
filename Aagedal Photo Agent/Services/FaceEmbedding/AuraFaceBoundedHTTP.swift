import Foundation

/// Ephemeral, no-redirect transport. Response headers and every received chunk are
/// capped before retention; the signed archive's exact length is checked by the installer.
nonisolated enum AuraFaceBoundedHTTP {
    static func limit(for url: URL) throws -> Int {
        if url == AuraFaceComponentStore.descriptorURL { return AuraFaceComponentStore.maximumDescriptorBytes }
        if url == AuraFaceComponentStore.signatureURL { return 89 }
        guard AuraFaceComponentStore.isAllowedDownloadURL(url) else { throw AuraFaceComponentError.invalidServerResponse }
        return Int(AuraFaceComponentStore.maximumArchiveBytes)
    }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> AuraFaceHTTPPayload {
        let transfer = Transfer(url: url, limit: try limit(for: url), configuration: configuration)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start($0) }
        } onCancel: { transfer.cancel() }
    }

    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL
        private let maximum: Int
        private let configuration: URLSessionConfiguration
        private var continuation: CheckedContinuation<AuraFaceHTTPPayload, any Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var bytes = Data()
        private var acceptedResponse = false
        private var finished = false
        private var cancelled = false

        init(url: URL, limit: Int, configuration: URLSessionConfiguration) {
            self.url = url; maximum = limit; self.configuration = configuration
        }

        func start(_ continuation: CheckedContinuation<AuraFaceHTTPPayload, any Error>) {
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }

        func cancel() {
            lock.withLock { cancelled = true }
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<AuraFaceHTTPPayload, any Error>) {
            lock.lock()
            guard !finished, let continuation else { lock.unlock(); return }
            finished = true
            self.continuation = nil
            let session = self.session
            self.session = nil; task = nil
            bytes.removeAll(keepingCapacity: false)
            lock.unlock()
            session?.invalidateAndCancel()
            continuation.resume(with: result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
            finish(.failure(AuraFaceComponentError.redirectedResponse))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url else {
                completionHandler(.cancel); finish(.failure(AuraFaceComponentError.invalidServerResponse)); return
            }
            guard response.expectedContentLength <= Int64(maximum) else {
                completionHandler(.cancel); finish(.failure(AuraFaceComponentError.responseTooLarge)); return
            }
            lock.withLock { acceptedResponse = true }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            guard acceptedResponse, data.count <= maximum - bytes.count else {
                lock.unlock(); finish(.failure(AuraFaceComponentError.responseTooLarge)); return
            }
            bytes.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error { finish(.failure(error)); return }
            lock.lock()
            let accepted = acceptedResponse
            let result = AuraFaceHTTPPayload(data: bytes, statusCode: 200)
            lock.unlock()
            finish(accepted ? .success(result) : .failure(AuraFaceComponentError.invalidServerResponse))
        }
    }
}
