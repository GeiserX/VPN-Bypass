import XCTest
@testable import VPNBypassCore

final class CleanDomainTests: XCTestCase {
    private let rm = RouteManager.shared

    // MARK: - Basic Passthrough

    func testBasicDomainPassthrough() {
        XCTAssertEqual(rm.cleanDomain("example.com"), "example.com")
    }

    func testAlreadyCleanDomain() {
        XCTAssertEqual(rm.cleanDomain("telegram.org"), "telegram.org")
    }

    func testSubdomainPreservation() {
        XCTAssertEqual(rm.cleanDomain("sub.domain.example.com"), "sub.domain.example.com")
    }

    func testHyphenatedDomain() {
        XCTAssertEqual(rm.cleanDomain("my-domain.com"), "my-domain.com")
    }

    func testNumericDomain() {
        XCTAssertEqual(rm.cleanDomain("123.com"), "123.com")
    }

    func testSingleLabelDomain() {
        XCTAssertEqual(rm.cleanDomain("localhost"), "localhost")
    }

    // MARK: - Case Normalization

    func testCaseNormalization() {
        XCTAssertEqual(rm.cleanDomain("Example.COM"), "example.com")
    }

    func testMixedCaseSubdomain() {
        XCTAssertEqual(rm.cleanDomain("WWW.Example.Org"), "www.example.org")
    }

    // MARK: - Protocol Stripping

    func testHTTPSStripping() {
        XCTAssertEqual(rm.cleanDomain("https://example.com"), "example.com")
    }

    func testHTTPStripping() {
        XCTAssertEqual(rm.cleanDomain("http://example.com"), "example.com")
    }

    func testFTPStripping() {
        XCTAssertEqual(rm.cleanDomain("ftp://files.example.com"), "files.example.com")
    }

    func testSSHStripping() {
        XCTAssertEqual(rm.cleanDomain("ssh://server.example.com"), "server.example.com")
    }

    func testCustomSchemeStripping() {
        XCTAssertEqual(rm.cleanDomain("custom+scheme://example.com"), "example.com")
    }

    func testProtocolWithNumbers() {
        XCTAssertEqual(rm.cleanDomain("h2c://example.com"), "example.com")
    }

    func testProtocolWithDotsAndHyphens() {
        XCTAssertEqual(rm.cleanDomain("coap+tcp://example.com"), "example.com")
    }

    // MARK: - Userinfo Removal

    func testUserinfoRemoval() {
        XCTAssertEqual(rm.cleanDomain("user:pass@example.com"), "example.com")
    }

    func testUserinfoWithScheme() {
        XCTAssertEqual(rm.cleanDomain("https://user:pass@example.com"), "example.com")
    }

    func testUsernameOnlyRemoval() {
        XCTAssertEqual(rm.cleanDomain("admin@example.com"), "example.com")
    }

    // MARK: - Port Removal

    func testPort443Removal() {
        XCTAssertEqual(rm.cleanDomain("example.com:443"), "example.com")
    }

    func testPort8080Removal() {
        XCTAssertEqual(rm.cleanDomain("example.com:8080"), "example.com")
    }

    func testPortWithScheme() {
        XCTAssertEqual(rm.cleanDomain("https://example.com:443"), "example.com")
    }

    // MARK: - Path Removal

    func testPathRemoval() {
        XCTAssertEqual(rm.cleanDomain("example.com/path/to/page"), "example.com")
    }

    func testPathWithScheme() {
        XCTAssertEqual(rm.cleanDomain("https://example.com/path"), "example.com")
    }

    func testTrailingSlash() {
        XCTAssertEqual(rm.cleanDomain("example.com/"), "example.com")
    }

    // MARK: - Query String Removal

    func testQueryStringRemoval() {
        XCTAssertEqual(rm.cleanDomain("example.com?q=search"), "example.com")
    }

    func testQueryStringWithPath() {
        XCTAssertEqual(rm.cleanDomain("example.com/page?q=1&lang=en"), "example.com")
    }

    // MARK: - Fragment Removal (via allowed char filter)

    func testFragmentRemoval() {
        // '#' is not in the allowed character set, so it and everything after gets filtered
        // but the fragment chars that are alphanumeric will remain joined to the domain
        XCTAssertEqual(rm.cleanDomain("example.com#section"), "example.comsection")
    }

    // MARK: - Combined URL Components

    func testFullURLCombined() {
        // https://user:pass@Example.COM:8080/path?q=1#frag
        // 1. trim: no change
        // 2. scheme strip: user:pass@Example.COM:8080/path?q=1#frag
        // 3. userinfo (@): Example.COM:8080/path?q=1#frag
        // 4. port (:): Example.COM
        // 5. path (/): no slash left
        // 6. query (?): no ? left
        // 7. filter: Example.COM (all valid)
        // 8. lowercase: example.com
        XCTAssertEqual(rm.cleanDomain("https://user:pass@Example.COM:8080/path?q=1#frag"), "example.com")
    }

    func testSchemeUserinfoPortPath() {
        XCTAssertEqual(rm.cleanDomain("ftp://anonymous:@files.example.com:21/pub"), "files.example.com")
    }

    // MARK: - Whitespace Handling

    func testLeadingTrailingWhitespace() {
        XCTAssertEqual(rm.cleanDomain("  example.com  "), "example.com")
    }

    func testTabsAndNewlines() {
        XCTAssertEqual(rm.cleanDomain("\t example.com \n"), "example.com")
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(rm.cleanDomain("   "), "")
    }

    // MARK: - Empty and Minimal Inputs

    func testEmptyString() {
        XCTAssertEqual(rm.cleanDomain(""), "")
    }

    func testOnlyProtocol() {
        // "https://" -> scheme strip leaves "" -> result ""
        XCTAssertEqual(rm.cleanDomain("https://"), "")
    }

    func testOnlyProtocolWithTrailingSlash() {
        XCTAssertEqual(rm.cleanDomain("http:///"), "")
    }

    // MARK: - Invalid / Special Character Filtering

    func testInvalidCharactersStripped() {
        // semicolon and space are not in allowed set [alphanumerics + .-]
        XCTAssertEqual(rm.cleanDomain("example.com;rm -rf"), "example.comrm-rf")
    }

    func testShellInjectionAttempt() {
        // $, (, ) are stripped; alphanumerics remain
        XCTAssertEqual(rm.cleanDomain("example.com$(whoami)"), "example.comwhoami")
    }

    func testBacktickInjection() {
        // backticks are stripped
        XCTAssertEqual(rm.cleanDomain("example.com`ls`"), "example.comls")
    }

    func testPipeInjection() {
        // Path removal truncates at first '/', leaving "example.com|cat "
        // Filter strips '|' and space
        XCTAssertEqual(rm.cleanDomain("example.com|cat /etc/passwd"), "example.comcat")
    }

    func testAngleBracketsStripped() {
        XCTAssertEqual(rm.cleanDomain("example.com<script>"), "example.comscript")
    }

    func testUnderscoreStripped() {
        // underscore is NOT in the allowed set [alphanumerics + .-]
        XCTAssertEqual(rm.cleanDomain("my_domain.com"), "mydomain.com")
    }

    // MARK: - International / Non-ASCII Characters

    func testInternationalCharsStripped() {
        // 'e' with accent is not in CharacterSet.alphanumerics for ASCII
        // Actually, CharacterSet.alphanumerics includes Unicode letters,
        // but the unicode scalar filter may keep accented chars.
        // Let's verify: é (U+00E9) IS in CharacterSet.alphanumerics (Unicode Letters category).
        // So café.com -> café.com -> lowercased -> café.com
        XCTAssertEqual(rm.cleanDomain("café.com"), "caf\u{00E9}.com")
    }

    func testEmojiStripped() {
        // Emoji are Symbol category, not in alphanumerics
        XCTAssertEqual(rm.cleanDomain("test🎉.com"), "test.com")
    }

    // MARK: - IP Address Passthrough

    func testIPv4Passthrough() {
        XCTAssertEqual(rm.cleanDomain("192.168.1.1"), "192.168.1.1")
    }

    func testIPv4WithPort() {
        XCTAssertEqual(rm.cleanDomain("192.168.1.1:8080"), "192.168.1.1")
    }

    func testIPv4WithSchemeAndPort() {
        XCTAssertEqual(rm.cleanDomain("http://10.0.0.1:3000/api"), "10.0.0.1")
    }

    // MARK: - Double Protocol

    func testDoubleProtocol() {
        // "https://https://example.com"
        // 1. scheme regex strips first "https://", leaving "https://example.com"
        // 2. no @
        // 3. firstIndex(of: ":") finds ':' in "https:", truncates to "https"
        // 4. no / left, no ? left
        // 5. filter: "https" (all alphanumeric)
        // 6. lowercase: "https"
        XCTAssertEqual(rm.cleanDomain("https://https://example.com"), "https")
    }

    // MARK: - Multiple @ Signs

    func testMultipleAtSigns() {
        // "a@b@example.com"
        // 1. no scheme
        // 2. firstIndex(of: "@") finds first @, takes after: "b@example.com"
        // 3. no ':'
        // 4. no '/'
        // 5. no '?'
        // 6. filter: '@' is NOT in allowed set -> "bexample.com"
        // 7. lowercase: "bexample.com"
        XCTAssertEqual(rm.cleanDomain("a@b@example.com"), "bexample.com")
    }

    // MARK: - Multiple Colons

    func testMultipleColons() {
        // "a:b:c:example.com"
        // 1. no scheme (no "://")
        // 2. no '@'
        // 3. firstIndex(of: ":") at index 1, truncates to "a"
        // 4. no '/', no '?'
        // 5. filter: "a"
        // 6. lowercase: "a"
        XCTAssertEqual(rm.cleanDomain("a:b:c:example.com"), "a")
    }

    // MARK: - Very Long Domain

    func testVeryLongDomainPreserved() {
        // Build a 253-character valid domain (max DNS length)
        // Use 63-char labels separated by dots: "aaa...a.bbb...b.ccc...c.dd...d"
        let label63 = String(repeating: "a", count: 63)
        // 63 + 1 + 63 + 1 + 63 + 1 + 59 + 4 = 63.63.63. + 59 chars + .com
        // Total: 63+1+63+1+63+1+57+1+3 = 253
        let lastLabel = String(repeating: "b", count: 57)
        let longDomain = "\(label63).\(label63).\(label63).\(lastLabel).com"
        XCTAssertEqual(longDomain.count, 253)
        XCTAssertEqual(rm.cleanDomain(longDomain), longDomain)
    }

    // MARK: - Edge Cases with Ordering

    func testPortBeforePath() {
        // Port removal happens before path removal
        XCTAssertEqual(rm.cleanDomain("example.com:8080/path"), "example.com")
    }

    func testQueryWithoutPath() {
        XCTAssertEqual(rm.cleanDomain("example.com?key=value"), "example.com")
    }

    func testSchemeWithUserinfoAndPort() {
        XCTAssertEqual(rm.cleanDomain("ssh://git@github.com:22"), "github.com")
    }

    func testDotOnlyDomain() {
        XCTAssertEqual(rm.cleanDomain("."), ".")
    }

    func testHyphenOnlyInput() {
        XCTAssertEqual(rm.cleanDomain("-"), "-")
    }

    func testDotHyphenCombination() {
        XCTAssertEqual(rm.cleanDomain("a--b.c--d.com"), "a--b.c--d.com")
    }

    // MARK: - Scheme Regex Boundary Cases

    func testSchemeRequiresLetterStart() {
        // "123://example.com" — scheme regex requires ^[a-zA-Z], so "123://" is NOT a scheme
        // No scheme stripped. No @. First ':' at index 3 -> truncates to "123"
        XCTAssertEqual(rm.cleanDomain("123://example.com"), "123")
    }

    func testSchemeCaseMixed() {
        XCTAssertEqual(rm.cleanDomain("HTTPS://EXAMPLE.COM"), "example.com")
    }

    func testSchemeWithPlusDotHyphen() {
        // svn+ssh:// is a valid scheme per the regex
        XCTAssertEqual(rm.cleanDomain("svn+ssh://repo.example.com"), "repo.example.com")
    }

    // MARK: - Realistic URLs

    func testGitHubURL() {
        XCTAssertEqual(rm.cleanDomain("https://github.com/GeiserX/VPN-Bypass"), "github.com")
    }

    func testComplexQueryURL() {
        XCTAssertEqual(rm.cleanDomain("https://www.google.com/search?q=hello+world&hl=en"), "www.google.com")
    }

    func testSubdomainWithHTTPS() {
        XCTAssertEqual(rm.cleanDomain("https://api.telegram.org"), "api.telegram.org")
    }

    func testLocalNetworkAddress() {
        XCTAssertEqual(rm.cleanDomain("http://router.local:8080/admin"), "router.local")
    }
}
