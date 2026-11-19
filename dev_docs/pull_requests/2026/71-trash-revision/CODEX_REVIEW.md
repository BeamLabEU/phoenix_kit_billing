# PR #71 review

Trashing and restoring an order each advance its revision under the order lock. The tests cover both transitions from a synced revision, preservation of the other metadata and preservation of the stored edit time. Existing trashed rows acquire their next revision on restore.

The merge reconciles the schema, event and API documentation with the optional internal note introduced in #72.
