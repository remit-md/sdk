package examples;

import md.remit.MockRemit;
import md.remit.RemitMd;
import md.remit.Wallet;
import md.remit.models.Escrow;
import md.remit.models.Transaction;

import java.math.BigDecimal;

/**
 * Quick start example - run with MockRemit (no credentials required).
 *
 * To use the live API, replace mock.wallet() with:
 *   Wallet wallet = RemitMd.fromEnv();  // set REMITMD_KEY env var
 */
public class QuickStart {

    public static void main(String[] args) {
        // ─── Use MockRemit for testing (zero network) ───────────────────────
        MockRemit mock = new MockRemit();
        Wallet wallet = mock.wallet();

        String recipient = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";

        // Direct payment
        Transaction payment = wallet.pay(recipient, new BigDecimal("1.50"), "for the API call");
        System.out.println("Paid: " + payment.amount + " USDC → " + payment.to);

        // Escrow for task completion
        Escrow escrow = wallet.createEscrow(recipient, new BigDecimal("5.00"), "code review");
        System.out.println("Escrow created: " + escrow.id + " (status: " + escrow.status + ")");

        // Release after verifying work
        wallet.releaseEscrow(escrow.id);
        System.out.println("Escrow released → " + recipient);

        // Verify via mock assertions
        System.out.println("Payments made: " + mock.transactionCount());
        System.out.println("Total paid to recipient: " + mock.totalPaidTo(recipient) + " USDC");

        // ─── Live API usage ─────────────────────────────────────────────────
        // Wallet live = RemitMd.fromEnv();  // requires REMITMD_KEY
        // Wallet live = RemitMd.withKey("0x...").chain("base").testnet(true).build();
    }
}
