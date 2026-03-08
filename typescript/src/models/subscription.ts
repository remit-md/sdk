import type { SubscriptionStatus } from "./common.js";

export interface Subscription {
  id: string;
  payer: string;
  payee: string;
  amount: number;
  interval: "daily" | "weekly" | "monthly" | "yearly";
  maxPeriods?: number;
  periodsCompleted: number;
  chain: string;
  status: SubscriptionStatus;
  nextPaymentAt: number;
  createdAt: number;
  cancelledAt?: number;
}
