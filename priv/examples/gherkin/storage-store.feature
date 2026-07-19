Feature: storage Store + Migrator
  # Executable contract (ADR 0015): storage/contract_test.go binds every step
  # to the real store — SQLite always, Postgres when SIRE_TEST_POSTGRES_URL is
  # set. Observed, never asserted.

  Scenario: a conflicting transaction rolls back
    Given an open store
    When a transaction writes key "a" and then fails
    Then key "a" is absent and the caller saw the error

  Scenario: values round-trip through a committed transaction
    Given an open store
    When a transaction puts key "b" with value "v1" and commits
    Then reading key "b" returns "v1"

  Scenario: migrations apply up and roll back down
    Given an open store with the embedded migration set
    When Up runs to the latest version
    Then Version reports the latest migration
    And the baseline schema accepts a tenant row
    When Down rolls back one step
    Then Version returns to the previous version

  Scenario: a dirty migration state blocks further migration
    Given an open store with the embedded migration set
    And the migration state is marked dirty
    Then Up fails with DirtyState
    And Down fails with DirtyState
