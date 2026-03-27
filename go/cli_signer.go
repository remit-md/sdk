package remitmd

import (
	"bytes"
	"context"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// CliSigner implements Signer by delegating to the `remit sign` CLI subprocess.
// The CLI holds the encrypted keystore; this adapter only needs the binary on
// PATH and the REMIT_KEY_PASSWORD env var set.
//
// Create with NewCliSigner, which fetches and caches the wallet address:
//
//	signer, err := remitmd.NewCliSigner()
//	wallet, err := remitmd.NewWalletWithSigner(signer)
type CliSigner struct {
	cliPath string
	address common.Address
}

// cliTimeout is the maximum time allowed for a CLI subprocess call.
const cliTimeout = 10 * time.Second

// NewCliSigner creates a CliSigner by running `remit address` to fetch
// and cache the wallet address. The CLI must be on PATH (or specify a
// custom path), the keystore must exist, and REMIT_KEY_PASSWORD must be set.
func NewCliSigner(cliPath ...string) (*CliSigner, error) {
	path := "remit"
	if len(cliPath) > 0 && cliPath[0] != "" {
		path = cliPath[0]
	}

	ctx, cancel := context.WithTimeout(context.Background(), cliTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, path, "address")
	out, err := cmd.Output()
	if err != nil {
		return nil, remitErr(ErrCodeUnauthorized,
			fmt.Sprintf("CliSigner: failed to get address from CLI: %s", err),
			map[string]any{"cli_path": path},
		)
	}

	addr := strings.TrimSpace(string(out))
	if !strings.HasPrefix(addr, "0x") || len(addr) != 42 {
		return nil, remitErr(ErrCodeUnauthorized,
			fmt.Sprintf("CliSigner: invalid address from CLI: %s", addr),
			map[string]any{"cli_path": path},
		)
	}

	return &CliSigner{
		cliPath: path,
		address: common.HexToAddress(addr),
	}, nil
}

// Sign sends the digest to `remit sign --digest` via stdin and returns
// the 65-byte signature.
func (c *CliSigner) Sign(digest [32]byte) ([]byte, error) {
	hexInput := "0x" + hex.EncodeToString(digest[:])

	ctx, cancel := context.WithTimeout(context.Background(), cliTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, c.cliPath, "sign", "--digest")
	cmd.Stdin = bytes.NewReader([]byte(hexInput))

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		errMsg := strings.TrimSpace(stderr.String())
		if errMsg == "" {
			errMsg = err.Error()
		}
		return nil, remitErr(ErrCodeUnauthorized,
			fmt.Sprintf("CliSigner: signing failed: %s", errMsg),
			nil,
		)
	}

	sigHex := strings.TrimSpace(stdout.String())
	if !strings.HasPrefix(sigHex, "0x") || len(sigHex) != 132 {
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("CliSigner: invalid signature from CLI: %s", sigHex),
			nil,
		)
	}

	sigBytes, err := hex.DecodeString(sigHex[2:])
	if err != nil {
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("CliSigner: invalid signature hex: %s", err),
			nil,
		)
	}
	if len(sigBytes) != 65 {
		return nil, remitErr(ErrCodeServerError,
			fmt.Sprintf("CliSigner: expected 65-byte signature, got %d bytes", len(sigBytes)),
			map[string]any{"length": len(sigBytes)},
		)
	}

	return sigBytes, nil
}

// Address returns the cached Ethereum address of the signing key.
func (c *CliSigner) Address() common.Address {
	return c.address
}

// String returns a safe representation.
func (c *CliSigner) String() string {
	return fmt.Sprintf("CliSigner{address: %s}", c.address.Hex())
}

// IsCliSignerAvailable checks all three conditions for CliSigner activation:
//  1. `remit` (or `remit.exe`) found on PATH
//  2. Keystore file exists at ~/.remit/keys/default.enc
//  3. REMIT_KEY_PASSWORD env var is set (non-empty)
func IsCliSignerAvailable(cliPath ...string) bool {
	path := "remit"
	if len(cliPath) > 0 && cliPath[0] != "" {
		path = cliPath[0]
	}

	// Check 1: CLI on PATH
	if _, err := exec.LookPath(path); err != nil {
		return false
	}

	// Check 2: Keystore exists
	home, err := os.UserHomeDir()
	if err != nil {
		return false
	}
	keystorePath := filepath.Join(home, ".remit", "keys", "default.enc")
	if _, err := os.Stat(keystorePath); os.IsNotExist(err) {
		return false
	}

	// Check 3: Password available
	if os.Getenv("REMIT_KEY_PASSWORD") == "" {
		return false
	}

	return true
}

// cliInstallHint returns platform-specific install instructions for the CLI.
func cliInstallHint() string {
	switch runtime.GOOS {
	case "darwin":
		return "brew install remit-md/tap/remit"
	case "windows":
		return "winget install remit-md.remit"
	default:
		return "curl -fsSL https://remit.md/install.sh | sh"
	}
}
