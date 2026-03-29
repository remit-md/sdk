import XCTest
@testable import RemitMd

final class X402Tests: XCTestCase {

    func testAllowanceExceededErrorContainsAmounts() {
        let err = AllowanceExceededError(amountUsdc: 1.5, limitUsdc: 0.1)
        XCTAssertEqual(err.amountUsdc, 1.5, accuracy: 0.001)
        XCTAssertEqual(err.limitUsdc, 0.1, accuracy: 0.001)
    }

    func testAllowanceExceededErrorDescription() {
        let err = AllowanceExceededError(amountUsdc: 1.5, limitUsdc: 0.1)
        let msg = err.description
        XCTAssertTrue(msg.contains("1.5") || msg.contains("1.50"))
        XCTAssertTrue(msg.contains("0.1") || msg.contains("0.10"))
    }

    func testX402ClientCanBeCreated() {
        let mock = MockRemit()
        let signer = MockSigner()
        let transport = MockTransport(mock: mock)
        let client = X402Client(signer: signer, address: signer.address, apiTransport: transport)
        XCTAssertNotNil(client)
    }

    func testX402ClientCustomLimit() {
        let mock = MockRemit()
        let signer = MockSigner()
        let transport = MockTransport(mock: mock)
        let client = X402Client(signer: signer, address: signer.address, maxAutoPayUsdc: 5.0, apiTransport: transport)
        XCTAssertEqual(client.maxAutoPayUsdc, 5.0, accuracy: 0.001)
    }
}
