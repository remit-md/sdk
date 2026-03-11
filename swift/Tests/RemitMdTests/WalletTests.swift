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
        XCTAssertEqual(tx.amount, 5.00)
        XCTAssertEqual(tx.to, recipient)
        XCTAssertEqual(tx.status, "confirmed")
        XCTAssertTrue(mock.wasPaid(address: recipient))
        XCTAssertEqual(mock.totalPaid(to: recipient), 5.00, accuracy: 0.001)
    }

    func testPayWithMemo() async throws {
        let tx = try await wallet.pay(to: recipient, amount: 0.003, memo: "API call #42")
        XCTAssertEqual(tx.memo, "API call #42")
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
        XCTAssertEqual(released.status, .released)

        do {
            _ = try await wallet.releaseEscrow(id: escrow.id)
            XCTFail("expected double-release error")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.escrowAlreadyReleased)
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
        let tab = try await wallet.openTab(recipient: recipient, limit: 10.0)
        XCTAssertEqual(tab.status, .open)

        let debit = try await wallet.debitTab(id: tab.id, amount: 3.0, memo: "call 1")
        XCTAssertEqual(debit.amount, 3.0, accuracy: 0.001)
        XCTAssertEqual(debit.spentAfter, 3.0, accuracy: 0.001)

        _ = try await wallet.debitTab(id: tab.id, amount: 4.0)
        let closed = try await wallet.closeTab(id: tab.id)
        XCTAssertEqual(closed.status, .closed)
        XCTAssertEqual(closed.spent, 7.0, accuracy: 0.001)
    }

    func testTabLimitExceeded() async throws {
        let tab = try await wallet.openTab(recipient: recipient, limit: 5.0)
        do {
            _ = try await wallet.debitTab(id: tab.id, amount: 6.0)
            XCTFail("expected limit-exceeded error")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.tabLimitExceeded)
        }
    }

    // MARK: - Stream

    func testStream() async throws {
        let stream = try await wallet.startStream(recipient: recipient, ratePerSecond: 0.001)
        XCTAssertEqual(stream.status, .active)
        XCTAssertEqual(stream.ratePerSecond, 0.001, accuracy: 0.0001)

        let stopped = try await wallet.closeStream(id: stream.id)
        XCTAssertEqual(stopped.status, .ended)
        XCTAssertNotNil(stopped.endedAt)
    }

    // MARK: - Bounty

    func testBountyLifecycle() async throws {
        let bounty = try await wallet.postBounty(amount: 50.0, description: "Summarize this document")
        XCTAssertEqual(bounty.status, .open)

        let awarded = try await wallet.awardBounty(id: bounty.id, winner: recipient)
        XCTAssertEqual(awarded.status, .awarded)
        XCTAssertEqual(awarded.winner, recipient)

        do {
            _ = try await wallet.awardBounty(id: bounty.id, winner: other)
            XCTFail("expected already-awarded error")
        } catch let e as RemitError {
            XCTAssertEqual(e.code, RemitError.bountyAlreadyAwarded)
        }
    }

    // MARK: - Deposit

    func testDeposit() async throws {
        let deposit = try await wallet.lockDeposit(recipient: recipient, amount: 25.0, reason: "collateral")
        XCTAssertEqual(deposit.status, .locked)
        XCTAssertEqual(deposit.amount, 25.0, accuracy: 0.001)
        XCTAssertEqual(deposit.reason, "collateral")
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
