package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

/** Paginated list of transactions. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class TransactionList {

    @JsonProperty("items")
    public List<Transaction> items;

    @JsonProperty("total")
    public int total;

    @JsonProperty("page")
    public int page;

    @JsonProperty("per_page")
    public int perPage;

    @JsonProperty("has_more")
    public boolean hasMore;
}
