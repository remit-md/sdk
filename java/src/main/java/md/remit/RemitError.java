package md.remit;

import java.util.Collections;
import java.util.Map;

/**
 * Exception thrown by remit.md SDK operations.
 *
 * <p>Every error has a machine-readable {@code code} from {@link ErrorCodes},
 * a human-readable {@code message} with a fix suggestion, and optional
 * {@code details} for structured context.
 *
 * <pre>{@code
 * try {
 *     wallet.pay("0xinvalid", new BigDecimal("1.00"));
 * } catch (RemitError e) {
 *     if (e.getCode().equals(ErrorCodes.INVALID_ADDRESS)) {
 *         // handle validation error
 *     }
 * }
 * }</pre>
 */
public class RemitError extends RuntimeException {

    private final String code;
    private final Map<String, Object> details;
    private final int httpStatus;

    public RemitError(String code, String message) {
        this(code, message, Collections.emptyMap(), 0);
    }

    public RemitError(String code, String message, Map<String, Object> details) {
        this(code, message, details, 0);
    }

    public RemitError(String code, String message, Map<String, Object> details, int httpStatus) {
        super(message);
        this.code = code;
        this.details = details != null ? Collections.unmodifiableMap(details) : Collections.emptyMap();
        this.httpStatus = httpStatus;
    }

    /** Machine-readable error code. See {@link ErrorCodes}. */
    public String getCode() {
        return code;
    }

    /**
     * Structured context about the error.
     * E.g., for INVALID_ADDRESS: {@code {"address": "0xinvalid"}}.
     */
    public Map<String, Object> getDetails() {
        return details;
    }

    /** HTTP status code (0 if not from an HTTP response). */
    public int getHttpStatus() {
        return httpStatus;
    }

    @Override
    public String toString() {
        return "RemitError[" + code + "]: " + getMessage();
    }
}
