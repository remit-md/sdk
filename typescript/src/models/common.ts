/** Common enums and shared model types. */

export type ChainId =
  | "base"
  | "base-sepolia"
  | "arbitrum"
  | "arbitrum-sepolia"
  | "optimism"
  | "optimism-sepolia"
  | "ethereum"
  | "sepolia";

export type InvoiceStatus =
  | "pending"
  | "funded"
  | "active"
  | "completed"
  | "cancelled"
  | "disputed"
  | "failed";

export type EscrowStatus =
  | "pending"
  | "funded"
  | "active"
  | "completed"
  | "cancelled"
  | "disputed"
  | "failed";

export type TabStatus = "open" | "closed" | "expired" | "suspended";

export type StreamStatus = "active" | "paused" | "closed" | "completed" | "cancelled";

export type BountyStatus = "open" | "closed" | "awarded" | "expired" | "cancelled";

export type DepositStatus = "locked" | "returned" | "forfeited" | "expired";

export type DisputeStatus = "open" | "under_review" | "resolved" | "closed";

export type SubscriptionStatus = "active" | "paused" | "cancelled" | "expired";

export type ReputationTier = "new" | "trusted" | "verified" | "elite";

/** Result of a write operation. */
export interface Transaction {
  invoiceId?: string;
  txHash?: string;
  chain: string;
  status: string;
  createdAt: number; // unix timestamp
}

/** Wallet status including balance and tier info. */
export interface WalletStatus {
  address: string;
  chain: string;
  usdcBalance: number;
  tier: string;
  monthlyVolume: number;
  feeRateBps: number; // basis points
}

/** On-chain reputation profile. */
export interface Reputation {
  address: string;
  score: number;
  totalPaid: number;
  totalReceived: number;
  escrowsCompleted: number;
  escrowsDisputed: number;
  disputeRate: number;
  memberSince: number; // unix timestamp
}

/** Webhook/polling event. */
export interface RemitEvent {
  id: string;
  type: string;
  chain: string;
  wallet: string;
  payload: Record<string, unknown>;
  createdAt: number;
}

/** Registered webhook endpoint. */
export interface Webhook {
  id: string;
  wallet: string;
  url: string;
  events: string[];
  chains: string[];
  active: boolean;
  createdAt: number;
}
