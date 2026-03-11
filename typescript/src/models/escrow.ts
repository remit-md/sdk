import type { EscrowStatus } from "./common.js";

export interface Escrow {
  invoiceId: string;
  txHash?: string;
  payer: string;
  payee: string;
  amount: number;
  chain: string;
  status: EscrowStatus;
  milestoneIndex?: number;
  claimStartedAt?: number;
  evidenceUri?: string;
  disputeId?: string;
  createdAt: number;
  expiresAt?: number;
}
