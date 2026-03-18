package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;

/** Result of a testnet mint operation. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class MintResponse {

    @JsonProperty("tx_hash")
    public String txHash;

    @JsonProperty("balance")
    public BigDecimal balance;
}
