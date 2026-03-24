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
  monthlyVolume: string;
  tier: string;
  feeRateBps: number; // basis points
  activeEscrows: number;
  activeTabs: number;
  activeStreams: number;
  /** Current EIP-2612 permit nonce for this wallet. Null if RPC unavailable server-side. */
  permitNonce: number | null;
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
  chainId: number;
  usdc: string;
  router: string;
  escrow: string;
  tab: string;
  stream: string;
  bounty: string;
  deposit: string;
  feeCalculator: string;
  keyRegistry: string;
  relayer?: string;
}
