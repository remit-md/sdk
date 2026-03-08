import type { DepositStatus } from "./common.js";

export interface Deposit {
  id: string;
  payer: string;
  payee: string;
  amount: number;
  chain: string;
  status: DepositStatus;
  createdAt: number;
  expiresAt: number;
  releasedAt?: number;
}
