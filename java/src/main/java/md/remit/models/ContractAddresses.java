package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/** On-chain contract addresses for the current deployment. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class ContractAddresses {

    @JsonProperty("chain_id")
    public long chainId;

    @JsonProperty("usdc")
    public String usdc;

    @JsonProperty("router")
    public String router;

    @JsonProperty("escrow")
    public String escrow;

    @JsonProperty("tab")
    public String tab;

    @JsonProperty("stream")
    public String stream;

    @JsonProperty("bounty")
    public String bounty;

    @JsonProperty("deposit")
    public String deposit;

    @JsonProperty("fee_calculator")
    public String feeCalculator;

    @JsonProperty("key_registry")
    public String keyRegistry;

    @JsonProperty("arbitration")
    public String arbitration;
}
