package md.remit;

import md.remit.models.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Duration;

import static org.assertj.core.api.Assertions.*;

@DisplayName("MockRemit / Wallet tests")
class WalletTest {

    private MockRemit mock;
    private Wallet wallet;

    @BeforeEach
    void setup() {
        mock = new MockRemit();
        wallet = mock.wallet();
    }

    // ─── Balance ──────────────────────────────────────────────────────────────

    @Test
    @DisplayName("balance returns 10000 USDC by default")
    void testDefaultBalance() {
        Balance b = wallet.balance();
        assertThat(b.usdc).isEqualByComparingTo(BigDecimal.valueOf(10_000));
        assertThat(b.address).isNotBlank();
    }

    @Test
    @DisplayName("setBalance overrides the mock balance")
    void testSetBalance() {
        mock.setBalance(BigDecimal.valueOf(500));
        assertThat(wallet.balance().usdc).isEqualByComparingTo(BigDecimal.valueOf(500));
    }

    // ─── Direct Payment ───────────────────────────────────────────────────────

    @Test
    @DisplayName("pay reduces balance and records transaction")
    void testPay() {
        String recipient = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        Transaction tx = wallet.pay(recipient, BigDecimal.valueOf(1.50));

        assertThat(tx.id).startsWith("tx_");
        assertThat(tx.amount).isEqualByComparingTo(BigDecimal.valueOf(1.50));
        assertThat(tx.to).isEqualToIgnoringCase(recipient);

        // Balance reduced
        assertThat(wallet.balance().usdc).isEqualByComparingTo(BigDecimal.valueOf(9998.50));

        // Mock assertion helpers
        assertThat(mock.wasPaid(recipient, BigDecimal.valueOf(1.50))).isTrue();
        assertThat(mock.totalPaidTo(recipient)).isEqualByComparingTo(BigDecimal.valueOf(1.50));
    }

    @Test
    @DisplayName("pay with memo stores the memo")
    void testPayWithMemo() {
        String recipient = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        Transaction tx = wallet.pay(recipient, BigDecimal.valueOf(2.00), "for the API call");
        assertThat(tx.memo).isEqualTo("for the API call");
    }

    @Test
    @DisplayName("pay throws INSUFFICIENT_FUNDS when balance is too low")
    void testPayInsufficientFunds() {
        mock.setBalance(BigDecimal.valueOf(0.50));
        assertThatThrownBy(() -> wallet.pay("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", BigDecimal.valueOf(1.00)))
            .isInstanceOf(RemitError.class)
            .hasMessageContaining("Insufficient")
            .extracting(e -> ((RemitError) e).getCode())
            .isEqualTo(ErrorCodes.INSUFFICIENT_FUNDS);
    }

    @Test
    @DisplayName("pay throws INVALID_ADDRESS for malformed address")
    void testPayInvalidAddress() {
        assertThatThrownBy(() -> wallet.pay("notanaddress", BigDecimal.valueOf(1.00)))
            .isInstanceOf(RemitError.class)
            .extracting(e -> ((RemitError) e).getCode())
            .isEqualTo(ErrorCodes.INVALID_ADDRESS);
    }

    @Test
    @DisplayName("pay throws INVALID_AMOUNT for zero amount")
    void testPayZeroAmount() {
        assertThatThrownBy(() -> wallet.pay("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", BigDecimal.ZERO))
            .isInstanceOf(RemitError.class)
            .extracting(e -> ((RemitError) e).getCode())
            .isEqualTo(ErrorCodes.INVALID_AMOUNT);
    }

    // ─── Escrow ───────────────────────────────────────────────────────────────

    @Test
    @DisplayName("createEscrow locks funds and returns escrow in funded state")
    void testCreateEscrow() {
        String payee = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        Escrow escrow = wallet.createEscrow(payee, BigDecimal.valueOf(5.00));

        assertThat(escrow.id).startsWith("esc_");
        assertThat(escrow.status).isEqualTo("funded");
        assertThat(escrow.amount).isEqualByComparingTo(BigDecimal.valueOf(5.00));
        assertThat(wallet.balance().usdc).isEqualByComparingTo(BigDecimal.valueOf(9995));
    }

    @Test
    @DisplayName("releaseEscrow transfers funds to payee")
    void testReleaseEscrow() {
        String payee = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        Escrow escrow = wallet.createEscrow(payee, BigDecimal.valueOf(5.00));

        Transaction tx = wallet.releaseEscrow(escrow.id);
        assertThat(tx.to).isEqualToIgnoringCase(payee);
        assertThat(tx.amount).isEqualByComparingTo(BigDecimal.valueOf(5.00));

        Escrow updated = wallet.getEscrow(escrow.id);
        assertThat(updated.status).isEqualTo("released");
    }

    @Test
    @DisplayName("cancelEscrow returns funds to payer")
    void testCancelEscrow() {
        Escrow escrow = wallet.createEscrow(
            "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", BigDecimal.valueOf(5.00));

        BigDecimal balanceBefore = wallet.balance().usdc;
        wallet.cancelEscrow(escrow.id);
        assertThat(wallet.balance().usdc)
            .isEqualByComparingTo(balanceBefore.add(BigDecimal.valueOf(5.00)));

        Escrow updated = wallet.getEscrow(escrow.id);
        assertThat(updated.status).isEqualTo("cancelled");
    }

    @Test
    @DisplayName("getEscrow throws ESCROW_NOT_FOUND for unknown ID")
    void testGetEscrowNotFound() {
        assertThatThrownBy(() -> wallet.getEscrow("esc_doesnotexist"))
            .isInstanceOf(RemitError.class)
            .extracting(e -> ((RemitError) e).getCode())
            .isEqualTo(ErrorCodes.ESCROW_NOT_FOUND);
    }

    // ─── Tab ──────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("createTab + debitTab + settleTab lifecycle")
    void testTabLifecycle() {
        String service = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        Tab tab = wallet.createTab(service, BigDecimal.valueOf(10.00));

        assertThat(tab.id).startsWith("tab_");
        assertThat(tab.status).isEqualTo("open");
        assertThat(tab.used).isEqualByComparingTo(BigDecimal.ZERO);

        // Debit twice
        TabDebit d1 = wallet.debitTab(tab.id, BigDecimal.valueOf(0.003), "API call 1");
        assertThat(d1.cumulative).isEqualByComparingTo(BigDecimal.valueOf(0.003));

        TabDebit d2 = wallet.debitTab(tab.id, BigDecimal.valueOf(0.003), "API call 2");
        assertThat(d2.cumulative).isEqualByComparingTo(BigDecimal.valueOf(0.006));

        // Settle
        Transaction tx = wallet.settleTab(tab.id);
        assertThat(tx.amount).isEqualByComparingTo(BigDecimal.valueOf(0.006));
    }

    @Test
    @DisplayName("debitTab throws TAB_LIMIT_EXCEEDED when over limit")
    void testTabLimitExceeded() {
        String service = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        Tab tab = wallet.createTab(service, BigDecimal.valueOf(1.00));

        assertThatThrownBy(() -> wallet.debitTab(tab.id, BigDecimal.valueOf(2.00), "too much"))
            .isInstanceOf(RemitError.class)
            .extracting(e -> ((RemitError) e).getCode())
            .isEqualTo(ErrorCodes.TAB_LIMIT_EXCEEDED);
    }

    // ─── Bounty ───────────────────────────────────────────────────────────────

    @Test
    @DisplayName("createBounty + awardBounty lifecycle")
    void testBountyLifecycle() {
        Bounty bounty = wallet.createBounty(BigDecimal.valueOf(25.00), "Summarize this research paper");

        assertThat(bounty.id).startsWith("bty_");
        assertThat(bounty.status).isEqualTo("open");
        assertThat(bounty.award).isEqualByComparingTo(BigDecimal.valueOf(25.00));

        String winner = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        Transaction tx = wallet.awardBounty(bounty.id, winner);
        assertThat(tx.to).isEqualToIgnoringCase(winner);
        assertThat(tx.amount).isEqualByComparingTo(BigDecimal.valueOf(25.00));
    }

    // ─── Reset ────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("reset clears all state")
    void testReset() {
        wallet.pay("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", BigDecimal.valueOf(100));
        assertThat(mock.transactionCount()).isEqualTo(1);

        mock.reset();
        assertThat(mock.transactionCount()).isEqualTo(0);
        assertThat(wallet.balance().usdc).isEqualByComparingTo(BigDecimal.valueOf(10_000));
    }

    // ─── Multiple payments ────────────────────────────────────────────────────

    @Test
    @DisplayName("totalPaidTo sums multiple payments to the same recipient")
    void testTotalPaidTo() {
        String recipient = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        wallet.pay(recipient, BigDecimal.valueOf(1.00));
        wallet.pay(recipient, BigDecimal.valueOf(2.00));
        wallet.pay(recipient, BigDecimal.valueOf(3.00));

        assertThat(mock.totalPaidTo(recipient)).isEqualByComparingTo(BigDecimal.valueOf(6.00));
        assertThat(mock.transactionCount()).isEqualTo(3);
    }

    // ─── Analytics ────────────────────────────────────────────────────────────

    @Test
    @DisplayName("remainingBudget returns operator limits")
    void testRemainingBudget() {
        Budget budget = wallet.remainingBudget();
        assertThat(budget.dailyRemaining).isPositive();
        assertThat(budget.perTxLimit).isPositive();
    }

    @Test
    @DisplayName("reputation returns mock score for any address")
    void testReputation() {
        var rep = wallet.reputation("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
        assertThat(rep.score).isBetween(0, 1000);
        assertThat(rep.address).isNotBlank();
    }
}
