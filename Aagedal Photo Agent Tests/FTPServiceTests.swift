import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("FTPService.curlArguments")
struct FTPCurlArgumentsTests {

    private func makeArgs(_ connection: FTPConnection) -> [String] {
        FTPService.curlArguments(
            localPath: "/tmp/photo.jpg",
            remoteURL: "ftp://example.com:21/incoming/photo.jpg",
            netrcPath: "/tmp/abc.netrc",
            connection: connection
        )
    }

    @Test("plain FTP carries no TLS or insecure flags")
    func plainFTPHasNoTLS() {
        let args = makeArgs(FTPConnection(useSFTP: false, useTLS: false))
        #expect(!args.contains("--ssl-reqd"))
        #expect(!args.contains("--ssl"))
        #expect(!args.contains("--insecure"))
        #expect(args.contains("--ftp-create-dirs"))
    }

    @Test("explicit FTPS requires TLS so a downgrade aborts instead of sending cleartext")
    func ftpsRequiresTLS() {
        let args = makeArgs(FTPConnection(useSFTP: false, useTLS: true))
        #expect(args.contains("--ssl-reqd"))
        #expect(!args.contains("--insecure")) // cert verification stays on by default
        #expect(args.contains("--ftp-create-dirs"))
    }

    @Test("FTPS with insecure cert verification adds --insecure but keeps --ssl-reqd")
    func ftpsInsecureCert() {
        let args = makeArgs(FTPConnection(useSFTP: false, useTLS: true, allowInsecureHostVerification: true))
        #expect(args.contains("--ssl-reqd"))
        #expect(args.contains("--insecure"))
    }

    @Test("SFTP uses neither TLS nor ftp-create-dirs flags")
    func sftpFlags() {
        let secure = makeArgs(FTPConnection(useSFTP: true))
        #expect(!secure.contains("--ssl-reqd"))
        #expect(!secure.contains("--ftp-create-dirs"))
        #expect(!secure.contains("--insecure"))

        let insecure = makeArgs(FTPConnection(useSFTP: true, allowInsecureHostVerification: true))
        #expect(insecure.contains("--insecure"))
    }

    @Test("globbing is disabled so filenames with [] or {} upload literally")
    func globbingDisabled() {
        // curl treats [], {} in URLs as glob patterns by default, which would abort
        // the upload of any file whose name contains those (legal) characters.
        for connection in [
            FTPConnection(useSFTP: false, useTLS: false),
            FTPConnection(useSFTP: false, useTLS: true),
            FTPConnection(useSFTP: true),
        ] {
            #expect(makeArgs(connection).contains("--globoff"))
        }
    }

    @Test("credentials are passed via netrc file, never on the command line")
    func credentialsViaNetrc() {
        let args = makeArgs(FTPConnection(useSFTP: false))
        #expect(args.contains("--netrc-file"))
        #expect(args.contains("/tmp/abc.netrc"))
        // The remote URL is the upload target and must be present.
        #expect(args.contains("ftp://example.com:21/incoming/photo.jpg"))
        // The local file is uploaded with -T.
        let tIndex = args.firstIndex(of: "-T")
        #expect(tIndex != nil)
        if let tIndex { #expect(args[args.index(after: tIndex)] == "/tmp/photo.jpg") }
    }

    @Test("connection test has both connect and overall deadlines")
    func connectionTestHasOverallDeadline() {
        let args = FTPService.testConnectionArguments(
            remoteURL: "ftp://example.com:21/incoming/",
            netrcPath: "/tmp/abc.netrc",
            connection: FTPConnection(host: "example.com")
        )
        #expect(args.contains("--connect-timeout"))
        #expect(args.contains("--max-time"))
    }
}

@Suite("FTPService cancellation")
struct FTPServiceCancellationTests {
    @Test("a pre-cancelled upload exits without launching or crashing Process")
    func preCancelledUpload() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("FTPCancel-\(UUID().uuidString).jpg")
        try Data("test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let task = Task {
            try await FTPService().uploadFile(
                localURL: file,
                connection: FTPConnection(host: "127.0.0.1", port: 1, username: "user"),
                password: "password",
                progressHandler: { _ in }
            )
        }
        task.cancel()

        do {
            try await task.value
            Issue.record("A pre-cancelled upload unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
    }
}

@Suite("FTPService.remoteUploadURL")
struct FTPRemoteURLTests {

    private func url(_ filename: String, _ connection: FTPConnection) -> String {
        FTPService.remoteUploadURL(for: filename, connection: connection)
    }

    @Test("# is encoded so the remote path is not truncated at the fragment")
    func encodesHash() {
        let conn = FTPConnection(host: "example.com", port: 21, remotePath: "/incoming/", useSFTP: false)
        #expect(url("Shot #3.jpg", conn) == "ftp://example.com:21/incoming/Shot%20%233.jpg")
    }

    @Test("? is encoded so it is not split off as a query")
    func encodesQuestionMark() {
        let conn = FTPConnection(host: "h", port: 21, remotePath: "/d/", useSFTP: false)
        #expect(url("a?b.jpg", conn).hasSuffix("/d/a%3Fb.jpg"))
    }

    @Test("brackets, spaces and percent are encoded and round-trip via curl's decode")
    func encodesGlobAndSpecials() {
        let conn = FTPConnection(host: "h", port: 21, remotePath: "/d/", useSFTP: false)
        #expect(url("IMG_[2].jpg", conn).hasSuffix("/d/IMG_%5B2%5D.jpg"))
        #expect(url("50% off {final}.jpg", conn).hasSuffix("/d/50%25%20off%20%7Bfinal%7D.jpg"))
    }

    @Test("scheme is sftp for SFTP connections; plain names are unchanged")
    func schemeAndPlainNames() {
        let sftp = FTPConnection(host: "h", port: 22, remotePath: "/d/", useSFTP: true)
        #expect(url("plain.jpg", sftp) == "sftp://h:22/d/plain.jpg")
    }

    @Test("a missing trailing slash on the remote path is added")
    func addsTrailingSlash() {
        let conn = FTPConnection(host: "h", port: 21, remotePath: "/d", useSFTP: false)
        #expect(url("a.jpg", conn) == "ftp://h:21/d/a.jpg")
    }

    @Test("remote directory specials are encoded while / separators stay intact")
    func encodesRemotePathSpecials() {
        // A space in a remote directory would break the URL, and a '#'/'?' would
        // truncate it at the fragment/query — the directory must be encoded like the
        // filename, but its '/' separators must survive.
        let spaced = FTPConnection(host: "h", port: 21, remotePath: "/My Photos/2026", useSFTP: false)
        #expect(url("a.jpg", spaced) == "ftp://h:21/My%20Photos/2026/a.jpg")

        let hashed = FTPConnection(host: "h", port: 21, remotePath: "/in#box/", useSFTP: false)
        #expect(url("a.jpg", hashed) == "ftp://h:21/in%23box/a.jpg")
    }
}

@Suite("FTPConnection Codable")
struct FTPConnectionCodableTests {

    @Test("legacy JSON without useTLS decodes to useTLS == false")
    func legacyDecodeDefaultsTLSOff() throws {
        let legacy = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"old","host":"h",\
        "port":21,"username":"u","remotePath":"/","useSFTP":false,\
        "allowInsecureHostVerification":false}
        """.data(using: .utf8)!
        let conn = try JSONDecoder().decode(FTPConnection.self, from: legacy)
        #expect(conn.useTLS == false)
        #expect(conn.host == "h")
    }

    @Test("useTLS survives an encode/decode roundtrip")
    func roundtripPreservesTLS() throws {
        let original = FTPConnection(name: "secure", host: "h", useSFTP: false, useTLS: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FTPConnection.self, from: data)
        #expect(decoded.useTLS == true)
        #expect(decoded == original)
    }
}
