/**
 * Demo LLM API Service
 *
 * Demonstrates remit.md metered tab payments. Charges $0.003 per call.
 * The caller must have an open tab with this service's wallet as payee.
 *
 * Each request includes a signed tab voucher authorizing the charge.
 * This service verifies the signature and (in production) submits it
 * to the remit.md API. For demo purposes, signature verification is
 * done locally — no live contract interaction required.
 */

import express, { Request, Response, NextFunction } from "express";
import { ethers } from "ethers";
import { createServer } from "http";
import "dotenv/config";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.PORT ?? "3001", 10);
const WALLET_PRIVATE_KEY =
  process.env.LLM_API_PRIVATE_KEY ??
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // Anvil key 0 (demo only)
const CHAIN_ID = parseInt(process.env.CHAIN_ID ?? "84532", 10); // Base Sepolia
const PRICE_USD = 0.003; // $0.003 per call
const PRICE_UNITS = BigInt(3000); // 3000 μUSDC (6 decimals = $0.003)
const REMITMD_API_URL =
  process.env.REMITMD_API_URL ?? "http://localhost:8080";

const wallet = new ethers.Wallet(WALLET_PRIVATE_KEY);
const SERVICE_ADDRESS = wallet.address;

// ---------------------------------------------------------------------------
// Tab voucher verification
// ---------------------------------------------------------------------------

// EIP-712 domain + types matching RemitTab.sol
const EIP712_DOMAIN = {
  name: "RemitTab",
  version: "1",
  chainId: CHAIN_ID,
  verifyingContract: process.env.TAB_ADDRESS ?? ethers.ZeroAddress,
};

const VOUCHER_TYPES = {
  TabVoucher: [
    { name: "tabId", type: "bytes32" },
    { name: "payee", type: "address" },
    { name: "amount", type: "uint96" },
    { name: "nonce", type: "uint64" },
    { name: "deadline", type: "uint64" },
  ],
};

interface TabVoucher {
  tabId: string;
  payee: string;
  amount: string;
  nonce: string;
  deadline: string;
  signature: string;
}

async function verifyVoucher(
  voucher: TabVoucher
): Promise<{ valid: boolean; error?: string; signer?: string }> {
  // Check deadline
  const now = Math.floor(Date.now() / 1000);
  if (parseInt(voucher.deadline) < now) {
    return { valid: false, error: "Voucher expired" };
  }

  // Check payee matches our wallet
  if (voucher.payee.toLowerCase() !== SERVICE_ADDRESS.toLowerCase()) {
    return {
      valid: false,
      error: `Wrong payee: expected ${SERVICE_ADDRESS}, got ${voucher.payee}`,
    };
  }

  // Check amount matches price
  if (BigInt(voucher.amount) < PRICE_UNITS) {
    return {
      valid: false,
      error: `Insufficient amount: need ${PRICE_UNITS}, got ${voucher.amount}`,
    };
  }

  // Recover signer from EIP-712 signature
  try {
    const recovered = ethers.verifyTypedData(
      EIP712_DOMAIN,
      VOUCHER_TYPES,
      {
        tabId: voucher.tabId,
        payee: voucher.payee,
        amount: BigInt(voucher.amount),
        nonce: BigInt(voucher.nonce),
        deadline: BigInt(voucher.deadline),
      },
      voucher.signature
    );
    return { valid: true, signer: recovered };
  } catch (err) {
    return { valid: false, error: "Invalid signature" };
  }
}

// ---------------------------------------------------------------------------
// Middleware: verify tab voucher on each request
// ---------------------------------------------------------------------------

interface AuthenticatedRequest extends Request {
  voucher?: TabVoucher;
  callerAddress?: string;
}

async function requireTabPayment(
  req: AuthenticatedRequest,
  res: Response,
  next: NextFunction
): Promise<void> {
  const authHeader = req.headers["x-remitmd-voucher"];
  if (!authHeader || typeof authHeader !== "string") {
    res.status(402).json({
      error: "PAYMENT_REQUIRED",
      message:
        "Include a signed tab voucher in X-RemitMD-Voucher header (JSON-encoded TabVoucher)",
      price_usd: PRICE_USD,
      payee: SERVICE_ADDRESS,
      chain_id: CHAIN_ID,
      tab_address: process.env.TAB_ADDRESS ?? "not configured",
    });
    return;
  }

  let voucher: TabVoucher;
  try {
    voucher = JSON.parse(authHeader) as TabVoucher;
  } catch {
    res.status(400).json({ error: "INVALID_VOUCHER", message: "Voucher must be valid JSON" });
    return;
  }

  const result = await verifyVoucher(voucher);
  if (!result.valid) {
    res.status(402).json({
      error: "INVALID_VOUCHER",
      message: result.error,
    });
    return;
  }

  req.voucher = voucher;
  req.callerAddress = result.signer;
  next();
}

// ---------------------------------------------------------------------------
// Mock LLM responses
// ---------------------------------------------------------------------------

const MOCK_RESPONSES = [
  "Based on my analysis, the optimal solution involves a multi-step approach that balances efficiency with accuracy.",
  "The data suggests three key patterns: temporal clustering, feature correlation, and distributional shift.",
  "I recommend implementing a caching layer with TTL-based invalidation to reduce latency by approximately 40%.",
  "The root cause appears to be a race condition in the concurrent processing pipeline. A mutex at line 142 should resolve it.",
  "Given the constraints, a greedy algorithm achieves O(n log n) — optimal for this problem class.",
  "The architecture should be event-driven with CQRS separation to handle the anticipated 10x traffic spike.",
  "Key risks: dependency on third-party API availability, latency variance under load, and cold-start overhead.",
  "The refactored implementation reduces cyclomatic complexity from 23 to 7, improving testability significantly.",
];

function mockGenerate(prompt: string): string {
  // Deterministic mock: hash the prompt to pick a response
  let hash = 0;
  for (const char of prompt) hash = (hash * 31 + char.charCodeAt(0)) & 0xffffffff;
  return MOCK_RESPONSES[Math.abs(hash) % MOCK_RESPONSES.length];
}

// ---------------------------------------------------------------------------
// Express app
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json());

// Service manifest
app.get("/.well-known/remit.json", (_req: Request, res: Response) => {
  res.json({
    agent: SERVICE_ADDRESS,
    name: "Demo LLM API",
    description: "Mock LLM endpoint for remit.md demonstration",
    version: "0.1.0",
    services: [
      {
        id: "llm_generate",
        endpoint: "/v1/generate",
        method: "POST",
        price_usd: PRICE_USD,
        price_model: "per_call",
        payment_type: "metered",
        tab_address: process.env.TAB_ADDRESS ?? "not configured",
        chain_id: CHAIN_ID,
      },
    ],
  });
});

// Health check
app.get("/health", (_req: Request, res: Response) => {
  res.json({ status: "ok", service: "llm-api", wallet: SERVICE_ADDRESS });
});

// Main endpoint — requires tab payment
app.post(
  "/v1/generate",
  requireTabPayment as express.RequestHandler,
  (req: AuthenticatedRequest, res: Response) => {
    const { prompt } = req.body as { prompt?: string };

    if (!prompt || typeof prompt !== "string") {
      res.status(400).json({ error: "INVALID_REQUEST", message: "'prompt' is required" });
      return;
    }

    const response = mockGenerate(prompt);
    const tokensIn = Math.ceil(prompt.length / 4);
    const tokensOut = Math.ceil(response.length / 4);

    res.json({
      id: `gen_${Date.now()}`,
      object: "text_completion",
      model: "remitmd-demo-v1",
      choices: [{ text: response, finish_reason: "stop" }],
      usage: {
        prompt_tokens: tokensIn,
        completion_tokens: tokensOut,
        total_tokens: tokensIn + tokensOut,
      },
      payment: {
        charged_usd: PRICE_USD,
        charged_units: PRICE_UNITS.toString(),
        tab_id: req.voucher!.tabId,
        nonce: req.voucher!.nonce,
        payer: req.callerAddress,
      },
    });
  }
);

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const server = createServer(app);
server.listen(PORT, () => {
  console.log(`[llm-api] Service wallet: ${SERVICE_ADDRESS}`);
  console.log(`[llm-api] Price: $${PRICE_USD} per call (${PRICE_UNITS} μUSDC)`);
  console.log(`[llm-api] Listening on http://localhost:${PORT}`);
  console.log(`[llm-api] Manifest: http://localhost:${PORT}/.well-known/remit.json`);
});

export default app;
