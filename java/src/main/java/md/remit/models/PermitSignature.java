package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/** ERC-2612 permit signature for gasless USDC approvals. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class PermitSignature {

    @JsonProperty("value")
    public long value;

    @JsonProperty("deadline")
    public long deadline;

    @JsonProperty("v")
    public int v;

    @JsonProperty("r")
    public String r;

    @JsonProperty("s")
    public String s;

    public PermitSignature() {}

    public PermitSignature(long value, long deadline, int v, String r, String s) {
        this.value = value;
        this.deadline = deadline;
        this.v = v;
        this.r = r;
        this.s = s;
    }
}
