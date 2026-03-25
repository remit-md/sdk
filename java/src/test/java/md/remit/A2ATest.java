package md.remit;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;

@DisplayName("A2A types and helper tests")
class A2ATest {

    // ─── Record construction ──────────────────────────────────────────────────

    @Test
    @DisplayName("Extension record holds fields")
    void testExtension() {
        A2A.Extension ext = new A2A.Extension("https://remit.md/x402", "x402 payments", true);
        assertThat(ext.uri()).isEqualTo("https://remit.md/x402");
        assertThat(ext.description()).isEqualTo("x402 payments");
        assertThat(ext.required()).isTrue();
    }

    @Test
    @DisplayName("Capabilities record holds fields")
    void testCapabilities() {
        A2A.Capabilities cap = new A2A.Capabilities(true, false, true, List.of());
        assertThat(cap.streaming()).isTrue();
        assertThat(cap.pushNotifications()).isFalse();
        assertThat(cap.stateTransitionHistory()).isTrue();
    }

    @Test
    @DisplayName("Skill record holds fields")
    void testSkill() {
        A2A.Skill skill = new A2A.Skill("pay", "Pay", "Send USDC", List.of("payment"));
        assertThat(skill.id()).isEqualTo("pay");
        assertThat(skill.name()).isEqualTo("Pay");
        assertThat(skill.tags()).containsExactly("payment");
    }

    @Test
    @DisplayName("Fees record holds fields")
    void testFees() {
        A2A.Fees fees = new A2A.Fees(100, 50, 10000);
        assertThat(fees.standardBps()).isEqualTo(100);
        assertThat(fees.preferredBps()).isEqualTo(50);
        assertThat(fees.cliffUsd()).isEqualTo(10000);
    }

    @Test
    @DisplayName("TaskStatus record holds fields")
    void testTaskStatus() {
        A2A.TaskStatus status = new A2A.TaskStatus("completed", null);
        assertThat(status.state()).isEqualTo("completed");
        assertThat(status.message()).isNull();
    }

    @Test
    @DisplayName("ArtifactPart record holds data")
    void testArtifactPart() {
        A2A.ArtifactPart part = new A2A.ArtifactPart("data", Map.of("txHash", "0xabc"));
        assertThat(part.kind()).isEqualTo("data");
        assertThat(part.data()).containsKey("txHash");
    }

    @Test
    @DisplayName("Task record holds fields")
    void testTask() {
        A2A.Task task = new A2A.Task(
            "task-1",
            new A2A.TaskStatus("completed", null),
            List.of()
        );
        assertThat(task.id()).isEqualTo("task-1");
        assertThat(task.status().state()).isEqualTo("completed");
    }

    // ─── getTaskTxHash ────────────────────────────────────────────────────────

    @Test
    @DisplayName("getTaskTxHash extracts txHash from artifacts")
    void testGetTaskTxHashFound() {
        A2A.Task task = new A2A.Task(
            "task-1",
            new A2A.TaskStatus("completed", null),
            List.of(new A2A.Artifact("result", List.of(
                new A2A.ArtifactPart("data", Map.of("txHash", "0xabc123"))
            )))
        );
        assertThat(A2A.getTaskTxHash(task)).isEqualTo("0xabc123");
    }

    @Test
    @DisplayName("getTaskTxHash returns null when no txHash")
    void testGetTaskTxHashNotFound() {
        A2A.Task task = new A2A.Task(
            "task-2",
            new A2A.TaskStatus("completed", null),
            List.of(new A2A.Artifact("result", List.of(
                new A2A.ArtifactPart("data", Map.of("other", "value"))
            )))
        );
        assertThat(A2A.getTaskTxHash(task)).isNull();
    }

    @Test
    @DisplayName("getTaskTxHash returns null for empty artifacts")
    void testGetTaskTxHashEmpty() {
        A2A.Task task = new A2A.Task(
            "task-3",
            new A2A.TaskStatus("completed", null),
            List.of()
        );
        assertThat(A2A.getTaskTxHash(task)).isNull();
    }

    @Test
    @DisplayName("getTaskTxHash returns null for null artifacts")
    void testGetTaskTxHashNull() {
        A2A.Task task = new A2A.Task(
            "task-4",
            new A2A.TaskStatus("completed", null),
            null
        );
        assertThat(A2A.getTaskTxHash(task)).isNull();
    }

    // ─── SendOptions ──────────────────────────────────────────────────────────

    @Test
    @DisplayName("SendOptions two-arg constructor")
    void testSendOptionsTwoArg() {
        A2A.SendOptions opts = new A2A.SendOptions("0xRecipient", 1.50);
        assertThat(opts.to()).isEqualTo("0xRecipient");
        assertThat(opts.amount()).isEqualTo(1.50);
        assertThat(opts.memo()).isEmpty();
        assertThat(opts.mandate()).isNull();
    }

    @Test
    @DisplayName("SendOptions three-arg constructor")
    void testSendOptionsThreeArg() {
        A2A.SendOptions opts = new A2A.SendOptions("0xRecipient", 2.00, "test memo");
        assertThat(opts.to()).isEqualTo("0xRecipient");
        assertThat(opts.amount()).isEqualTo(2.00);
        assertThat(opts.memo()).isEqualTo("test memo");
    }

    @Test
    @DisplayName("SendOptions full constructor with mandate")
    void testSendOptionsWithMandate() {
        A2A.IntentMandate mandate = new A2A.IntentMandate(
            "m-1", "2026-12-31", "0xissuer", Map.of("maxAmount", "100", "currency", "USDC")
        );
        A2A.SendOptions opts = new A2A.SendOptions("0xRecipient", 5.00, "with mandate", mandate);
        assertThat(opts.mandate()).isNotNull();
        assertThat(opts.mandate().mandateId()).isEqualTo("m-1");
    }

    // ─── IntentMandate ────────────────────────────────────────────────────────

    @Test
    @DisplayName("IntentMandate holds fields")
    void testIntentMandate() {
        A2A.IntentMandate m = new A2A.IntentMandate(
            "m-123", "2026-12-31T23:59:59Z", "0xIssuer",
            Map.of("maxAmount", "1000", "currency", "USDC")
        );
        assertThat(m.mandateId()).isEqualTo("m-123");
        assertThat(m.expiresAt()).isEqualTo("2026-12-31T23:59:59Z");
        assertThat(m.issuer()).isEqualTo("0xIssuer");
        assertThat(m.allowance()).containsKeys("maxAmount", "currency");
    }

    // ─── Client construction ──────────────────────────────────────────────────

    @Test
    @DisplayName("Client constructor with valid endpoint")
    void testClientConstruction() {
        // We cannot test real RPC calls, but we can verify construction succeeds.
        // Use a mock signer.
        md.remit.signer.Signer signer = new md.remit.signer.Signer() {
            @Override
            public byte[] sign(byte[] digest) { return new byte[65]; }
            @Override
            public String address() { return "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; }
        };
        A2A.Client client = new A2A.Client("https://remit.md/a2a", signer, 8453, null);
        assertThat(client).isNotNull();
    }

    @Test
    @DisplayName("Client.fromCard with AgentCard")
    void testClientFromCard() {
        md.remit.signer.Signer signer = new md.remit.signer.Signer() {
            @Override
            public byte[] sign(byte[] digest) { return new byte[65]; }
            @Override
            public String address() { return "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; }
        };
        A2A.AgentCard card = new A2A.AgentCard(
            "0.1", "Remit", "Payment agent", "https://remit.md/a2a", "1.0",
            "https://remit.md/docs", null, null, null
        );
        A2A.Client client = A2A.Client.fromCard(card, signer);
        assertThat(client).isNotNull();
    }
}
