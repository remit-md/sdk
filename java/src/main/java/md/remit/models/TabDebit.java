package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** A single off-chain debit against an open tab. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class TabDebit {

    @JsonProperty("id")
    public String id;

    @JsonProperty("tab_id")
    public String tabId;

    @JsonProperty("amount")
    public BigDecimal amount;

    @JsonProperty("memo")
    public String memo;

    @JsonProperty("cumulative")
    public BigDecimal cumulative;

    @JsonProperty("created_at")
    public Instant createdAt;
}
