// A2A / AP2
export {
  discoverAgent,
  A2AClient,
  getTaskTxHash,
} from "./a2a.js";
export type {
  AgentCard,
  A2ACapabilities,
  A2AExtension,
  A2ASkill,
  A2AX402,
  A2AFees,
  A2ATask,
  A2ATaskStatus,
  A2AArtifact,
  A2AArtifactPart,
  IntentMandate,
  SendOptions,
  A2AClientOptions,
} from "./a2a.js";

// Core classes
export { RemitClient } from "./client.js";
export { Wallet } from "./wallet.js";
export type {
  WalletOptions,
  OpenTabOptions,
  CloseTabOptions,
  ChargeTabOptions,
  OpenStreamOptions,
  PostBountyOptions,
  PlaceDepositOptions,
  PermitSignature,
  SignPermitOptions,
} from "./wallet.js";

// Signers
export { PrivateKeySigner } from "./signer.js";
export type { Signer, TypedDataDomain, TypedDataTypes } from "./signer.js";
export { OwsSigner } from "./ows-signer.js";
export type { OwsSignerOptions } from "./ows-signer.js";
export { CliSigner } from "./cli-signer.js";

// Errors
export {
  RemitError,
  fromErrorCode,
  InvalidSignatureError,
  NonceReusedError,
  TimestampExpiredError,
  UnauthorizedError,
  InsufficientBalanceError,
  BelowMinimumError,
  EscrowNotFoundError,
  EscrowAlreadyFundedError,
  EscrowExpiredError,
  InvalidInvoiceError,
  DuplicateInvoiceError,
  SelfPaymentError,
  InvalidPaymentTypeError,
  TabDepletedError,
  TabExpiredError,
  TabNotFoundError,
  StreamNotFoundError,
  RateExceedsCapError,
  BountyExpiredError,
  BountyClaimedError,
  BountyMaxAttemptsError,
  BountyNotFoundError,
  ChainMismatchError,
  ChainUnsupportedError,
  RateLimitedError,
  CancelBlockedClaimStartError,
  CancelBlockedEvidenceError,
  VersionMismatchError,
  NetworkError,
} from "./errors.js";

// Models
export * from "./models/index.js";

// Testing utilities
export { MockRemit, MockWallet } from "./testing/mock.js";
export { LocalChain } from "./testing/local.js";

// x402 client middleware
export { X402Client, AllowanceExceededError } from "./x402.js";
export type { X402ClientOptions } from "./x402.js";

// x402 provider middleware
export { X402Paywall } from "./provider.js";
export type { PaywallOptions, CheckResult } from "./provider.js";

// Integrations
export { remitTools } from "./integrations/vercel-ai.js";
export type { RemitToolDescriptor } from "./integrations/vercel-ai.js";
