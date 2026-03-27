package md.remit.signer;

import md.remit.ErrorCodes;
import md.remit.RemitError;
import org.junit.jupiter.api.*;

import static org.junit.jupiter.api.Assertions.*;

@DisplayName("CliSigner")
class CliSignerTest {

    // ─── isAvailable ──────────────────────────────────────────────────────────────

    @Test
    @DisplayName("isAvailable returns false when REMIT_KEY_PASSWORD is not set")
    void testIsAvailableNoPassword() {
        // In CI/test environments, REMIT_KEY_PASSWORD is typically not set.
        // If it IS set, this test is a no-op (we can't unset env vars in Java).
        String password = System.getenv("REMIT_KEY_PASSWORD");
        if (password == null || password.isEmpty()) {
            assertFalse(CliSigner.isAvailable());
        }
    }

    @Test
    @DisplayName("isAvailable returns false with non-existent CLI path")
    void testIsAvailableNonExistentCli() {
        assertFalse(CliSigner.isAvailable("/nonexistent/path/to/remit-fake-binary"));
    }

    // ─── create failures ──────────────────────────────────────────────────────────

    @Test
    @DisplayName("create throws UNAUTHORIZED with non-existent CLI path")
    void testCreateNonExistentCli() {
        RemitError error = assertThrows(RemitError.class, () ->
            CliSigner.create("/nonexistent/path/to/remit-fake-binary")
        );
        assertEquals(ErrorCodes.UNAUTHORIZED, error.getCode());
        assertTrue(error.getMessage().contains("failed to start"));
    }

    @Test
    @DisplayName("create(cliPath) error includes install hint")
    void testCreateErrorHasInstallHint() {
        RemitError error = assertThrows(RemitError.class, () ->
            CliSigner.create("/nonexistent/path/to/remit-fake-binary")
        );
        assertNotNull(error.getDetails().get("hint"));
        String hint = (String) error.getDetails().get("hint");
        // Should contain an install command for some platform
        assertTrue(
            hint.contains("brew install") || hint.contains("winget install") || hint.contains("curl"),
            "Install hint should contain a platform-specific install command"
        );
    }
}
