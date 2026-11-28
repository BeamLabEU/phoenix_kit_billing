# PR #76 review

Reviewed head `33702ab` against `dfc3a01`. The changes add provider refunds, failed-refund reconciliation, checkout closure, guest payment links, invoice events and a daily renewal cron.

| Severity | Finding | Effect |
| --- | --- | --- |
| BUG - HIGH | Hosted checkout checked the stored invoice status but priced the caller's copy. | A partial payment before or during session creation could leave the customer with a link charging the old balance. A failed session write could also return a URL that billing could never close. |
| BUG - HIGH | EveryPay returns the payment reference on successive partial refunds. Billing used that reference to deduplicate refunds. | The second refund could move money and return success while leaving the invoice balance unchanged. |
| BUG - HIGH | A successful HTTP response could contain a terminally failed or cancelled refund. | Billing could book a refund and void the invoice even though the provider reported failure. |
| BUG - HIGH | Failed-refund fallback matched the charge and amount even on a row with a different known refund ID. It also left the fallback match anonymous after reversal. | A failure could reverse the wrong refund. Redelivery after a read-back failure could skip reconciliation or select another same-amount refund. |
| BUG - HIGH | In-flight refund reconciliation deducted every concurrent refund on the payment. The manual duplicate-ID check ran before taking the invoice lock. | An unrelated identified refund could hide money returned by another request. Two manual submissions could record the same refund twice. |

See [the fixes and regression coverage](FOLLOW_UP.md).
