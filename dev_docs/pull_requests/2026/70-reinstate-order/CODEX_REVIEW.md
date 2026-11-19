# PR #70 review

**BUG - HIGH** A reinstatement made with an old order struct could return the previous buyer and publish the reinstated order on that buyer’s PubSub topic. The transition refreshed only selected fields from storage. A missing row could also reach the update and raise a stale entry error.

Reinstatement now uses the full locked order, including its current buyer, and returns `{:error, :not_found}` when the row has disappeared. Regression tests exercise reassignment before cancellation and removal before reinstatement.
