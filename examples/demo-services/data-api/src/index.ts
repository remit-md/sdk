/**
 * Demo Data API Service
 *
 * Demonstrates remit.md metered tab payments. Charges $0.01 per query.
 * Returns synthetic market/weather/financial data for demo purposes.
 */

import express, { Request, Response, NextFunction } from "express";
import { ethers } from "ethers";
import { createServer } from "http";
import "dotenv/config";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.PORT ?? "3002", 10);
const WALLET_PRIVATE_KEY =
  process.env.DATA_API_PRIVATE_KEY ??
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // Anvil key 1 (demo only)
const CHAIN_ID = parseInt(process.env.CHAIN_ID ?? "84532", 10);
const PRICE_USD = 0.01;
const PRICE_UNITS = BigInt(10000); // 10000 μUSDC = $0.01

const wallet = new ethers.Wallet(WALLET_PRIVATE_KEY);
const SERVICE_ADDRESS = wallet.address;

// ---------------------------------------------------------------------------
// Tab voucher verification (shared logic — identical to llm-api)
// ---------------------------------------------------------------------------

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
  const now = Math.floor(Date.now() / 1000);
  if (parseInt(voucher.deadline) < now) return { valid: false, error: "Voucher expired" };
  if (voucher.payee.toLowerCase() !== SERVICE_ADDRESS.toLowerCase())
    return { valid: false, error: `Wrong payee: expected ${SERVICE_ADDRESS}` };
  if (BigInt(voucher.amount) < PRICE_UNITS)
    return { valid: false, error: `Insufficient amount: need ${PRICE_UNITS}` };

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
  } catch {
    return { valid: false, error: "Invalid signature" };
  }
}

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
      message: "Include a signed tab voucher in X-RemitMD-Voucher header",
      price_usd: PRICE_USD,
      payee: SERVICE_ADDRESS,
      chain_id: CHAIN_ID,
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
    res.status(402).json({ error: "INVALID_VOUCHER", message: result.error });
    return;
  }

  req.voucher = voucher;
  req.callerAddress = result.signer;
  next();
}

// ---------------------------------------------------------------------------
// Synthetic data generators
// ---------------------------------------------------------------------------

type DatasetType = "prices" | "weather" | "sentiment" | "metrics";

function generatePrices(query: string): object {
  const seed = query.length;
  return {
    dataset: "crypto_prices",
    timestamp: new Date().toISOString(),
    data: [
      { symbol: "ETH", price_usd: 3200 + (seed * 7) % 500, change_24h: -2.3 + (seed % 10) * 0.5 },
      { symbol: "BTC", price_usd: 67000 + (seed * 13) % 5000, change_24h: 1.2 + (seed % 8) * 0.3 },
      { symbol: "USDC", price_usd: 1.0001, change_24h: 0.01 },
    ],
    source: "demo-data-api",
  };
}

function generateWeather(query: string): object {
  const cities = ["San Francisco", "New York", "London", "Tokyo", "Sydney"];
  const seed = query.length % cities.length;
  return {
    dataset: "weather",
    timestamp: new Date().toISOString(),
    location: cities[seed],
    data: {
      temperature_c: 15 + (seed * 3),
      humidity_pct: 60 + (seed * 5),
      conditions: ["Clear", "Cloudy", "Rainy", "Sunny", "Partly Cloudy"][seed],
      wind_kmh: 10 + (seed * 4),
    },
    source: "demo-data-api",
  };
}

function generateSentiment(query: string): object {
  return {
    dataset: "sentiment_analysis",
    timestamp: new Date().toISOString(),
    query,
    results: {
      score: 0.72 - (query.length * 0.01) % 0.5,
      label: query.length % 2 === 0 ? "positive" : "neutral",
      confidence: 0.85,
      topics: ["technology", "finance", "innovation"].slice(0, (query.length % 3) + 1),
    },
    source: "demo-data-api",
  };
}

function generateMetrics(_query: string): object {
  return {
    dataset: "api_metrics",
    timestamp: new Date().toISOString(),
    data: {
      requests_per_second: 1247,
      p50_latency_ms: 12,
      p95_latency_ms: 48,
      p99_latency_ms: 142,
      error_rate_pct: 0.03,
      active_connections: 4821,
    },
    source: "demo-data-api",
  };
}

function queryDataset(type: DatasetType, query: string): object {
  switch (type) {
    case "prices": return generatePrices(query);
    case "weather": return generateWeather(query);
    case "sentiment": return generateSentiment(query);
    case "metrics": return generateMetrics(query);
  }
}

// ---------------------------------------------------------------------------
// Express app
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json());

app.get("/.well-known/remit.json", (_req: Request, res: Response) => {
  res.json({
    agent: SERVICE_ADDRESS,
    name: "Demo Data API",
    description: "Synthetic data endpoint for remit.md demonstration",
    version: "0.1.0",
    services: [
      {
        id: "data_query",
        endpoint: "/v1/query",
        method: "GET",
        price_usd: PRICE_USD,
        price_model: "per_call",
        payment_type: "metered",
        tab_address: process.env.TAB_ADDRESS ?? "not configured",
        chain_id: CHAIN_ID,
        datasets: ["prices", "weather", "sentiment", "metrics"],
      },
    ],
  });
});

app.get("/health", (_req: Request, res: Response) => {
  res.json({ status: "ok", service: "data-api", wallet: SERVICE_ADDRESS });
});

app.get(
  "/v1/query",
  requireTabPayment as express.RequestHandler,
  (req: AuthenticatedRequest, res: Response) => {
    const type = (req.query["type"] as DatasetType | undefined) ?? "prices";
    const query = (req.query["q"] as string | undefined) ?? "";

    const validTypes: DatasetType[] = ["prices", "weather", "sentiment", "metrics"];
    if (!validTypes.includes(type)) {
      res.status(400).json({
        error: "INVALID_DATASET",
        message: `Unknown dataset type '${type}'. Valid types: ${validTypes.join(", ")}`,
      });
      return;
    }

    const data = queryDataset(type, query);
    res.json({
      ...data,
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

const server = createServer(app);
server.listen(PORT, () => {
  console.log(`[data-api] Service wallet: ${SERVICE_ADDRESS}`);
  console.log(`[data-api] Price: $${PRICE_USD} per query (${PRICE_UNITS} μUSDC)`);
  console.log(`[data-api] Listening on http://localhost:${PORT}`);
  console.log(`[data-api] Available datasets: prices, weather, sentiment, metrics`);
});

export default app;
