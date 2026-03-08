import type { Reputation, ReputationTier } from "./common.js";
export type { Reputation, ReputationTier };

export interface ReputationProfile extends Reputation {
  tier: ReputationTier;
  badges: string[];
}
