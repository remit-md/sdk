package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** A per-second USDC payment stream. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Stream {

    @JsonProperty("id")
    public String id;

    @JsonProperty("payer")
    public String payer;

    @JsonProperty("recipient")
    public String recipient;

    @JsonProperty("rate_per_sec")
    public BigDecimal ratePerSec;

    @JsonProperty("deposit")
    public BigDecimal deposit;

    @JsonProperty("withdrawn")
    public BigDecimal withdrawn;

    @JsonProperty("vested")
    public BigDecimal vested;

    @JsonProperty("status")
    public String status; // "active" | "paused" | "closed"

    @JsonProperty("created_at")
    public Instant createdAt;
}
