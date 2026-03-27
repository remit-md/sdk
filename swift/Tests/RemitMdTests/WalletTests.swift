import XCTest
@testable import RemitMd

final class WalletTests: XCTestCase {
    var mock: MockRemit!
    var wallet: RemitWallet!

    let recipient = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"
    let other    = "0x1234567890123456789012345678901234567890"

    override func setUp() {
        mock = MockRemit()
        wallet = RemitWallet(mock: mock)
        mock.setBalance(1000.0, for: mock.walletAddress)
    }

    override func tearDown() {
        mock.reset()
    }

    // MARK: - Direct payment

    func testPay() async throws {
        let tx = try await wallet.pay(to: recipient, amount: 5.00)
        XCTAssertEqual(tx.status, "confirmed")
        XCTAssertNotNil(tx.txHash)
        XCTAssertTrue(mock.wasPaid(address: recipient))
        XCTAssertEqual(mock.totalPaid(to: recipient), 5.00, accuracy: 0.001)
    }

    func testPayWithMemo() async throws {
        let tx = try await wallet.pay(to: recipient, amount: 0.003, memo: "API call #42")
        XCTAssertEqual(tx.status, "confirmed")
    }

    func testPayMultiple() async throws {
        try await wallet.pay(to: recipient, amount: 1.00)
        try await wallet.pay(to: recipient, amount: 2.00)
        try await wallet.pay(to: other, amount: 0.50)
        XCTAssertEqual(mock.totalPaid(to: recipient), 3.00, accuracy: 0.001)
        XCTAssertEqual(mock.transactionCount(), 3)
    }

    // MARK: - Validation errors

    func testInvalidAddress() async {
        do {
            _ = try await wallet.pay(to: "not-an-address", amount: 1.0)
            XCTFail("expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.invalidAddress)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testZeroAmount() async {
        do {
            _ = try await wallet.pay(to: recipient, amount: 0)
            XCTFail("expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.invalidAmount)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testNegativeAmount() async {
        do {
            _ = try await wallet.pay(to: recipient, amount: -5.0)
            XCTFail("expected RemitError")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.invalidAmount)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Balance

    func testBalance() async throws {
        mock.setBalance(42.50, for: mock.walletAddress)
        let bal = try await wallet.balance()
        XCTAssertEqual(bal.balance, 42.50, accuracy: 0.001)
        XCTAssertEqual(bal.currency, "USDC")
    }

    // MARK: - Escrow lifecycle

    func testEscrowLifecycle() async throws {
        let escrow = try await wallet.createEscrow(
            recipient: recipient, amount: 100.0, conditions: "task complete"
        )
        XCTAssertEqual(escrow.status, .pending)
        XCTAssertEqual(escrow.amount, 100.0, accuracy: 0.001)

        let released = try await wallet.releaseEscrow(id: escrow.id)
        XCTAssertEqual(released.status, .completed)

        do {
            _ = try await wallet.releaseEscrow(id: escrow.id)
            XCTFail("expected double-release error")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.escrowAlreadyCompleted)
        }
    }

    func testEscrowCancel() async throws {
        let escrow = try await wallet.createEscrow(recipient: recipient, amount: 50.0)
        let cancelled = try await wallet.cancelEscrow(id: escrow.id)
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testEscrowNotFound() async {
        do {
            _ = try await wallet.getEscrow(id: "escrow_nonexistent")
            XCTFail("expected not-found error")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.escrowNotFound)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Tab lifecycle

    func testTabLifecycle() async throws {
        let tab = try await wallet.openTab(provider: recipient, limitAmount: 10.0, perUnit: 0.10)
        XCTAssertEqual(tab.status, .open)

        let charge = try await wallet.chargeTab(id: tab.id, amount: 3.0, cumulative: 3.0,
                                                 callCount: 1, providerSig: "0xdead")
        XCTAssertEqual(charge.amount, 3.0, accuracy: 0.001)
        XCTAssertEqual(charge.tabId, tab.id)

        _ = try await wallet.chargeTab(id: tab.id, amount: 4.0, cumulative: 7.0,
                                        callCount: 2, providerSig: "0xbeef")
        let closed = try await wallet.closeTab(id: tab.id, finalAmount: 7.0, providerSig: "0xfeed")
        XCTAssertEqual(closed.status, .closed)
        XCTAssertEqual(closed.spent, 7.0, accuracy: 0.001)
    }

    func testTabLimitExceeded() async throws {
        let tab = try await wallet.openTab(provider: recipient, limitAmount: 5.0, perUnit: 0.10)
        do {
            _ = try await wallet.chargeTab(id: tab.id, amount: 6.0, cumulative: 6.0,
                                            callCount: 1, providerSig: "0xdead")
            XCTFail("expected limit-exceeded error")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.tabLimitExceeded)
        }
    }

    // MARK: - Stream

    func testStream() async throws {
        let stream = try await wallet.startStream(payee: recipient, ratePerSecond: 0.001, maxTotal: 5.0)
        XCTAssertEqual(stream.status, .active)
        XCTAssertEqual(stream.ratePerSecond, 0.001, accuracy: 0.0001)

        let stopped = try await wallet.closeStream(id: stream.id)
        XCTAssertEqual(stopped.status, .closed)
        XCTAssertNotNil(stopped.closedAt)
    }

    // MARK: - Bounty

    func testBountyLifecycle() async throws {
        let deadline = Int(Date().timeIntervalSince1970) + 3600
        let bounty = try await wallet.postBounty(amount: 50.0, taskDescription: "Summarize this document",
                                                  deadline: deadline)
        XCTAssertEqual(bounty.status, .open)

        let sub = try await wallet.submitBounty(id: bounty.id, evidenceUri: "ipfs://deadbeef")
        XCTAssertEqual(sub.bountyId, bounty.id)

        let awarded = try await wallet.awardBounty(id: bounty.id, submissionId: sub.id)
        XCTAssertEqual(awarded.status, .awarded)

        do {
            _ = try await wallet.awardBounty(id: bounty.id, submissionId: 999)
            XCTFail("expected already-awarded error")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.bountyAlreadyAwarded)
        }
    }

    // MARK: - Deposit

    func testDeposit() async throws {
        let deposit = try await wallet.placeDeposit(provider: recipient, amount: 25.0, expiresIn: 3600)
        XCTAssertEqual(deposit.status, .locked)
        XCTAssertEqual(deposit.amount, 25.0, accuracy: 0.001)

        let returned = try await wallet.returnDeposit(id: deposit.id)
        XCTAssertEqual(returned.status, "confirmed")
    }

    // MARK: - Reputation

    func testReputation() async throws {
        mock.setReputation(0.85, for: mock.walletAddress)
        let rep = try await wallet.reputation()
        XCTAssertEqual(rep.score, 0.85, accuracy: 0.001)
    }

    func testReputationDefault() async throws {
        let rep = try await wallet.reputation(of: recipient)
        XCTAssertGreaterThan(rep.score, 0)
        XCTAssertLessThanOrEqual(rep.score, 1)
    }

    // MARK: - Analytics

    func testSpendingSummary() async throws {
        let summary = try await wallet.spendingSummary()
        XCTAssertGreaterThanOrEqual(summary.totalSpent, 0)
        XCTAssertEqual(summary.currency, "USDC")
    }

    func testHistory() async throws {
        _ = try await wallet.pay(to: recipient, amount: 1.0)
        _ = try await wallet.pay(to: other, amount: 2.0)
        let history = try await wallet.history()
        XCTAssertEqual(history.transactions.count, 2)
    }

    func testBudget() async throws {
        let budget = try await wallet.budget()
        XCTAssertGreaterThan(budget.dailyLimit, 0)
        XCTAssertEqual(budget.currency, "USDC")
    }

    // MARK: - Mock reset

    func testReset() async throws {
        _ = try await wallet.pay(to: recipient, amount: 1.0)
        XCTAssertEqual(mock.transactionCount(), 1)
        mock.reset()
        XCTAssertEqual(mock.transactionCount(), 0)
        XCTAssertFalse(mock.wasPaid(address: recipient))
    }

    // MARK: - Custom signer injection (V24 C1)

    func testInitWithCustomSigner() {
        // MockSigner conforms to Signer protocol - verify it works with init(signer:)
        let customSigner = MockSigner(address: "0x1111111111111111111111111111111111111111")
        let customWallet = RemitWallet(signer: customSigner, chain: .baseSepolia)
        XCTAssertEqual(customWallet.address, "0x1111111111111111111111111111111111111111")
    }

    func testInitWithPrivateKeySignerViaProtocol() throws {
        // Verify PrivateKeySigner works via the new init(signer:) path too
        let signer = try PrivateKeySigner(privateKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
        let customWallet = RemitWallet(signer: signer, chain: .baseSepolia)
        XCTAssertEqual(customWallet.address, "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")
    }

    func testExistingPrivateKeyInitStillWorks() throws {
        // Ensure the original init(privateKey:) still functions
        let wallet = try RemitWallet(
            privateKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
            chain: .baseSepolia
        )
        XCTAssertEqual(wallet.address, "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")
    }

    // MARK: - Keccak256 known-answer test

    func testKeccak256KnownAnswer() {
        // keccak256("") = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        let emptyHash = keccak256(Data())
        XCTAssertEqual(emptyHash.hexString,
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

        // keccak256("hello") = 1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
        let helloHash = keccak256(Data("hello".utf8))
        XCTAssertEqual(helloHash.hexString,
            "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    }
}
