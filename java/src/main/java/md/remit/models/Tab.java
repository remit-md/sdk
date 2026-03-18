package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** Off-chain payment channel for batched micro-payments. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Tab {

    @JsonProperty("id")
    public String id;

    @JsonProperty("opener")
    public String opener;

    @JsonProperty("provider")
    public String provider;

    @JsonProperty("limit_amount")
    public BigDecimal limitAmount;

    @JsonProperty("per_unit")
    public BigDecimal perUnit;

    @JsonProperty("status")
    public String status; // "open" | "closed" | "settled" | "expired"

    @JsonProperty("total_charged")
    public BigDecimal totalCharged;

    @JsonProperty("closed_tx_hash")
    public String closedTxHash;

    @JsonProperty("expires_at")
    public Instant expiresAt;

    @JsonProperty("created_at")
    public Instant createdAt;
}
