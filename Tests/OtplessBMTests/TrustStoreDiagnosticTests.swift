//
//  TrustStoreDiagnosticTests.swift
//  Temporary diagnostic: does sigma.otpless.app pass PLAIN system TLS (no pinning delegate)?
//

import XCTest

final class TrustStoreDiagnosticTests: XCTestCase {
    func testPlainSystemTrustToSigma() async {
        do {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "https://sigma.otpless.app/")!)
            print("DIAG sigma plain: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        } catch {
            XCTFail("DIAG sigma plain system TLS failed: \(error)")
        }
    }
    func testPlainSystemTrustToUserAuth() async {
        do {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "https://user-auth.otpless.app/")!)
            print("DIAG user-auth plain: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        } catch {
            XCTFail("DIAG user-auth plain system TLS failed: \(error)")
        }
    }
}
