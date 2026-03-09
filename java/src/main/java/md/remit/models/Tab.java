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

    @JsonProperty("counterpart")
    public String counterpart;

    @JsonProperty("limit")
    public BigDecimal limit;

    @JsonProperty("used")
    public BigDecimal used;

    @JsonProperty("status")
    public String status; // "open" | "settled" | "expired"

    @JsonProperty("expires_at")
    public Instant expiresAt;

    @JsonProperty("created_at")
    public Instant createdAt;
}
