import type { TabStatus } from "./common.js";

export interface Tab {
  id: string;
  payer: string;
  payee: string;
  limit: number;
  perUnit: number;
  spent: number;
  chain: string;
  status: TabStatus;
  createdAt: number;
  expiresAt: number;
}

export interface TabCharge {
  tabId: string;
  amount: number;
  units: number;
  memo?: string;
  chargedAt: number;
}
