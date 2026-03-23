/** Common enums and shared model types. */

export type ChainId =
  | "base"
  | "base-sepolia";

export type InvoiceStatus =
  | "pending"
  | "funded"
  | "active"
  | "completed"
  | "cancelled"
  | "failed";

export type EscrowStatus =
  | "pending"
  | "funded"
  | "active"
  | "completed"
  | "cancelled"
  | "failed";

export type TabStatus = "open" | "closed" | "expired" | "suspended";

export type StreamStatus = "active" | "paused" | "closed" | "completed" | "cancelled";

export type BountyStatus = "open" | "closed" | "awarded" | "expired" | "cancelled";

export type DepositStatus = "locked" | "returned" | "forfeited" | "expired";

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
  wallet: string;
  balance: string;
  monthly_volume: string;
  tier: string;
  fee_rate_bps: number; // basis points
  active_escrows: number;
  active_tabs: number;
  active_streams: number;
}

/** On-chain reputation profile. */
export interface Reputation {
  address: string;
  score: number;
  totalPaid: number;
  totalReceived: number;
  escrowsCompleted: number;
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

/** One-time operator link returned by createFundLink / createWithdrawLink. */
export interface LinkResponse {
  url: string;
  token: string;
  expiresAt: string;
  walletAddress: string;
}

/** Contract addresses returned by GET /contracts. */
export interface ContractAddresses {
  chain_id: number;
  usdc: string;
  router: string;
  escrow: string;
  tab: string;
  stream: string;
  bounty: string;
  deposit: string;
  fee_calculator: string;
  key_registry: string;
  relayer?: string;
}
