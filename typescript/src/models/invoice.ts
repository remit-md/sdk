import type { InvoiceStatus } from "./common.js";

export interface Milestone {
  index: number;
  description: string;
  amount: number;
  deadline?: number; // unix timestamp
  evidenceUri?: string;
  releasedAt?: number;
}

export interface Split {
  recipient: string;
  basisPoints: number; // out of 10000
}

export interface Invoice {
  id: string;
  from: string;
  to: string;
  amount: number; // USD
  chain: string;
  status: InvoiceStatus;
  paymentType: "escrow" | "tab" | "stream" | "bounty" | "deposit" | "direct";
  memo?: string;
  milestones?: Milestone[];
  splits?: Split[];
  timeout?: number; // seconds
  createdAt: number;
  expiresAt?: number;
  metadata?: Record<string, unknown>;
}
