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
