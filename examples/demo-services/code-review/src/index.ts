/**
 * Demo Code Review Agent
 *
 * Demonstrates remit.md escrow payments. Charges $2.00 per review.
 *
 * Escrow lifecycle:
 *   1. Client creates invoice via remit.md API (price: $2.00)
 *   2. Client funds escrow on-chain
 *   3. Client calls POST /v1/review with { escrowId, code }
 *   4. This service:
 *      a. Calls remit.md API: POST /api/v0/escrows/{id}/claim-start
 *      b. Performs code review (mock)
 *      c. Calls remit.md API: POST /api/v0/escrows/{id}/submit-evidence
 *      d. Returns the review to the client
 *   5. Client verifies the work and calls release (or disputes)
 */

import express, { Request, Response } from "express";
import { createServer } from "http";
import "dotenv/config";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.PORT ?? "3003", 10);
const REMITMD_API_URL = process.env.REMITMD_API_URL ?? "http://localhost:8080";
const SERVICE_WALLET =
  process.env.CODE_REVIEW_WALLET ??
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"; // Anvil key 2 address (demo only)
const API_KEY = process.env.CODE_REVIEW_API_KEY ?? "demo-api-key";
const PRICE_USD = 2.0;

// ---------------------------------------------------------------------------
// In-memory job state (replace with DB in production)
// ---------------------------------------------------------------------------

type JobStatus = "pending" | "in_progress" | "complete" | "failed";

interface ReviewJob {
  escrowId: string;
  status: JobStatus;
  startedAt?: number;
  completedAt?: number;
  review?: CodeReview;
  error?: string;
}

interface CodeReview {
  summary: string;
  issues: ReviewIssue[];
  suggestions: string[];
  score: number; // 0-100
  evidence_hash: string;
}

interface ReviewIssue {
  severity: "critical" | "high" | "medium" | "low";
  line?: number;
  message: string;
}

const jobs = new Map<string, ReviewJob>();

// ---------------------------------------------------------------------------
// Mock code review
// ---------------------------------------------------------------------------

function reviewCode(code: string): CodeReview {
  const lines = code.split("\n");
  const issues: ReviewIssue[] = [];

  // Detect common patterns
  if (code.includes("eval(")) {
    issues.push({ severity: "critical", message: "Use of eval() is dangerous — remote code execution risk" });
  }
  if (/console\.log/.test(code)) {
    issues.push({ severity: "low", message: "Remove debug console.log statements before production" });
  }
  if (/var /.test(code)) {
    issues.push({ severity: "medium", message: "Use const/let instead of var for proper scoping" });
  }
  if (/\.then\(/.test(code) && /async/.test(code)) {
    issues.push({ severity: "low", message: "Mixing async/await with .then() — prefer consistent style" });
  }
  if (lines.some((l) => l.length > 120)) {
    issues.push({ severity: "low", message: "Lines exceeding 120 characters reduce readability" });
  }
  if (code.includes("TODO") || code.includes("FIXME")) {
    issues.push({ severity: "medium", message: "Unresolved TODO/FIXME comments found — address before merge" });
  }
  if (!/try\s*\{/.test(code) && code.includes("await ")) {
    issues.push({ severity: "high", message: "async operations without try/catch — unhandled rejections possible" });
  }

  const score = Math.max(0, 100 - issues.reduce((sum, i) => {
    const weights = { critical: 40, high: 20, medium: 10, low: 5 };
    return sum + weights[i.severity];
  }, 0));

  const suggestions = [
    "Consider adding unit tests to cover edge cases",
    "Add JSDoc/TSDoc comments to public functions",
    "Extract magic numbers into named constants",
  ].slice(0, Math.max(1, 3 - issues.length));

  // Deterministic evidence hash (in production: IPFS CID of full review)
  const reviewText = JSON.stringify({ issues, suggestions, score });
  const evidence_hash =
    "0x" +
    [...reviewText].reduce((h, c) => ((h << 5) - h + c.charCodeAt(0)) & 0xffffffff, 0)
      .toString(16)
      .padStart(64, "0");

  return {
    summary:
      issues.length === 0
        ? "No issues found. Code looks clean and follows best practices."
        : `Found ${issues.length} issue(s). See details below.`,
    issues,
    suggestions,
    score,
    evidence_hash,
  };
}

// ---------------------------------------------------------------------------
// remit.md API calls
// ---------------------------------------------------------------------------

async function claimStart(escrowId: string): Promise<boolean> {
  try {
    const res = await fetch(`${REMITMD_API_URL}/api/v0/escrows/${escrowId}/claim-start`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${API_KEY}`,
      },
    });
    return res.ok;
  } catch (err) {
    console.error(`[code-review] claim-start failed for ${escrowId}:`, err);
    return false;
  }
}

async function submitEvidence(escrowId: string, evidenceHash: string): Promise<boolean> {
  try {
    const res = await fetch(`${REMITMD_API_URL}/api/v0/escrows/${escrowId}/submit-evidence`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${API_KEY}`,
      },
      body: JSON.stringify({
        evidence_type: "ipfs_hash",
        evidence_value: evidenceHash,
        description: "Code review report — issues and suggestions attached",
      }),
    });
    return res.ok;
  } catch (err) {
    console.error(`[code-review] submit-evidence failed for ${escrowId}:`, err);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Express app
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: "1mb" }));

app.get("/.well-known/remit.json", (_req: Request, res: Response) => {
  res.json({
    agent: SERVICE_WALLET,
    name: "Demo Code Review Agent",
    description: "Automated code review for remit.md demonstration",
    version: "0.1.0",
    services: [
      {
        id: "code_review",
        endpoint: "/v1/review",
        method: "POST",
        price_usd: PRICE_USD,
        price_model: "fixed",
        payment_type: "escrow",
        escrow_address: process.env.ESCROW_ADDRESS ?? "not configured",
        chain_id: parseInt(process.env.CHAIN_ID ?? "84532", 10),
        instructions: "1. Create invoice via remit.md API. 2. Fund escrow. 3. POST /v1/review with escrowId.",
      },
    ],
  });
});

app.get("/health", (_req: Request, res: Response) => {
  res.json({ status: "ok", service: "code-review", wallet: SERVICE_WALLET, jobs: jobs.size });
});

// Get job status
app.get("/v1/review/:escrowId", (req: Request, res: Response) => {
  const job = jobs.get(req.params["escrowId"] ?? "");
  if (!job) {
    res.status(404).json({ error: "NOT_FOUND", message: "No review job for this escrow ID" });
    return;
  }
  res.json(job);
});

// Submit code for review — triggers escrow lifecycle
app.post("/v1/review", async (req: Request, res: Response): Promise<void> => {
  const body = req.body as { escrowId?: string; code?: string };

  if (!body.escrowId || typeof body.escrowId !== "string") {
    res.status(400).json({ error: "INVALID_REQUEST", message: "'escrowId' is required" });
    return;
  }
  if (!body.code || typeof body.code !== "string") {
    res.status(400).json({ error: "INVALID_REQUEST", message: "'code' is required" });
    return;
  }
  if (body.code.length > 50_000) {
    res.status(400).json({ error: "CODE_TOO_LARGE", message: "Code must be ≤50KB" });
    return;
  }

  const { escrowId, code } = body;

  // Idempotency: if already processing or complete, return current state
  const existing = jobs.get(escrowId);
  if (existing?.status === "complete") {
    res.json(existing);
    return;
  }
  if (existing?.status === "in_progress") {
    res.status(202).json({ message: "Review in progress", job: existing });
    return;
  }

  // Create job
  const job: ReviewJob = { escrowId, status: "pending", startedAt: Date.now() };
  jobs.set(escrowId, job);

  // Accept immediately, process async
  res.status(202).json({
    message: "Review accepted — check GET /v1/review/:escrowId for status",
    escrowId,
  });

  // Async review lifecycle
  (async () => {
    job.status = "in_progress";

    // Step 1: claim start (signals to escrow we're working)
    const claimed = await claimStart(escrowId);
    if (!claimed) {
      console.warn(`[code-review] claim-start failed for ${escrowId} — proceeding anyway (demo mode)`);
    }

    // Simulate processing time (500ms–2s)
    await new Promise((r) => setTimeout(r, 500 + Math.random() * 1500));

    // Step 2: perform review
    const review = reviewCode(code);
    job.review = review;

    // Step 3: submit evidence
    const submitted = await submitEvidence(escrowId, review.evidence_hash);
    if (!submitted) {
      console.warn(`[code-review] submit-evidence failed for ${escrowId} — client must release manually`);
    }

    job.status = "complete";
    job.completedAt = Date.now();
    console.log(
      `[code-review] Review complete for ${escrowId}: score=${review.score}, issues=${review.issues.length}`
    );
  })().catch((err: unknown) => {
    job.status = "failed";
    job.error = err instanceof Error ? err.message : String(err);
    console.error(`[code-review] Review failed for ${escrowId}:`, err);
  });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

const server = createServer(app);
server.listen(PORT, () => {
  console.log(`[code-review] Service wallet: ${SERVICE_WALLET}`);
  console.log(`[code-review] Price: $${PRICE_USD} per review (escrow)`);
  console.log(`[code-review] Listening on http://localhost:${PORT}`);
  console.log(`[code-review] remit.md API: ${REMITMD_API_URL}`);
});

export default app;
