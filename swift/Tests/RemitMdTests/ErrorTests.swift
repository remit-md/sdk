import XCTest
@testable import RemitMd

final class ErrorTests: XCTestCase {

    func testRemitErrorHasCodeAndMessage() {
        let err = RemitError(code: "TEST_CODE", message: "test message")
        XCTAssertEqual(err.code, "TEST_CODE")
        XCTAssertEqual(err.message, "test message")
    }

    func testRemitErrorDescription() {
        let err = RemitError(code: "INVALID_ADDRESS", message: "bad addr")
        let desc = err.description
        XCTAssertTrue(desc.contains("INVALID_ADDRESS"))
    }

    func testErrorCodesAreStableStrings() {
        XCTAssertEqual(RemitError.invalidSignature, "INVALID_SIGNATURE")
        XCTAssertEqual(RemitError.insufficientBalance, "INSUFFICIENT_BALANCE")
        XCTAssertEqual(RemitError.escrowExpired, "ESCROW_EXPIRED")
        XCTAssertEqual(RemitError.tabDepleted, "TAB_DEPLETED")
        XCTAssertEqual(RemitError.tabExpired, "TAB_EXPIRED")
        XCTAssertEqual(RemitError.bountyExpired, "BOUNTY_EXPIRED")
    }

    func testInvalidAddressRejectedBeforeNetwork() async {
        let mock = MockRemit()
        let wallet = RemitWallet(mock: mock)
        do {
            _ = try await wallet.pay(to: "not-an-address", amount: 1.0)
            XCTFail("Expected error")
        } catch let err as RemitError {
            XCTAssertEqual(err.code, RemitError.invalidAddress)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
