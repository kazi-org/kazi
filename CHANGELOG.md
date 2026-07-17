# Changelog

> **Deprecated (removal in v2.0.0):** the command-runner provider names
> `test_runner` and `prod_log` are **deprecated** -- folded onto the unified
> `custom_script` engine as presets (ADR-0040). Both names still resolve, so this
> is NON-BREAKING; a goal still using either name loads and evaluates identically
> and the loader prints a one-line migration hint to STDERR (never into `--json`
> stdout). Migrate `test_runner` -> `custom_script` with `verdict = "exit_zero"`,
> and `prod_log` -> `custom_script` with `verdict = "match_count"`. The names are
> removed in v2.0.0. See [docs/deprecations.md](docs/deprecations.md).

> **Breaking (v1.0.0):** the deprecated CLI aliases `kazi run`, `kazi propose`,
> and `mix kazi.run` were **removed** (verb unification under ADR-0032). They no
> longer parse: `kazi run` / `kazi propose` now error as unknown commands, and the
> MCP server no longer advertises `kazi_run` / `kazi_propose`. Use `kazi apply`,
> `kazi plan`, and `mix kazi.apply` instead. See
> [docs/deprecations.md](docs/deprecations.md) for the migration.

## [1.186.1](https://github.com/kazi-org/kazi/compare/v1.186.0...v1.186.1) (2026-07-17)


### Bug Fixes

* **bus:** bound every with_conn-routed call so a wedged NATS reply can't hang forever (issue [#1255](https://github.com/kazi-org/kazi/issues/1255)) ([5fbc96a](https://github.com/kazi-org/kazi/commit/5fbc96a18b4b7146059892a3724e4f94325d617c))

## [1.186.0](https://github.com/kazi-org/kazi/compare/v1.185.0...v1.186.0) (2026-07-17)


### Features

* **clarify:** flag a code goal with no landing mode, and suggest the gates (T44.12, ADR-0055) ([f785725](https://github.com/kazi-org/kazi/commit/f7857256afe24c4923588542e5de88876e8551fd))

## [1.185.0](https://github.com/kazi-org/kazi/compare/v1.184.0...v1.185.0) (2026-07-17)


### Features

* **goal:** add the [conventions] block (process_contract toggle + extra_rules) ([39f3c8d](https://github.com/kazi-org/kazi/commit/39f3c8dab14009a5abbb727e2809810f1ccfb029))
* **harness:** controller-owned process-contract renderer ([06478dc](https://github.com/kazi-org/kazi/commit/06478dcd55f48308cb9e70a361076e7907fbd0a7))
* **loop:** append the process contract to the dispatch prompt (after orientation, before work item) ([1f9d9dc](https://github.com/kazi-org/kazi/commit/1f9d9dc3984ddf4bc76624c26ec964b53936af69))

## [1.184.0](https://github.com/kazi-org/kazi/compare/v1.183.0...v1.184.0) (2026-07-17)


### Features

* **loop:** route pin-blocked scenarios to the demonstrator (:dispatch_demonstrator) ([8a0cf43](https://github.com/kazi-org/kazi/commit/8a0cf4302e2740578d34cc5fb121129fd5d82fe9))
* **scenario:** demonstrator dispatch -- versioned prompt + born-reproducible acceptance gate ([24f2da8](https://github.com/kazi-org/kazi/commit/24f2da8e1f6ff1616154a8b5ce1b2af1b839214e))

## [1.183.0](https://github.com/kazi-org/kazi/compare/v1.182.0...v1.183.0) (2026-07-17)


### Features

* **scenario:** standing capability monitors + intern the delegate passthrough keys (T49.12, ADR-0064 d6) ([dc66ab7](https://github.com/kazi-org/kazi/commit/dc66ab76d14b31953eedfce15cdc175d4d6e3b0f))

## [1.182.0](https://github.com/kazi-org/kazi/compare/v1.181.0...v1.182.0) (2026-07-17)


### Features

* **dashboard:** starmap SESSIONS rail renders live bus presence (T51.5, ADR-0073) ([08d521b](https://github.com/kazi-org/kazi/commit/08d521b4b2a89589185937a6daace08a9c873fcb))
* **runtime:** mirror apply run lifecycle onto the bus, best-effort (T51.5, ADR-0067 point 1) ([b79a36f](https://github.com/kazi-org/kazi/commit/b79a36ffc34237624fc67ee7ada732a6ce580885))

## [1.181.0](https://github.com/kazi-org/kazi/compare/v1.180.0...v1.181.0) (2026-07-17)


### Features

* **scheduler:** needs-ordered merge + git cherry silent-revert verification ([e34cbd5](https://github.com/kazi-org/kazi/commit/e34cbd5998ca0bb73ee047f18c53ab3b732acaa0))

## [1.180.0](https://github.com/kazi-org/kazi/compare/v1.179.0...v1.180.0) (2026-07-17)


### Features

* **enforcement:** role-scoped path policy (fixer read-only, demonstrator write-only) ([f413c54](https://github.com/kazi-org/kazi/commit/f413c54f64e98e8c4c457d554fde08331370bdf1))
* **loader:** parse [enforcement.roles] and derive role defaults from scenario predicates ([1f7b33c](https://github.com/kazi-org/kazi/commit/1f7b33cb81010f20cae461b1613a8ca9486562bf))
* **providers:** public Scenario.pin_path/1 for effective pin resolution ([dae8120](https://github.com/kazi-org/kazi/commit/dae8120fe46b271be03a2e99cf7043f563eddb7d))

## [1.179.0](https://github.com/kazi-org/kazi/compare/v1.178.0...v1.179.0) (2026-07-17)


### Features

* **runtime:** align harness permissions with the declared landing mode (T44.5, ADR-0055) ([6668db3](https://github.com/kazi-org/kazi/commit/6668db3ed15fdbfdd294a052f0ad073b3891fb8a))

## [1.178.0](https://github.com/kazi-org/kazi/compare/v1.177.0...v1.178.0) (2026-07-17)


### Features

* **cli:** surface per-group landed refs in the collective result ([be4647e](https://github.com/kazi-org/kazi/commit/be4647e4846c5603340a95aac50fe45570c00407))
* **scheduler:** land each converged partition on its own group-derived branch ([96dca3c](https://github.com/kazi-org/kazi/commit/96dca3c7367a4e20c38abc7a0d1208bfd71685dc))

## [1.177.0](https://github.com/kazi-org/kazi/compare/v1.176.0...v1.177.0) (2026-07-17)


### Features

* **examples:** hand-authored scenario goal-file + replayable fixture page ([cd4a046](https://github.com/kazi-org/kazi/commit/cd4a0468701bb766ada1c66fef2da2faba088876))

## [1.176.0](https://github.com/kazi-org/kazi/compare/v1.175.0...v1.176.0) (2026-07-17)


### Features

* **bus:** board claim ownership read live from refs/claims/* (T55.8, ADR-0073 d2) ([7cbdcda](https://github.com/kazi-org/kazi/commit/7cbdcda5de5ffe9d4cc620294257581ee55f775e))

## [1.175.0](https://github.com/kazi-org/kazi/compare/v1.174.0...v1.175.0) (2026-07-17)


### Features

* **browser:** viewport matrix + the component(story-URL) recipe (T43.5, ADR-0053) ([ddf2c24](https://github.com/kazi-org/kazi/commit/ddf2c24a1dec86d7078f43f97d0dbe37e931d530))

## [1.174.0](https://github.com/kazi-org/kazi/compare/v1.173.0...v1.174.0) (2026-07-17)


### Features

* **providers:** substitute fresh inputs before scenario replay ([25a92d5](https://github.com/kazi-org/kazi/commit/25a92d5748bf32f36b6e350ed70497274ec96289))
* **scenario:** input generators + per-replay placeholder substitution ([58c33cf](https://github.com/kazi-org/kazi/commit/58c33cf681eca3c09313d4a18dd9e3a6f46cdb0b))

## [1.173.0](https://github.com/kazi-org/kazi/compare/v1.172.0...v1.173.0) (2026-07-17)


### Features

* **actions:** integrate verifies-then-ships for [integration] goals ([099435e](https://github.com/kazi-org/kazi/commit/099435e2de7975d97727ede65854b666eaf697c0))

## [1.172.0](https://github.com/kazi-org/kazi/compare/v1.171.1...v1.172.0) (2026-07-17)


### Features

* **loader:** accept and validate scenario predicate config ([f392e98](https://github.com/kazi-org/kazi/commit/f392e98e2dba806180a276c1693a3eb525c40260))
* **providers:** scenario provider -- replay a pinned Gherkin Scenario by delegation ([c83f57a](https://github.com/kazi-org/kazi/commit/c83f57a96c899bb307747b5292f065bbe06478e1))
* **runtime:** register the scenario provider ([fdca389](https://github.com/kazi-org/kazi/commit/fdca389467c1b6bfefbd0f742b71868a62d34fa5))
* **schema:** scenario predicate config schema ([38d6040](https://github.com/kazi-org/kazi/commit/38d6040077a259abd347a9f2388160f727ffe8a4))

## [1.171.1](https://github.com/kazi-org/kazi/compare/v1.171.0...v1.171.1) (2026-07-17)


### Bug Fixes

* **context:** stuck bundle never blanks the last predicate's failure ([c2960aa](https://github.com/kazi-org/kazi/commit/c2960aa5ff61af7d1c8fe553ea0f62621f9dcccd)), closes [#1075](https://github.com/kazi-org/kazi/issues/1075)
* **scheduler:** push run-owned partition branch with upstream at creation ([00a90df](https://github.com/kazi-org/kazi/commit/00a90dfb0668b9ceb99a3be0d6a4b45ea88ab28e)), closes [#1075](https://github.com/kazi-org/kazi/issues/1075)

## [1.171.0](https://github.com/kazi-org/kazi/compare/v1.170.0...v1.171.0) (2026-07-17)


### Features

* **bus:** the kazi bus hook payload (session-start board, turn digest) ([28153cb](https://github.com/kazi-org/kazi/commit/28153cbb560e2b3b7c4c545269f1ceb60d8f26ca))
* **cli:** wire bus hook dispatch + help to Kazi.Bus.Hook ([b9f84aa](https://github.com/kazi-org/kazi/commit/b9f84aa7cb151295ead3024ed0720e1b3127b408))

## [1.170.0](https://github.com/kazi-org/kazi/compare/v1.169.0...v1.170.0) (2026-07-17)


### Features

* **goal:** synthesize an implicit landed predicate when [integration] mode != none ([d4c76b4](https://github.com/kazi-org/kazi/commit/d4c76b4c166ad02b98806d09c8843c3c1defc6c7))

## [1.169.0](https://github.com/kazi-org/kazi/compare/v1.168.0...v1.169.0) (2026-07-17)


### Features

* **browser:** add a11y (axe-core) assertion to the playwright runner ([1fba03a](https://github.com/kazi-org/kazi/commit/1fba03a05517b71396da0671122862ccdd0177cd))
* **browser:** surface a11y violation count as a lower_better score ([3cef3c4](https://github.com/kazi-org/kazi/commit/3cef3c468f578ce6c2fcefdf71f930992c2658ad))
* **loader:** validate a11y browser assertion severity/max_violations ([bba9a72](https://github.com/kazi-org/kazi/commit/bba9a726cc4a3e7264c1cecaa58db162bc696ae8))
* **schema:** document a11y in the browser predicate schema ([ac60858](https://github.com/kazi-org/kazi/commit/ac6085875ae0325bc99fdd29a6937b371f66565a))

## [1.168.0](https://github.com/kazi-org/kazi/compare/v1.167.0...v1.168.0) (2026-07-17)


### Features

* **bus:** read_digest/1 -- the one daemon-assembled read every surface shares ([8a8f860](https://github.com/kazi-org/kazi/commit/8a8f860ecc74badefeda44ba33fd7a053f4fa0a7))
* **cli:** render the daemon's digest; document `bus read --since <cursor>` ([d330a6c](https://github.com/kazi-org/kazi/commit/d330a6c3ff2236cf9094ffa69e74f2d0726f373e))
* **daemon:** assemble the bus digest server-side (T55.7, ADR-0072 d5) ([8c4b0ef](https://github.com/kazi-org/kazi/commit/8c4b0eff4f9869b117e14958220ce4d5972748ff))
* **mcp:** kazi_bus_read reads through the daemon's assembly (T55.7) ([62d363b](https://github.com/kazi-org/kazi/commit/62d363b25ca3553d91448281d7f6fa7dcf06c805))


### Bug Fixes

* **digest:** restore the [@doc](https://github.com/doc) opening dropped in the T55.6 rebase resolution ([3d0158f](https://github.com/kazi-org/kazi/commit/3d0158f5f3f309acc3f9cae3552a87f6993f220d))

## [1.167.0](https://github.com/kazi-org/kazi/compare/v1.166.0...v1.167.0) (2026-07-17)


### Features

* **browser:** `download` file-effect assertion (T49.10, ADR-0064 d7) ([d41fd19](https://github.com/kazi-org/kazi/commit/d41fd19f5b26ae679813ddef117ca198deb9d503))

## [1.166.0](https://github.com/kazi-org/kazi/compare/v1.165.0...v1.166.0) (2026-07-17)


### Features

* **goal:** add [integration] branch field and integration_branch/1 resolver ([70f7003](https://github.com/kazi-org/kazi/commit/70f700392a7c045b3eff96e47cd6bdb16a507e94))


### Bug Fixes

* **scheduler:** recognize run-owned branch by identity, not kazi-partition prefix ([7b39ccf](https://github.com/kazi-org/kazi/commit/7b39ccffec210fc662c29ff6d4cc627dd5833d28))
* **scheduler:** worktree checks out the goal's real branch via :owned_branch ([896f22f](https://github.com/kazi-org/kazi/commit/896f22f356c2948f6777a72cab1342331fc4147c))

## [1.165.0](https://github.com/kazi-org/kazi/compare/v1.164.1...v1.165.0) (2026-07-17)


### Features

* **examples:** cli provider goal-file over the kazi binary ([a32e082](https://github.com/kazi-org/kazi/commit/a32e08263f7083136c15c92bb7eb0b5fb1161af9))
* **loader:** map cli provider and validate its assertions ([aa52930](https://github.com/kazi-org/kazi/commit/aa529301fa031caf5ab1237fd078d8c6889ffff4))
* **providers:** add :cli golden-invocation provider (UC-055) ([7620e1d](https://github.com/kazi-org/kazi/commit/7620e1d167b902738f94bf8ad97f43d8802e1f79))
* **runtime:** register :cli provider in the dispatch map ([31c9b81](https://github.com/kazi-org/kazi/commit/31c9b811570b9fb730617b4d024fce85bff2930d))
* **schema:** kazi schema cli config descriptor ([f054ca0](https://github.com/kazi-org/kazi/commit/f054ca00f3a1391b41bfd9b5bae6d2e09e9a0cb5))

## [1.164.1](https://github.com/kazi-org/kazi/compare/v1.164.0...v1.164.1) (2026-07-17)


### Bug Fixes

* **bus:** presence records the stable session-anchor pid, not the ephemeral CLI pid ([cb9f867](https://github.com/kazi-org/kazi/commit/cb9f867ec56c5e63273bd358488a682c37c9d432)), closes [#1164](https://github.com/kazi-org/kazi/issues/1164)

## [1.164.0](https://github.com/kazi-org/kazi/compare/v1.163.0...v1.164.0) (2026-07-17)


### Features

* **bus:** kazi bus get &lt;id&gt; -- deliberate pull for stubbed content (ADR-0072 d3) ([0065d65](https://github.com/kazi-org/kazi/commit/0065d6551de748f2ff496dcef234c852c8f2e796))

## [1.163.0](https://github.com/kazi-org/kazi/compare/v1.162.0...v1.163.0) (2026-07-17)


### Features

* **bus:** board projection module, reusing the digest stub rule ([4a17871](https://github.com/kazi-org/kazi/commit/4a178716135f6420c3ac581245278e69b3d9b090))
* **bus:** Kazi.Bus.board/1 reads last-value fact per topic, cursor-free ([a0de0fa](https://github.com/kazi-org/kazi/commit/a0de0fa7c868f77109d6293625c442b6141dc5f4))
* **cli:** kazi bus board verb renders current bus state ([ef549f6](https://github.com/kazi-org/kazi/commit/ef549f66c5fb9041d90891f6ec7d0a7010f04453))
* **mcp:** kazi_bus_board tool mirrors the bus board verb ([9b907d1](https://github.com/kazi-org/kazi/commit/9b907d18cb99be699856405125457f1eedc50e9b))

## [1.162.0](https://github.com/kazi-org/kazi/compare/v1.161.0...v1.162.0) (2026-07-17)


### Features

* **cli:** kazi schema integration + lint unknown-mode warning ([fc3bbb0](https://github.com/kazi-org/kazi/commit/fc3bbb00727909537cc1375a07ea085b94edf5c2))
* **goal:** advisory [integration] mode lint ([f592c04](https://github.com/kazi-org/kazi/commit/f592c046488437572291195e64f2bfb676143a7f))
* **goal:** parse and expose the [integration] landing block ([82ae090](https://github.com/kazi-org/kazi/commit/82ae0900045ce4c2e41813e0c0b0bf5ef0477113))

## [1.161.0](https://github.com/kazi-org/kazi/compare/v1.160.0...v1.161.0) (2026-07-17)


### Features

* **cli:** warn pre-dispatch when the permission mode cannot act (T54.6, [#1072](https://github.com/kazi-org/kazi/issues/1072)) ([32092be](https://github.com/kazi-org/kazi/commit/32092be68551543bdeb0c6ef5f4fa1b35d1a3eca))
* **loop:** fail fast when the harness was refused, not merely unsuccessful (T54.6, [#1072](https://github.com/kazi-org/kazi/issues/1072)) ([7a8a22c](https://github.com/kazi-org/kazi/commit/7a8a22cc7aa933848dc5ad2e3961c6cd36565871))
* **loop:** surface permission_denied_tool_calls on the terminal result (T54.6, [#1072](https://github.com/kazi-org/kazi/issues/1072)) ([310a5ad](https://github.com/kazi-org/kazi/commit/310a5add140c235ba7c8ebc824e6c0377f42dabe))

## [1.160.0](https://github.com/kazi-org/kazi/compare/v1.159.1...v1.160.0) (2026-07-17)


### Features

* **browser:** assertion dispatch table + console_clean journey capture ([d6ede52](https://github.com/kazi-org/kazi/commit/d6ede5264c455b5909e3ae8dd28376914e50bf7a))
* **loader:** validate browser assertion types at goal-load ([ebf9307](https://github.com/kazi-org/kazi/commit/ebf9307a358f844435c1f37b6d1f990e951c889d))

## [1.159.1](https://github.com/kazi-org/kazi/compare/v1.159.0...v1.159.1) (2026-07-17)


### Bug Fixes

* **cli:** --check surfaces the reason for an errored predicate ([#1096](https://github.com/kazi-org/kazi/issues/1096)) ([d2888a6](https://github.com/kazi-org/kazi/commit/d2888a681e2070ac066f9edca3a165205362bff3))
* **providers:** custom_script resolves a workspace-relative cmd ([#1096](https://github.com/kazi-org/kazi/issues/1096)) ([1ee83a8](https://github.com/kazi-org/kazi/commit/1ee83a812b03e79c763eb40a9e0d63e59da0eaa8))

## [1.159.0](https://github.com/kazi-org/kazi/compare/v1.158.0...v1.159.0) (2026-07-17)


### Features

* **bus:** tell answers a receipt -- id, resolved recipient, liveness (T55.12) ([5f866b7](https://github.com/kazi-org/kazi/commit/5f866b7f9545005c13fdca05a4bcb5845f38efad))
* **cli:** bus status &lt;id&gt;, tell prints its id, who shows inbox depth (T55.12) ([71f8651](https://github.com/kazi-org/kazi/commit/71f8651dc22375476e16e0282a8f07f01eca8d70))
* **mcp:** kazi_bus_tell returns the receipt; new kazi_bus_status twin (T55.12) ([c80fb98](https://github.com/kazi-org/kazi/commit/c80fb98e24b6ad0647b02117e17cfe85740c255f))


### Bug Fixes

* **mcp:** group fetch_message_id outside the call_tool clauses (T55.12) ([df51c55](https://github.com/kazi-org/kazi/commit/df51c5571396172933ccca953309289fbcb8e7b4))

## [1.158.0](https://github.com/kazi-org/kazi/compare/v1.157.0...v1.158.0) (2026-07-17)


### Features

* **reconcile:** GherkinImporter reads [@tags](https://github.com/tags) -- role/priority/interface (ADR-0054) ([57bb401](https://github.com/kazi-org/kazi/commit/57bb401c47dd893e9af510e586be48810138a1c4))


### Bug Fixes

* **goal:** intern the tag metadata atoms so a tagged spec loads in the release ([e99945d](https://github.com/kazi-org/kazi/commit/e99945d8bab9834dd853e7bde3921a5289c476d9))

## [1.157.0](https://github.com/kazi-org/kazi/compare/v1.156.0...v1.157.0) (2026-07-17)


### Features

* **scenario:** pin schema + validator -- the deterministic half of a scenario predicate (ADR-0064) ([46af2d0](https://github.com/kazi-org/kazi/commit/46af2d07d9a824d2f8bf94f6241c7256e3975c22))

## [1.156.0](https://github.com/kazi-org/kazi/compare/v1.155.2...v1.156.0) (2026-07-17)


### Features

* **scenario:** extract one Scenario from a .feature and hash its normalized text (ADR-0064) ([f1873dd](https://github.com/kazi-org/kazi/commit/f1873dd0c0f1a0217b0e91f3224e96383ae73034))

## [1.155.2](https://github.com/kazi-org/kazi/compare/v1.155.1...v1.155.2) (2026-07-17)


### Bug Fixes

* **compile:** restore a warning-clean build (11 -&gt; 0) ([c280fc7](https://github.com/kazi-org/kazi/commit/c280fc71b769ca4b10584e7613b962dde4bc978e))

## [1.155.1](https://github.com/kazi-org/kazi/compare/v1.155.0...v1.155.1) (2026-07-17)


### Bug Fixes

* **harness:** default permission_mode to auto + surface denied tool calls ([#769](https://github.com/kazi-org/kazi/issues/769)) ([540fada](https://github.com/kazi-org/kazi/commit/540fada6e3dc155dea0f98571ff2731e1f0c1eba))

## [1.155.0](https://github.com/kazi-org/kazi/compare/v1.154.0...v1.155.0) (2026-07-17)


### Features

* **teach:** ship a self-contained three-file skill with a LOCAL.md extension point ([5436307](https://github.com/kazi-org/kazi/commit/54363078b02a56eb471c97b5da1af68112efd412))

## [1.154.0](https://github.com/kazi-org/kazi/compare/v1.153.0...v1.154.0) (2026-07-17)


### Features

* **reconcile:** GherkinExpander enumerates runtime sub-predicates, one per Examples row for outlines (ADR-0071) ([991c541](https://github.com/kazi-org/kazi/commit/991c54172da624102ef5d331c97d1442168edbf6))

## [1.153.0](https://github.com/kazi-org/kazi/compare/v1.152.0...v1.153.0) (2026-07-17)


### Features

* **dashboard:** T55.3 live roster via transport source when a daemon is up (ADR-0073 d4) (aux) ([bf30130](https://github.com/kazi-org/kazi/commit/bf30130b782ef175ba834d9c95fa0242cd69d145))
* **dashboard:** T55.3 live roster via transport source when a daemon is up (ADR-0073 d4) (docs) ([f610108](https://github.com/kazi-org/kazi/commit/f6101082be36cba25ca4a7c5e9c4c314d6999e1f))
* **dashboard:** T55.3 live roster via transport source when a daemon is up (ADR-0073 d4) (lib) ([b05c531](https://github.com/kazi-org/kazi/commit/b05c53145bbaab56b6b83aefddce495426dbf296))
* **dashboard:** T55.3 live roster via transport source when a daemon is up (ADR-0073 d4) (test) ([06707e1](https://github.com/kazi-org/kazi/commit/06707e1a74cc990d5edcdc23185894dc4046207d))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (aux) ([b3369b1](https://github.com/kazi-org/kazi/commit/b3369b1e2d2021e787ebdf2e13ded3bc0c42ef50))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (docs) ([b0586ce](https://github.com/kazi-org/kazi/commit/b0586cef75fd83e9ff3f221d33b052382cc83a4a))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (lib) ([6e31dba](https://github.com/kazi-org/kazi/commit/6e31dba867f40dee10ece332d6b9aa3f518e99f6))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (test) ([cbde3a5](https://github.com/kazi-org/kazi/commit/cbde3a52694f1064ab925412e91cd92b547dacb6))


### Bug Fixes

* **dist:** T54.10 burrito stdout purity -- release-binary regression pin (test) ([467a503](https://github.com/kazi-org/kazi/commit/467a50339a57306eb846fa5e576bc3cf69c309a3))

## [1.152.0](https://github.com/kazi-org/kazi/compare/v1.151.0...v1.152.0) (2026-07-17)


### Features

* **bus:** T55.11 presence liveness -- idle vs dead, ghost reaping, who filters (docs) ([5599e08](https://github.com/kazi-org/kazi/commit/5599e08287a37611be937ece27ebbcf346b97e85))
* **bus:** T55.11 presence liveness -- idle vs dead, ghost reaping, who filters (lib) ([b29561c](https://github.com/kazi-org/kazi/commit/b29561c4bcaa2d654df45cda7ed5061a3cf2363c))
* **bus:** T55.11 presence liveness -- idle vs dead, ghost reaping, who filters (test) ([80e6eb9](https://github.com/kazi-org/kazi/commit/80e6eb9e64ca5bf0724a8ee81e7656391071d80f))
* **bus:** T55.5 stable identity -- bus name, nickname tell, stable fallback id (ADR-0073 d3) (aux) ([0e91e03](https://github.com/kazi-org/kazi/commit/0e91e03df2601df4cb66f30f64b5b63fad80309c))
* **bus:** T55.5 stable identity -- bus name, nickname tell, stable fallback id (ADR-0073 d3) (docs) ([ede3758](https://github.com/kazi-org/kazi/commit/ede3758575517e8b9f480f70a83842f05661b745))
* **bus:** T55.5 stable identity -- bus name, nickname tell, stable fallback id (ADR-0073 d3) (lib) ([7b62d8e](https://github.com/kazi-org/kazi/commit/7b62d8e2e32e2fb16e56b7d82e12578b0a759a04))
* **bus:** T55.5 stable identity -- bus name, nickname tell, stable fallback id (ADR-0073 d3) (test) ([974cfe4](https://github.com/kazi-org/kazi/commit/974cfe4856efb665b6c740c0bd7ef97e725561a2))
* **dashboard:** T55.3 live roster via transport source when a daemon is up (ADR-0073 d4) (aux) ([bf30130](https://github.com/kazi-org/kazi/commit/bf30130b782ef175ba834d9c95fa0242cd69d145))
* **dashboard:** T55.3 live roster via transport source when a daemon is up (ADR-0073 d4) (docs) ([f610108](https://github.com/kazi-org/kazi/commit/f6101082be36cba25ca4a7c5e9c4c314d6999e1f))
* **dashboard:** T55.3 live roster via transport source when a daemon is up (ADR-0073 d4) (lib) ([b05c531](https://github.com/kazi-org/kazi/commit/b05c53145bbaab56b6b83aefddce495426dbf296))
* **dashboard:** T55.3 live roster via transport source when a daemon is up (ADR-0073 d4) (test) ([06707e1](https://github.com/kazi-org/kazi/commit/06707e1a74cc990d5edcdc23185894dc4046207d))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (aux) ([b3369b1](https://github.com/kazi-org/kazi/commit/b3369b1e2d2021e787ebdf2e13ded3bc0c42ef50))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (docs) ([b0586ce](https://github.com/kazi-org/kazi/commit/b0586cef75fd83e9ff3f221d33b052382cc83a4a))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (lib) ([6e31dba](https://github.com/kazi-org/kazi/commit/6e31dba867f40dee10ece332d6b9aa3f518e99f6))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (test) ([cbde3a5](https://github.com/kazi-org/kazi/commit/cbde3a52694f1064ab925412e91cd92b547dacb6))


### Bug Fixes

* **bus:** T54.9 watch anchors to now -- strictly-new messages, --since escape ([#1097](https://github.com/kazi-org/kazi/issues/1097)) ([2362815](https://github.com/kazi-org/kazi/commit/2362815b0698340bbd60492a8a58c4bae2751e74))

## [1.151.0](https://github.com/kazi-org/kazi/compare/v1.150.0...v1.151.0) (2026-07-17)


### Features

* **bus:** bounded machine digest -- Digest.render/1 with the 1 KiB stub rule and 40-line bound (ADR-0072 d1/d2/d6) ([2eba2a6](https://github.com/kazi-org/kazi/commit/2eba2a61d8909b3384c1f5639bdc933adf9ef248))
* **bus:** digest is the default on --json and MCP; --full/full:true is the escape (ADR-0072 d1) ([90e0d27](https://github.com/kazi-org/kazi/commit/90e0d27fa0bbe1abb00a3ebe2e2ca5d3913a7914))
* **bus:** expose the JetStream stream sequence as the public message id (ADR-0072 d3) ([c9b3e57](https://github.com/kazi-org/kazi/commit/c9b3e5799d29bbdd3b1d136fb452f55252e1a8d4))
* **bus:** T55.11 presence liveness -- idle vs dead, ghost reaping, who filters (docs) ([5599e08](https://github.com/kazi-org/kazi/commit/5599e08287a37611be937ece27ebbcf346b97e85))
* **bus:** T55.11 presence liveness -- idle vs dead, ghost reaping, who filters (lib) ([b29561c](https://github.com/kazi-org/kazi/commit/b29561c4bcaa2d654df45cda7ed5061a3cf2363c))
* **bus:** T55.11 presence liveness -- idle vs dead, ghost reaping, who filters (test) ([80e6eb9](https://github.com/kazi-org/kazi/commit/80e6eb9e64ca5bf0724a8ee81e7656391071d80f))
* **bus:** T55.5 stable identity -- bus name, nickname tell, stable fallback id (ADR-0073 d3) (aux) ([0e91e03](https://github.com/kazi-org/kazi/commit/0e91e03df2601df4cb66f30f64b5b63fad80309c))
* **bus:** T55.5 stable identity -- bus name, nickname tell, stable fallback id (ADR-0073 d3) (docs) ([ede3758](https://github.com/kazi-org/kazi/commit/ede3758575517e8b9f480f70a83842f05661b745))
* **bus:** T55.5 stable identity -- bus name, nickname tell, stable fallback id (ADR-0073 d3) (lib) ([7b62d8e](https://github.com/kazi-org/kazi/commit/7b62d8e2e32e2fb16e56b7d82e12578b0a759a04))
* **bus:** T55.5 stable identity -- bus name, nickname tell, stable fallback id (ADR-0073 d3) (test) ([974cfe4](https://github.com/kazi-org/kazi/commit/974cfe4856efb665b6c740c0bd7ef97e725561a2))
* **cli:** bus digest envelope joins the versioned schema surface (kazi schema bus, ADR-0023/ADR-0072) ([ce45fb3](https://github.com/kazi-org/kazi/commit/ce45fb32ae94d98d677b34e1580561c813ead750))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (aux) ([b3369b1](https://github.com/kazi-org/kazi/commit/b3369b1e2d2021e787ebdf2e13ded3bc0c42ef50))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (docs) ([b0586ce](https://github.com/kazi-org/kazi/commit/b0586cef75fd83e9ff3f221d33b052382cc83a4a))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (lib) ([6e31dba](https://github.com/kazi-org/kazi/commit/6e31dba867f40dee10ece332d6b9aa3f518e99f6))
* **teach:** T55.2 kazi install-hooks + bus hook skeleton, with wave-gate fixes (ADR-0071) (test) ([cbde3a5](https://github.com/kazi-org/kazi/commit/cbde3a52694f1064ab925412e91cd92b547dacb6))


### Bug Fixes

* **bus:** T54.9 watch anchors to now -- strictly-new messages, --since escape ([#1097](https://github.com/kazi-org/kazi/issues/1097)) ([2362815](https://github.com/kazi-org/kazi/commit/2362815b0698340bbd60492a8a58c4bae2751e74))

## [1.150.0](https://github.com/kazi-org/kazi/compare/v1.149.0...v1.150.0) (2026-07-15)


### Features

* **archive:** trim_plan moves spec:-referenced behavior specs to docs/specs/archive/ (T40.4, ADR-0050) ([052767a](https://github.com/kazi-org/kazi/commit/052767ab6491a61021784e65e506a82823491f93))
* **doc-freshness:** (g) every spec: pointer in the live WBS resolves to a file (T40.5, ADR-0050) ([facf45c](https://github.com/kazi-org/kazi/commit/facf45cb473983bb4986fe441a70b6de5e5b54f0))
* **doc-lifecycle:** wrap the spec-refs-exist checker as a custom_script predicate (T40.5) ([abba87b](https://github.com/kazi-org/kazi/commit/abba87b97f19d283933b5044b68da751eb1f2cf7))


### Bug Fixes

* **loader:** intern gherkin doc-metadata atoms so spec-imported goals load in the release binary ([#1112](https://github.com/kazi-org/kazi/issues/1112)) ([e3952d9](https://github.com/kazi-org/kazi/commit/e3952d9ecef9902488cb86aab8a9d817bde271fa))

## [1.149.0](https://github.com/kazi-org/kazi/compare/v1.148.0...v1.149.0) (2026-07-15)


### Features

* **cli:** kazi spec import derives predicates from a .feature into a goal-file (T40.2, ADR-0050) ([d9976b8](https://github.com/kazi-org/kazi/commit/d9976b8efd36feb51b8d6021896d31a958de2b11))

## [1.148.0](https://github.com/kazi-org/kazi/compare/v1.147.1...v1.148.0) (2026-07-15)


### Features

* **dashboard:** Mission Control fleet home view, retiring the starmap ([2c40e41](https://github.com/kazi-org/kazi/commit/2c40e41dc1e058aa89c45f08fa67da19471c7415))

## [1.147.1](https://github.com/kazi-org/kazi/compare/v1.147.0...v1.147.1) (2026-07-15)


### Bug Fixes

* **scheduler:** collision-proof partition slug (full-key hash) + cross-process-unique nonce (T54.2, [#1074](https://github.com/kazi-org/kazi/issues/1074)) ([4dddc8b](https://github.com/kazi-org/kazi/commit/4dddc8bf3cc4771d60c47cc45076d3b39f4f8444))
* **scheduler:** salvage uncommitted collateral to a durable ref before worktree removal (T54.4, [#1081](https://github.com/kazi-org/kazi/issues/1081)) ([cf3863b](https://github.com/kazi-org/kazi/commit/cf3863b45563505909e743fc684dfc212ab0ce89))

## [1.147.0](https://github.com/kazi-org/kazi/compare/v1.146.0...v1.147.0) (2026-07-15)


### Features

* **bus:** client dials the daemon-advertised nats host/token; presence carries machine ([#1101](https://github.com/kazi-org/kazi/issues/1101), [#1102](https://github.com/kazi-org/kazi/issues/1102)) ([3cb07c0](https://github.com/kazi-org/kazi/commit/3cb07c0728123e544bee9c9cb2519c724ec6f4f3))
* **cli:** bus who shows the machine field ([#1102](https://github.com/kazi-org/kazi/issues/1102)) ([46c58b9](https://github.com/kazi-org/kazi/commit/46c58b935c27c0b1998961aeb1690fa54d7264fe))
* **daemon:** ping handshake surfaces nats host + token for the bus client ([#1101](https://github.com/kazi-org/kazi/issues/1101)) ([28fa313](https://github.com/kazi-org/kazi/commit/28fa313116ce8f8bbcc43739fee8b2fd008c060e))

## [1.146.0](https://github.com/kazi-org/kazi/compare/v1.145.0...v1.146.0) (2026-07-14)


### Features

* **adopt:** to_goal_file/1 renders a full goal map to a scaffold-free goal-file (T39.3, ADR-0049) ([873a6aa](https://github.com/kazi-org/kazi/commit/873a6aa6d178f07405dce081dcc57c66e68dfdd5))
* **cli:** approve --write materializes the approved goal to a loadable goal-file (T39.3, ADR-0049) ([466e73e](https://github.com/kazi-org/kazi/commit/466e73eb7b83d1aa24d706985770c5d9203cd35f))

## [1.145.0](https://github.com/kazi-org/kazi/compare/v1.144.0...v1.145.0) (2026-07-14)


### Features

* **mcp:** kazi_bus_watch tool + peek arg on kazi_bus_read (issue [#1091](https://github.com/kazi-org/kazi/issues/1091)) ([7f55212](https://github.com/kazi-org/kazi/commit/7f55212c846348173df64504fa06ef0300b042b4))

## [1.144.0](https://github.com/kazi-org/kazi/compare/v1.143.1...v1.144.0) (2026-07-14)


### Features

* **cli:** escript authoring refusal names the supported entrypoints (T39.5, ADR-0049) ([e964d2b](https://github.com/kazi-org/kazi/commit/e964d2b211bcee7b126d13247a9c108e6dbd690f))

## [1.143.1](https://github.com/kazi-org/kazi/compare/v1.143.0...v1.143.1) (2026-07-12)


### Bug Fixes

* **bus:** watch delivered a woken message twice via the stray signal copy ([281a8c6](https://github.com/kazi-org/kazi/commit/281a8c676a3e7b9e328bf469fe87ad19dd3d12a8))

## [1.143.0](https://github.com/kazi-org/kazi/compare/v1.142.0...v1.143.0) (2026-07-11)


### Features

* **bus:** watch, teams, document-sized messages, reconciled provisioning (issues [#1069](https://github.com/kazi-org/kazi/issues/1069), [#1091](https://github.com/kazi-org/kazi/issues/1091)) ([2986647](https://github.com/kazi-org/kazi/commit/298664759502be30194fc87cafd3d7cf0edd6f55))

## [1.142.0](https://github.com/kazi-org/kazi/compare/v1.141.0...v1.142.0) (2026-07-11)


### Features

* **cli:** --nats-host / --nats-token flags for daemon start ([e7e971a](https://github.com/kazi-org/kazi/commit/e7e971a74ec154836bb5ea2ba5e9a696a61e9061))
* **daemon:** nats-server connect-mode for cross-machine bus (ADR-0067) ([c445b40](https://github.com/kazi-org/kazi/commit/c445b40d9d57f2439b6b1712ac9faef3a187f9ec))
* **daemon:** thread remote nats host/token through start/1 and provisioning ([22d29bd](https://github.com/kazi-org/kazi/commit/22d29bd016b892923e970e4a5bb40f86450b28d5))


### Bug Fixes

* **bus:** deliver directed messages across scopes (issue [#1065](https://github.com/kazi-org/kazi/issues/1065)) ([ad5b122](https://github.com/kazi-org/kazi/commit/ad5b122fd21b775b0223f9a531c434e4bb1022d5))
* **read-model:** bound the migration lock wait instead of hanging (issue [#1019](https://github.com/kazi-org/kazi/issues/1019)) ([1e4cccb](https://github.com/kazi-org/kazi/commit/1e4cccbe6ef712d9d33bb89e588a3b5032d87cb9))
* **read-model:** refuse to migrate a schema newer than this binary knows (issue [#1019](https://github.com/kazi-org/kazi/issues/1019)) ([4352f24](https://github.com/kazi-org/kazi/commit/4352f24da4a8b529f4f223b949aec6a4057df801))
* **release:** load kazi modules at boot instead of lazily (issue [#1006](https://github.com/kazi-org/kazi/issues/1006)) ([1cf1d59](https://github.com/kazi-org/kazi/commit/1cf1d5928167c89a7a36adf4c24ba23c2cec043f))

## [1.141.0](https://github.com/kazi-org/kazi/compare/v1.140.3...v1.141.0) (2026-07-11)


### Features

* **bus:** default post kind to fact, add bus peek, per-verb --help (issue [#1059](https://github.com/kazi-org/kazi/issues/1059), [#1060](https://github.com/kazi-org/kazi/issues/1060)) ([c54ed44](https://github.com/kazi-org/kazi/commit/c54ed444363bbb61405d755958b68b17832707c5))
* **dashboard:** add stateless JSON API for runs and goals (issue [#1077](https://github.com/kazi-org/kazi/issues/1077)) ([fa3b39b](https://github.com/kazi-org/kazi/commit/fa3b39b93642db751263d6282cbed5928c0d1c93))


### Bug Fixes

* **fleet:** carry crash reason + let a landed member's dependent dispatch (issue [#1053](https://github.com/kazi-org/kazi/issues/1053)) ([d32576e](https://github.com/kazi-org/kazi/commit/d32576e9282d2d9aa6b06ae554e07be017c7cd99))
* **scheduler:** worktree teardown independence + base protection (issue [#1053](https://github.com/kazi-org/kazi/issues/1053)) ([b4b743d](https://github.com/kazi-org/kazi/commit/b4b743dcee743a55f8082b8f62b8a527c2052f49))

## [1.140.3](https://github.com/kazi-org/kazi/compare/v1.140.2...v1.140.3) (2026-07-11)


### Bug Fixes

* **ci:** install nats-server on CI runners for daemon tests (issue [#1061](https://github.com/kazi-org/kazi/issues/1061)) ([4b5d256](https://github.com/kazi-org/kazi/commit/4b5d256bd8fadea907a4dad8b22d5c81a4dfa5d7))

## [1.140.2](https://github.com/kazi-org/kazi/compare/v1.140.1...v1.140.2) (2026-07-10)


### Bug Fixes

* **read_model:** warn on a dropped harness_session_id write (issue [#1013](https://github.com/kazi-org/kazi/issues/1013)) ([2999764](https://github.com/kazi-org/kazi/commit/2999764fd6173c643352de2faa2af2648b997721))
* **runtime:** register run before starting the loop (issue [#1013](https://github.com/kazi-org/kazi/issues/1013)) ([406e8ef](https://github.com/kazi-org/kazi/commit/406e8ef5f59add0f75d58bcf6828951807d43573))

## [1.140.1](https://github.com/kazi-org/kazi/compare/v1.140.0...v1.140.1) (2026-07-10)


### Bug Fixes

* **loop:** bound :integrate execute/2 by a wall-clock timeout ([#1020](https://github.com/kazi-org/kazi/issues/1020)) ([59c7ffe](https://github.com/kazi-org/kazi/commit/59c7ffe9ec073551574ca25bddfd76de744d8d3f))

## [1.140.0](https://github.com/kazi-org/kazi/compare/v1.139.0...v1.140.0) (2026-07-10)


### Features

* **scheduler:** T53.2 worktree liveness guard ([#1022](https://github.com/kazi-org/kazi/issues/1022)) ([0056dfe](https://github.com/kazi-org/kazi/commit/0056dfed093d11051013aeca0f4a236594f1ce94))

## [1.139.0](https://github.com/kazi-org/kazi/compare/v1.138.0...v1.139.0) (2026-07-10)


### Features

* **mcp:** T51.3 kazi_bus_post|read|who|tell tools + session-bus docs (ADR-0067) ([fea9af9](https://github.com/kazi-org/kazi/commit/fea9af9185ccacf2d97059be20ab3ef6a35d1d9a))

## [1.138.0](https://github.com/kazi-org/kazi/compare/v1.137.0...v1.138.0) (2026-07-10)


### Features

* **bus:** T51.2 kazi bus post|read|who|tell over daemon NATS (ADR-0067) ([032b1a0](https://github.com/kazi-org/kazi/commit/032b1a07bbb01e08be04e816a3e94dadf3eaca95))

## [1.137.0](https://github.com/kazi-org/kazi/compare/v1.136.1...v1.137.0) (2026-07-10)


### Features

* **daemon:** T51.1 kazi daemon lifecycle skeleton (ADR-0067) ([e7fcaa6](https://github.com/kazi-org/kazi/commit/e7fcaa611c8a8fc2c6c2ccdce4f5efed26ca279f))

## [1.136.1](https://github.com/kazi-org/kazi/compare/v1.136.0...v1.136.1) (2026-07-10)


### Bug Fixes

* **integrate:** treat already-landed workspaces as a no-op ([#1027](https://github.com/kazi-org/kazi/issues/1027)) ([cb6b776](https://github.com/kazi-org/kazi/commit/cb6b7764fa96926e9901459896116713811371d9))

## [1.136.0](https://github.com/kazi-org/kazi/compare/v1.135.0...v1.136.0) (2026-07-10)


### Features

* **cli:** surface --pause-between-waves/--resume as documented flags (T50.6) ([81b7a70](https://github.com/kazi-org/kazi/commit/81b7a70de016e16492e4229aaf1b7a14d8f43acf))

## [1.135.0](https://github.com/kazi-org/kazi/compare/v1.134.0...v1.135.0) (2026-07-10)


### Features

* **cli:** kazi apply --fleet executes; --fleet-concurrency caps member parallelism (T50.5) ([a28eaf0](https://github.com/kazi-org/kazi/commit/a28eaf0afab4195a3d174506eac2a745e6e7b8e7))
* **fleet:** execute the fleet DAG through DepScheduler one level up (T50.5) ([2abf7d1](https://github.com/kazi-org/kazi/commit/2abf7d156be1443f807733d6a898ebdca0aacb44))

## [1.134.0](https://github.com/kazi-org/kazi/compare/v1.133.0...v1.134.0) (2026-07-09)


### Features

* **cli:** kazi apply --base &lt;ref&gt; selects the task worktree base (T50.8) ([ad9336e](https://github.com/kazi-org/kazi/commit/ad9336e5ccf9956aa9c06f1f944f13c7a708dfe7))
* **scheduler:** worktree base ref is a parameter with a fresh-base check ([f0547a1](https://github.com/kazi-org/kazi/commit/f0547a17644d0fe0077b361e146a585f135dbe8d))

## [1.133.0](https://github.com/kazi-org/kazi/compare/v1.132.0...v1.133.0) (2026-07-09)


### Features

* **cli:** a converged serial worktree run lands on the base by rebase-merge ([12910ee](https://github.com/kazi-org/kazi/commit/12910ee71cfcb94bfd8ffbccef4cebd13eaa4a18))
* **scheduler:** LocalIntegrator -- remote-less rebase-merge landing ([8e1731d](https://github.com/kazi-org/kazi/commit/8e1731d8e0adba27278a370760f6834b9195812b))


### Bug Fixes

* **actions:** integrate tolerates an already-committed task branch ([aefe49b](https://github.com/kazi-org/kazi/commit/aefe49bb61d9c561d31f425417f220dd43f1edf4))
* **cli:** serial landing only lands the kazi-owned task branch ([05bfcd4](https://github.com/kazi-org/kazi/commit/05bfcd414f56f4177625d6ca8b398c599d7ceab9))

## [1.132.0](https://github.com/kazi-org/kazi/compare/v1.131.2...v1.132.0) (2026-07-09)


### Features

* **cli:** serial apply isolates into a task worktree by default ([00104dc](https://github.com/kazi-org/kazi/commit/00104dce97847633121fc38f5b7e0b74d66d5084))

## [1.131.2](https://github.com/kazi-org/kazi/compare/v1.131.1...v1.131.2) (2026-07-09)


### Bug Fixes

* **release:** pin burrito to the kazi-org payload-liveness fork ([#1018](https://github.com/kazi-org/kazi/issues/1018)) ([a25bc72](https://github.com/kazi-org/kazi/commit/a25bc72e59560628ea947ea2bc0c9ea80d6e4ce0))

## [1.131.1](https://github.com/kazi-org/kazi/compare/v1.131.0...v1.131.1) (2026-07-09)


### Bug Fixes

* **dashboard:** session-pid walk recorded the wrong ancestor; LIVE shows elapsed runtime ([49e8ef5](https://github.com/kazi-org/kazi/commit/49e8ef56a82118052d8b906b3a3c0684b93e905b))

## [1.131.0](https://github.com/kazi-org/kazi/compare/v1.130.0...v1.131.0) (2026-07-09)


### Features

* **dashboard:** fleet-tile filter lifts the state-column cap ([bf74908](https://github.com/kazi-org/kazi/commit/bf74908040ba30ba2c5dc2025be2325c73c7a0a5))
* **dashboard:** richer starmap drill-in panel ([16b8069](https://github.com/kazi-org/kazi/commit/16b8069c17c11bdcf81e967bd1a51fa6a589512f))
* **goal:** optional top-level description field ([af1884f](https://github.com/kazi-org/kazi/commit/af1884f20de5f37f262e8ecc64ff0d5fe74c8eff))
* **read-model:** capture goal name + description on the run row ([b35062c](https://github.com/kazi-org/kazi/commit/b35062c35c61b5abad775fdf420a1c8575781422))

## [1.130.0](https://github.com/kazi-org/kazi/compare/v1.129.0...v1.130.0) (2026-07-09)


### Features

* **cli:** wire kazi apply --fleet &lt;dir|manifest&gt; --explain (T50.4) ([e00fac9](https://github.com/kazi-org/kazi/commit/e00fac9cd3574864cf11f5b2e03790f07eca75dc))
* **fleet:** add Kazi.Fleet -- goal-DAG discovery across goal-files (T50.4) ([b247adf](https://github.com/kazi-org/kazi/commit/b247adf9b5f8d5f6977f2351689ae5635f88236c))

## [1.129.0](https://github.com/kazi-org/kazi/compare/v1.128.0...v1.129.0) (2026-07-09)


### Features

* **dashboard:** session-scope toggle (CURRENT/CLOSED) + viewport-locked layout ([3a95d7d](https://github.com/kazi-org/kazi/commit/3a95d7d12e1d4e7e3a606570c94df32295148d19))

## [1.128.0](https://github.com/kazi-org/kazi/compare/v1.127.0...v1.128.0) (2026-07-09)


### Features

* **runtime:** kazi never hangs on its own telemetry (read-model Guard) ([f2a41b7](https://github.com/kazi-org/kazi/commit/f2a41b72002222ae09e03dbacd26757f72951b10))

## [1.127.0](https://github.com/kazi-org/kazi/compare/v1.126.1...v1.127.0) (2026-07-09)


### Features

* **dashboard:** honest state columns in the no-roadmap starmap fallback ([b136c83](https://github.com/kazi-org/kazi/commit/b136c83f39ea497f8f28a30cce62936824ac9783))

## [1.126.1](https://github.com/kazi-org/kazi/compare/v1.126.0...v1.126.1) (2026-07-09)


### Bug Fixes

* **repo:** 60s SQLite busy_timeout on the shared read-model DB ([35bfbbf](https://github.com/kazi-org/kazi/commit/35bfbbfbaf5fc42748d3cd7851ea028c8c36f542))

## [1.126.0](https://github.com/kazi-org/kazi/compare/v1.125.0...v1.126.0) (2026-07-09)


### Features

* **read-model:** add pause_checkpoints table for scheduler resume state (T50.3) ([1a97af6](https://github.com/kazi-org/kazi/commit/1a97af6d9e6ab02b0772369d62250ebc71b0e49b))
* **scheduler:** DepScheduler stops at frontier boundary with --pause-between-waves, resumes from checkpoint (T50.3) ([ccded1c](https://github.com/kazi-org/kazi/commit/ccded1c8667585534020cb426670e298b5ee44dd))

## [1.125.0](https://github.com/kazi-org/kazi/compare/v1.124.0...v1.125.0) (2026-07-09)


### Features

* **cli:** kazi status with no ref lists LIVE runs (issue [#971](https://github.com/kazi-org/kazi/issues/971)) ([f565f80](https://github.com/kazi-org/kazi/commit/f565f808c496d001f06ae3c6b37e3ebd1453dd14))
* **memory:** scope memory_index_files by workspace_root ([#977](https://github.com/kazi-org/kazi/issues/977)) ([60e0cbc](https://github.com/kazi-org/kazi/commit/60e0cbcb3a8d9b12a3baf55c51f4b9936f5ff505))


### Bug Fixes

* **memory:** thread workspace_root through indexing and recall ([#977](https://github.com/kazi-org/kazi/issues/977)) ([444844d](https://github.com/kazi-org/kazi/commit/444844d1304f837901410e7e8ae0ca429bc97d89))

## [1.124.0](https://github.com/kazi-org/kazi/compare/v1.123.0...v1.124.0) (2026-07-09)


### Features

* **loop:** record attempt_ledger_tokens/memory_recall_tokens in context ([#978](https://github.com/kazi-org/kazi/issues/978)) ([b95b0e8](https://github.com/kazi-org/kazi/commit/b95b0e838e5a34cf5b56456f0277eb4a44b2fb0d))
* **mcp:** nudge toward `kazi init --with-mcp` when unconfigured ([#972](https://github.com/kazi-org/kazi/issues/972)) ([5ad1326](https://github.com/kazi-org/kazi/commit/5ad13266d608ad147544324b37f9f36d2d02c540))

## [1.123.0](https://github.com/kazi-org/kazi/compare/v1.122.0...v1.123.0) (2026-07-09)


### Features

* **authoring:** implementation-brief depth is the authoring default ([e9f43a3](https://github.com/kazi-org/kazi/commit/e9f43a3d50d7f72c8f724dd84d546148dfede0da))

## [1.122.0](https://github.com/kazi-org/kazi/compare/v1.121.0...v1.122.0) (2026-07-09)


### Features

* **teach:** flip installed SKILL.md default grind tier to claude-sonnet-5 ([84e29ff](https://github.com/kazi-org/kazi/commit/84e29ff42e32bf3f92787160032604908a1f12fe))
* **teach:** teach the apply safety refusals, current subsumption status, live-economy grounding ([#955](https://github.com/kazi-org/kazi/issues/955), [#957](https://github.com/kazi-org/kazi/issues/957), [#958](https://github.com/kazi-org/kazi/issues/958)) ([ae8c6cf](https://github.com/kazi-org/kazi/commit/ae8c6cf256736dba9f4cbd9992fb16d3c79818d6))

## [1.121.0](https://github.com/kazi-org/kazi/compare/v1.120.0...v1.121.0) (2026-07-09)


### Features

* **config:** KAZI_ATTEMPT_LEDGER / KAZI_MEMORY_RECALL runtime env hooks ([c2e2394](https://github.com/kazi-org/kazi/commit/c2e2394b41698d4631ab3a1801001c3430f4855a))

## [1.120.0](https://github.com/kazi-org/kazi/compare/v1.119.2...v1.120.0) (2026-07-09)


### Features

* **authoring:** thread session_name through plan, proposal_ref through apply ([e3cb0e5](https://github.com/kazi-org/kazi/commit/e3cb0e55b8a6f228f0edfe7c5ae7472992f90319))
* **authoring:** warn on vacuous naked-grep acceptance predicates ([8ba86ca](https://github.com/kazi-org/kazi/commit/8ba86ca307acee4276506bdc455dc127382d03a9))
* **scheduler:** emit frontier_complete stream event at needs-DAG wave boundaries ([11401f4](https://github.com/kazi-org/kazi/commit/11401f49f6bad366e301d180eccdeff0ad44159f))


### Bug Fixes

* **authoring:** reject an unloadable proposal ([#945](https://github.com/kazi-org/kazi/issues/945)) ([13ee078](https://github.com/kazi-org/kazi/commit/13ee07859a12f00e17c3d481e7a8480e2fac2462))

## [1.119.2](https://github.com/kazi-org/kazi/compare/v1.119.1...v1.119.2) (2026-07-09)


### Bug Fixes

* **authoring:** stop clarify's endpoint sniff naked-grepping prose slashes ([412e56e](https://github.com/kazi-org/kazi/commit/412e56ef36904caed1ec8fc0027bc9251c06fcfb))

## [1.119.1](https://github.com/kazi-org/kazi/compare/v1.119.0...v1.119.1) (2026-07-09)


### Bug Fixes

* **repo:** stop .kazi/goals/ from being silently swallowed by .gitignore ([affe2d7](https://github.com/kazi-org/kazi/commit/affe2d7761b11d74b3bee5a465834da373e29540))

## [1.119.0](https://github.com/kazi-org/kazi/compare/v1.118.0...v1.119.0) (2026-07-09)


### Features

* **authoring:** honor a caller-drafts payload's goal_id and idea (T39.1, ADR-0049) ([36f84c2](https://github.com/kazi-org/kazi/commit/36f84c25a90d5a0282e1e09e99f5ba11c1b481fa))
* **cli:** apply accepts an approved proposal's prop- ref, no goal-file (T39.2, ADR-0049) ([ca32986](https://github.com/kazi-org/kazi/commit/ca32986e465d9cfb3fe5bd5c9043c0e7e0589b8d))

## [1.118.0](https://github.com/kazi-org/kazi/compare/v1.117.0...v1.118.0) (2026-07-09)


### Features

* **harness:** thread the run's workspace into the opencode argv as --dir (T39.7) ([a1d7ffa](https://github.com/kazi-org/kazi/commit/a1d7ffadf54a716ea8ed6959c24adba788db2efd))

## [1.117.0](https://github.com/kazi-org/kazi/compare/v1.116.0...v1.117.0) (2026-07-09)


### Features

* **cli:** redirect logging off stdout for --json runs (E39 T39.4, issue [#804](https://github.com/kazi-org/kazi/issues/804)) ([f031721](https://github.com/kazi-org/kazi/commit/f0317219a21fe6a1394de7fffde0e046a7e21f85))

## [1.116.0](https://github.com/kazi-org/kazi/compare/v1.115.0...v1.116.0) (2026-07-08)


### Features

* **runtime:** refuse a second apply while a LIVE run holds the same goal ([#941](https://github.com/kazi-org/kazi/issues/941)-incident) ([8904ad1](https://github.com/kazi-org/kazi/commit/8904ad159d76f5acdadac6d2a82b52f91d9b0bf6))

## [1.115.0](https://github.com/kazi-org/kazi/compare/v1.114.0...v1.115.0) (2026-07-08)


### Features

* **cli:** refuse an executing apply against a primary-worktree workspace ([#937](https://github.com/kazi-org/kazi/issues/937) Gap A) ([c8b357b](https://github.com/kazi-org/kazi/commit/c8b357b1b84585f38375783213391a4cfd778554))

## [1.114.0](https://github.com/kazi-org/kazi/compare/v1.113.0...v1.114.0) (2026-07-08)


### Features

* **repo:** pre-push guard for the auto-releasing main + committed hooks dir ([939c955](https://github.com/kazi-org/kazi/commit/939c9553dbd242d873b09a610e361534ca376949))

## [1.113.0](https://github.com/kazi-org/kazi/compare/v1.112.3...v1.113.0) (2026-07-08)


### Features

* **cli:** auto-detect CLAUDE_CODE_SESSION_ID as a session_name fallback ([04d323a](https://github.com/kazi-org/kazi/commit/04d323aca67d0bd3100254786e3aa9b9b3cc717e))

## [1.112.3](https://github.com/kazi-org/kazi/compare/v1.112.2...v1.112.3) (2026-07-08)


### Bug Fixes

* **logging:** resolve dashboard.log path at runtime, not compile time ([b0b5565](https://github.com/kazi-org/kazi/commit/b0b55659cce92705a24229c0119598d68b95eff1))

## [1.112.2](https://github.com/kazi-org/kazi/compare/v1.112.1...v1.112.2) (2026-07-08)


### Bug Fixes

* **cli:** wire the run reaper ticker + log rotation into standalone dashboard boot ([1bf09b4](https://github.com/kazi-org/kazi/commit/1bf09b4a1912d47a3cc0b80d65d7997c7567fb7c))

## [1.112.1](https://github.com/kazi-org/kazi/compare/v1.112.0...v1.112.1) (2026-07-08)


### Bug Fixes

* **cli:** start the read-model before kazi memory subcommands ([ca0c4b0](https://github.com/kazi-org/kazi/commit/ca0c4b093f5b9f353e5d7ce312f6e3fab87608bd))

## [1.112.0](https://github.com/kazi-org/kazi/compare/v1.111.0...v1.112.0) (2026-07-08)


### Features

* **cli:** kazi memory list-proposed / approve / reject (ADR-0063) ([6397f3e](https://github.com/kazi-org/kazi/commit/6397f3e5aebd59d81b71b586b8add59cc416f3c1))
* **memory:** deterministic harvest + gated promotion (ADR-0063) ([25a9347](https://github.com/kazi-org/kazi/commit/25a934775b7202d6fa8da773e0737dbdb92ef7ca))
* **read_model:** proposed-memory store for gated harvest (ADR-0063) ([dfc4da4](https://github.com/kazi-org/kazi/commit/dfc4da42ddd0aa534a4f3630a06b7b3f216e35a0))

## [1.111.0](https://github.com/kazi-org/kazi/compare/v1.110.0...v1.111.0) (2026-07-08)


### Features

* **cli:** kazi memory recall -- budgeted FTS recall verb (ADR-0062) ([eba66f5](https://github.com/kazi-org/kazi/commit/eba66f5359c72b53694c5fee9bb9ae3316d89843))
* **goal:** [memory] corpus override for semantic recall (ADR-0062) ([39957ee](https://github.com/kazi-org/kazi/commit/39957eef4e35238293ed3421cc0f159569751daa))
* **loop:** inject semantic recall into the dispatch prompt, default off (ADR-0062) ([223c4e9](https://github.com/kazi-org/kazi/commit/223c4e918ff199cf6fdaf38012d85b60496febea))
* **memory:** SemanticIndex -- budgeted FTS5 recall over git-native corpus (ADR-0062) ([24d8595](https://github.com/kazi-org/kazi/commit/24d8595cee49c3b2b99e8c5e87503b69b8f55989))

## [1.110.0](https://github.com/kazi-org/kazi/compare/v1.109.0...v1.110.0) (2026-07-08)


### Features

* **memory:** episodic attempt ledger (ADR-0061) ([cece52e](https://github.com/kazi-org/kazi/commit/cece52e372617f3ea85f47ded8f86697e10bbb36))

## [1.109.0](https://github.com/kazi-org/kazi/compare/v1.108.0...v1.109.0) (2026-07-08)


### Features

* **read-model:** wire RunReaper.reap/0 into a periodic ticker ([bc7e868](https://github.com/kazi-org/kazi/commit/bc7e86886b32be52db19db62b44f18a5653f7d48))

## [1.108.0](https://github.com/kazi-org/kazi/compare/v1.107.0...v1.108.0) (2026-07-08)


### Features

* **run-liveness:** add os_pid field for reap detection ([b39e718](https://github.com/kazi-org/kazi/commit/b39e718fea5e001ad6bb2a3e02a67d6e942da48a))
* **run-liveness:** implement reaper for OS process liveness detection ([bb07f1b](https://github.com/kazi-org/kazi/commit/bb07f1bd74155a43207d090bb515d15cd518b152))
* **run-liveness:** populate os_pid at registration for reap detection ([7c58995](https://github.com/kazi-org/kazi/commit/7c589952e67133d4bab435b2d9804602c650defe))
* **runtime:** trap OS termination signals so externally-killed runs finalize ([132410f](https://github.com/kazi-org/kazi/commit/132410fccf78c66f2226ed68ee13d26fe78a8b3f))


### Bug Fixes

* **test:** checkout sandbox connection in run reaper tests (T48.15) ([7e6c8fe](https://github.com/kazi-org/kazi/commit/7e6c8fe604f47f7f916f25485fe12e9a0f61c1f8))
* **test:** correct run reaper liveness detection tests ([04fe3a2](https://github.com/kazi-org/kazi/commit/04fe3a21c6cfdb617206c03ed3ce02416f670f45))

## [1.107.0](https://github.com/kazi-org/kazi/compare/v1.106.0...v1.107.0) (2026-07-08)


### Features

* **logging:** bound logger level in production to prevent dashboard spam ([503ff39](https://github.com/kazi-org/kazi/commit/503ff39e423cbe757aa33e679826ad5743bcd1d2))
* **logging:** implement dashboard log rotation to prevent unbounded growth ([30f0242](https://github.com/kazi-org/kazi/commit/30f0242ee469e925005a2e42329b7319b15a6f78))
* **logging:** implement dashboard log rotation to prevent unbounded growth ([cceb452](https://github.com/kazi-org/kazi/commit/cceb45272f97bbde116a0df8380114fa3d3540e3))


### Bug Fixes

* **logging:** replace tautological test with actual assertion ([da40b75](https://github.com/kazi-org/kazi/commit/da40b7593cb1adba345fb5eaeaab4de203b377e6))

## [1.106.0](https://github.com/kazi-org/kazi/compare/v1.105.0...v1.106.0) (2026-07-08)


### Features

* **read-model:** add wall-clock heartbeat ticker for run liveness ([6680198](https://github.com/kazi-org/kazi/commit/66801983ee92e1e72f932ae54245f48819583276))

## [1.105.0](https://github.com/kazi-org/kazi/compare/v1.104.0...v1.105.0) (2026-07-07)


### Features

* **dashboard:** attention queue ranks by terminal cause (T48.14) ([2cdca96](https://github.com/kazi-org/kazi/commit/2cdca966805b647948133b670b14e0e22ee21429))
* **dashboard:** render cause-ranked attention-queue entries (T48.14) ([3040b76](https://github.com/kazi-org/kazi/commit/3040b7679e077b5985fea4f2bc5af9293eb6d96d))
* **loop:** extract cause-line formatter for reuse (T48.14) ([99c4887](https://github.com/kazi-org/kazi/commit/99c4887debd181f124efb72a52667665ecc53ccd))

## [1.104.0](https://github.com/kazi-org/kazi/compare/v1.103.1...v1.104.0) (2026-07-07)


### Features

* **cli:** plan/init surface a learned [budget] suggestion (T48.9) ([45fc606](https://github.com/kazi-org/kazi/commit/45fc606505fbec3b80ce60ae4c79268074555d3c))
* **economy:** learned budget suggestion derivation (T48.9, ADR-0058) ([ec83b16](https://github.com/kazi-org/kazi/commit/ec83b16180f5502d685858a82a1355f6b37bd224))
* **economy:** pool run history across a shape bucket (T48.9) ([2dd2055](https://github.com/kazi-org/kazi/commit/2dd20558f2ebd6f7af29696db4a2f53298975634))

## [1.103.1](https://github.com/kazi-org/kazi/compare/v1.103.0...v1.103.1) (2026-07-07)


### Bug Fixes

* **test:** url-less live wedge now asserts the T48.1 load rejection ([ba9d07f](https://github.com/kazi-org/kazi/commit/ba9d07f190a4df336394933b4f2e43624e4d9634))

## [1.103.0](https://github.com/kazi-org/kazi/compare/v1.102.0...v1.103.0) (2026-07-07)


### Features

* **bench:** prompt/context-variant arms + benchmark gate (T48.12) ([8205860](https://github.com/kazi-org/kazi/commit/8205860a3a38d73270797b7f68abfc08ab8139a7))

## [1.102.0](https://github.com/kazi-org/kazi/compare/v1.101.0...v1.102.0) (2026-07-07)


### Features

* **cli:** surface honest cause in run --json (T48.4) ([68fb99d](https://github.com/kazi-org/kazi/commit/68fb99dd703d01aca0ffd400466a2fd01c2bc02b))
* **dashboard:** show honest cause in the drill-in panel (T48.4) ([34586ee](https://github.com/kazi-org/kazi/commit/34586ee2ca56bf847f936bac445ba21e877373c8))
* **loop:** honest terminal cause classifier (T48.4, ADR-0058 decision 4) ([2231ef2](https://github.com/kazi-org/kazi/commit/2231ef2f9d66f4eb490d954a2e8edfe3f4a23c71))
* **read-model:** add outcome_cause_detail field to Run schema (T48.4) ([fd1c047](https://github.com/kazi-org/kazi/commit/fd1c04718ec1603cf531d11644dd482136d68a4f))
* **read-model:** migrate runs table for honest terminal cause detail (T48.4) ([e316869](https://github.com/kazi-org/kazi/commit/e3168693723c6cba0e5daa6aa5b13625aa58ccc4))
* **runtime:** project honest cause onto the read-model (T48.4) ([9a40379](https://github.com/kazi-org/kazi/commit/9a403792d48612bd6105a8b8bccc655e2893f8f0))

## [1.101.0](https://github.com/kazi-org/kazi/compare/v1.100.0...v1.101.0) (2026-07-07)


### Features

* **cli:** kazi economy --rediscovery -- ranked rediscovery-pressure report (T48.10) ([3b6ceb4](https://github.com/kazi-org/kazi/commit/3b6ceb42fd3d04ceb9ed0dd1040e3c3df1cdc043))
* **economy:** rediscovery-pressure fold from recorded tool counters (T48.10) ([8cd289a](https://github.com/kazi-org/kazi/commit/8cd289a7b5899bf01bfa1845b2c550ac0b279f3c))

## [1.100.0](https://github.com/kazi-org/kazi/compare/v1.99.0...v1.100.0) (2026-07-07)


### Features

* **cli:** kazi economy -- run-economics history over the read-model (T48.8) ([c80bade](https://github.com/kazi-org/kazi/commit/c80bade3a24fe8b2bf32768e72be94a8ce8f3664))
* **economy:** run-economics history aggregation (T48.8, ADR-0058) ([c36bbf7](https://github.com/kazi-org/kazi/commit/c36bbf7090c51bb007a1228b11c30003828e03a6))

## [1.99.0](https://github.com/kazi-org/kazi/compare/v1.98.1...v1.99.0) (2026-07-07)


### Features

* **economy:** add debrief_hypotheses read-model table (T48.11) ([f19f70e](https://github.com/kazi-org/kazi/commit/f19f70e222c713e9af7314e5e52265d1a1d3d1b9))
* **economy:** opt-in post-dispatch debrief capture as hypotheses (T48.11) ([5dcbbb6](https://github.com/kazi-org/kazi/commit/5dcbbb60b5ad650709e619f4a3c6fbf6049ea056))

## [1.98.1](https://github.com/kazi-org/kazi/compare/v1.98.0...v1.98.1) (2026-07-07)


### Bug Fixes

* **examples:** http_probe predicates carry url, not dead path config ([4d3b817](https://github.com/kazi-org/kazi/commit/4d3b817539fceb299c2b8721590d12bb85792a88))
* **loader:** validate live predicate url at goal-load (T48.1) ([238e1f5](https://github.com/kazi-org/kazi/commit/238e1f5754b777e2a17c18795480ef0b1f1a3735))

## [1.98.0](https://github.com/kazi-org/kazi/compare/v1.97.0...v1.98.0) (2026-07-07)


### Features

* **loop:** live permanent-error stuck detection (T48.3) ([2433840](https://github.com/kazi-org/kazi/commit/2433840517f3a93af9657c01a6192f5364612ef9))

## [1.97.0](https://github.com/kazi-org/kazi/compare/v1.96.0...v1.97.0) (2026-07-07)


### Features

* **cli:** surface usage_fidelity on the run --json result ([53fff04](https://github.com/kazi-org/kazi/commit/53fff04db13a6321abbae9d49d9fa640639348e3))
* **loop:** warn once per run when max_tokens is set but usage is unreported ([c1c152d](https://github.com/kazi-org/kazi/commit/c1c152d8278699234dc2ff03b4f3815ce951ff0d))

## [1.96.0](https://github.com/kazi-org/kazi/compare/v1.95.0...v1.96.0) (2026-07-07)


### Features

* **budget:** max_dispatches dimension -- dispatches, not ticks ([2e1a929](https://github.com/kazi-org/kazi/commit/2e1a929e3bfe5f0e30fef6ec5d48e448bb723123))


### Bug Fixes

* **loop:** single dispatches counter after T48.7 rebase ([6d734c4](https://github.com/kazi-org/kazi/commit/6d734c4a3257652df6db670dd7f57ff396c438d8))

## [1.95.0](https://github.com/kazi-org/kazi/compare/v1.94.0...v1.95.0) (2026-07-07)


### Features

* **loop:** surface dispatch count, context tier, and goal shape (T48.7) ([fea4bd4](https://github.com/kazi-org/kazi/commit/fea4bd4d4ff2466df4b15a42d46543fb37ff1fa9))
* **read-model:** migrate runs table for run-end economics (T48.7) ([7a6bd1c](https://github.com/kazi-org/kazi/commit/7a6bd1c735dbb0a5bef533b47d511284dbed1976))
* **read-model:** persist run-end economics via RunRegistry.finish/3 (T48.7) ([fae43e6](https://github.com/kazi-org/kazi/commit/fae43e6da677ae628a2468f3a721442964cf3125))
* **runtime:** project run-end economics onto RunRegistry.finish (T48.7) ([142502a](https://github.com/kazi-org/kazi/commit/142502adb88038b706c13ad9c77370aa8d8b136b))

## [1.94.0](https://github.com/kazi-org/kazi/compare/v1.93.1...v1.94.0) (2026-07-07)


### Features

* **loop:** error permanence taxonomy (permanent vs transient) ([9cd7a68](https://github.com/kazi-org/kazi/commit/9cd7a686335ad688b2b9a0cc66b21486f1a6bbdd))

## [1.93.1](https://github.com/kazi-org/kazi/compare/v1.93.0...v1.93.1) (2026-07-07)


### Bug Fixes

* **dashboard:** LV socket dead on released binary -- check_origin :conn for standalone boots ([f958e4d](https://github.com/kazi-org/kazi/commit/f958e4d7fcc360912b997fe2b104949eaf46d62b))

## [1.93.0](https://github.com/kazi-org/kazi/compare/v1.92.0...v1.93.0) (2026-07-07)


### Features

* **dashboard:** mobile bottom-tab layout for the starmap ([dbb1d30](https://github.com/kazi-org/kazi/commit/dbb1d3093c8b2193c57d68b89478712aa4f7184b))

## [1.92.0](https://github.com/kazi-org/kazi/compare/v1.91.0...v1.92.0) (2026-07-07)


### Features

* **dashboard:** serve the starmap at the root route ([df42a63](https://github.com/kazi-org/kazi/commit/df42a63483f6b4999f4fe6a6f16905cca0fd1d4d))

## [1.91.0](https://github.com/kazi-org/kazi/compare/v1.90.0...v1.91.0) (2026-07-07)


### Features

* **harness:** tie the dispatched child's lifetime to the controller ([57ac3e1](https://github.com/kazi-org/kazi/commit/57ac3e1827a799708523d14a9cbb0c1f478bbac8))
* **registry:** record the dispatched harness subprocess's OS pid ([1b66c9d](https://github.com/kazi-org/kazi/commit/1b66c9d169b5033543a4295e591ccdc178719570))
* warn loudly when a resumed goal's prior harness pid is still alive ([2301820](https://github.com/kazi-org/kazi/commit/230182087a13d56483c3e93064a5a61db3d933d3))


### Bug Fixes

* **harness:** portable child supervision -- setsid groups, env kill, jobless watchdog ([d93523a](https://github.com/kazi-org/kazi/commit/d93523a8ea4ad894ecc3dda90c145802aa399f11))

## [1.90.0](https://github.com/kazi-org/kazi/compare/v1.89.0...v1.90.0) (2026-07-07)


### Features

* **cli:** terminal collateral field for out-of-write-scope changes ([55c14d4](https://github.com/kazi-org/kazi/commit/55c14d4cb52e91988ef612018d0509a28e4b6c95))
* **goal:** [scope] gains write_paths and deny (issue [#860](https://github.com/kazi-org/kazi/issues/860)) ([0c1b097](https://github.com/kazi-org/kazi/commit/0c1b0971c9002e6b6f6061c5beaac23dcc4c846e))
* **providers:** scope_guard predicate provider for deny-path violations ([ebb1721](https://github.com/kazi-org/kazi/commit/ebb172185d0b3e99271405bb40aef82d674c4407))

## [1.89.0](https://github.com/kazi-org/kazi/compare/v1.88.0...v1.89.0) (2026-07-07)


### Features

* **boot:** pin erl_crash.dump under kazi's state dir + diagnose binary swaps ([88ad45b](https://github.com/kazi-org/kazi/commit/88ad45bfa2ed1ca2533793e8f605be00fecfe9b9)), closes [#856](https://github.com/kazi-org/kazi/issues/856)

## [1.88.0](https://github.com/kazi-org/kazi/compare/v1.87.0...v1.88.0) (2026-07-06)


### Features

* **web:** fleet-tile filters + single-column bands with vertical scroll ([865f5c4](https://github.com/kazi-org/kazi/commit/865f5c4120476870e157288de5c452acfab85fc0))

## [1.87.0](https://github.com/kazi-org/kazi/compare/v1.86.0...v1.87.0) (2026-07-06)


### Features

* **apply:** --session-name flag + claude session_id capture ([03644be](https://github.com/kazi-org/kazi/commit/03644be655a903b88e1f52c66977c36b260ef068))
* **registry:** session identity on the run row ([2ebf228](https://github.com/kazi-org/kazi/commit/2ebf228c784d5655a0eac255094410b7f9f4aebc))
* **web:** session names on the rail, resume command in the panel ([809c42c](https://github.com/kazi-org/kazi/commit/809c42c71bf1747107085608cebbe07ce973d4c5))

## [1.86.0](https://github.com/kazi-org/kazi/compare/v1.85.0...v1.86.0) (2026-07-06)


### Features

* **web:** SESSIONS rail filter -- click a session to dim the map to its goal ([1f05cf5](https://github.com/kazi-org/kazi/commit/1f05cf568225b603c27b5091f998811a927249e5))

## [1.85.0](https://github.com/kazi-org/kazi/compare/v1.84.0...v1.85.0) (2026-07-06)


### Features

* **web:** starmap edges, stuck sessions, slide-over drill-in panel ([d2c0a26](https://github.com/kazi-org/kazi/commit/d2c0a26798dea3177773527e496a658ce5cd37b3))
* **web:** wire the no-build LiveView client so phx-click works in a browser ([c63f9f8](https://github.com/kazi-org/kazi/commit/c63f9f8fd6924864f513abb369abc5ca6c138688))

## [1.84.0](https://github.com/kazi-org/kazi/compare/v1.83.0...v1.84.0) (2026-07-06)


### Features

* **web:** starmap density + fidelity pass -- the constellation at real fleet scale ([c540377](https://github.com/kazi-org/kazi/commit/c540377f5728c524cb7a614579acc6dc044f47dd))

## [1.83.0](https://github.com/kazi-org/kazi/compare/v1.82.1...v1.83.0) (2026-07-06)


### Features

* **web:** starmap constellation canvas -- the fleet renders as SVG nodes in wave bands ([00f0051](https://github.com/kazi-org/kazi/commit/00f0051122675a041b67cc439e20ecccb1964751))

## [1.82.1](https://github.com/kazi-org/kazi/compare/v1.82.0...v1.82.1) (2026-07-06)


### Bug Fixes

* **web:** retire the last pastel light-mode styles -- starmap chips, attention signals, /dag nodes go dark-zoo ([9cee018](https://github.com/kazi-org/kazi/commit/9cee0186582a9f74752d58a2dcae9ef3decc18c2))

## [1.82.0](https://github.com/kazi-org/kazi/compare/v1.81.0...v1.82.0) (2026-07-06)


### Features

* **web:** restyle the dashboard to the approved starmap design ([726cfd7](https://github.com/kazi-org/kazi/commit/726cfd7334637b8c5f61071c962602f1ebc7f4f4))

## [1.81.0](https://github.com/kazi-org/kazi/compare/v1.80.0...v1.81.0) (2026-07-06)


### Features

* kazi dashboard --roadmap renders a real goal-file's wave bands (T47.2) ([8200535](https://github.com/kazi-org/kazi/commit/8200535a1dc586802e0c0bcc7d5ec7bce6c2e6b4))

## [1.80.0](https://github.com/kazi-org/kazi/compare/v1.79.2...v1.80.0) (2026-07-06)


### Features

* fleet-wide event river over the per-run events.jsonl sinks (T47.1) ([ed3a7a5](https://github.com/kazi-org/kazi/commit/ed3a7a5913f73e7ab5c29715741e473c189a0076))

## [1.79.2](https://github.com/kazi-org/kazi/compare/v1.79.1...v1.79.2) (2026-07-06)


### Bug Fixes

* land converged change (kazi/integrate-1783353311) ([290e27b](https://github.com/kazi-org/kazi/commit/290e27ba0dafa55104f217e4b1b3c3242712ea1c))

## [1.79.1](https://github.com/kazi-org/kazi/compare/v1.79.0...v1.79.1) (2026-07-06)


### Bug Fixes

* integrate stages scoped, waits for CI, says what it landed (issue [#819](https://github.com/kazi-org/kazi/issues/819)) ([ce2b542](https://github.com/kazi-org/kazi/commit/ce2b542af71b44709a38b772e3da3551da9b09f7))

## [1.79.0](https://github.com/kazi-org/kazi/compare/v1.78.0...v1.79.0) (2026-07-06)


### Features

* **site:** add fleet dashboard feature card (T46.9) ([827396d](https://github.com/kazi-org/kazi/commit/827396d879d73bc14de9e783c31537010099f894))

## [1.78.0](https://github.com/kazi-org/kazi/compare/v1.77.0...v1.78.0) (2026-07-06)


### Features

* attention queue -- rank what needs the operator (T46.6) ([7f23dd3](https://github.com/kazi-org/kazi/commit/7f23dd3b8bbe7ae8fb110bbba8ce1d0be052b9d8))

## [1.77.0](https://github.com/kazi-org/kazi/compare/v1.76.0...v1.77.0) (2026-07-06)


### Features

* transcript peek LiveView -- tail a run's transcript.jsonl (T46.8) ([437fda6](https://github.com/kazi-org/kazi/commit/437fda6105facebba7acd7a8994b546c45b10932))

## [1.76.0](https://github.com/kazi-org/kazi/compare/v1.75.0...v1.76.0) (2026-07-06)


### Features

* drill-in convergence heatmap + iteration scrubber LiveView (T46.7) ([2ca81e5](https://github.com/kazi-org/kazi/commit/2ca81e53fd2614717785ec847b6f53ed051a2999))

## [1.75.0](https://github.com/kazi-org/kazi/compare/v1.74.1...v1.75.0) (2026-07-06)


### Features

* per-run events.jsonl sink -- append-only loop events, retention-capped (T46.2) ([042d120](https://github.com/kazi-org/kazi/commit/042d120f99fecfbc61b2b482665500658fabfa84))

## [1.74.1](https://github.com/kazi-org/kazi/compare/v1.74.0...v1.74.1) (2026-07-06)


### Bug Fixes

* land converged change (kazi/integrate-1783324901) ([d746a5d](https://github.com/kazi-org/kazi/commit/d746a5d93b504303a3002de8cad0dbf09d441c0b))

## [1.74.0](https://github.com/kazi-org/kazi/compare/v1.73.8...v1.74.0) (2026-07-06)


### Features

* first-class `kazi apply --check` observe-only mode (issue [#805](https://github.com/kazi-org/kazi/issues/805)) ([48db05e](https://github.com/kazi-org/kazi/commit/48db05eb0ef66213257ac950fbe5982445ef6653))

## [1.73.8](https://github.com/kazi-org/kazi/compare/v1.73.7...v1.73.8) (2026-07-06)


### Bug Fixes

* re-evaluate the predicate vector before a terminal over_budget result (issue [#790](https://github.com/kazi-org/kazi/issues/790)) ([5403f8c](https://github.com/kazi-org/kazi/commit/5403f8c0aaf4f06e780ba57bd7c925fd45c6e653))

## [1.73.7](https://github.com/kazi-org/kazi/compare/v1.73.6...v1.73.7) (2026-07-06)


### Bug Fixes

* caller-drafts proposal identity + plan-time validation (issues [#787](https://github.com/kazi-org/kazi/issues/787), [#793](https://github.com/kazi-org/kazi/issues/793), [#788](https://github.com/kazi-org/kazi/issues/788)) ([960a3b7](https://github.com/kazi-org/kazi/commit/960a3b784bcb5aeab5930f317347429c64eab595))

## [1.73.6](https://github.com/kazi-org/kazi/compare/v1.73.5...v1.73.6) (2026-07-06)


### Bug Fixes

* stop folding a partition's vacuous-goal outcome into :stuck (issue [#786](https://github.com/kazi-org/kazi/issues/786)) ([6707853](https://github.com/kazi-org/kazi/commit/6707853f60f27eb7bc5dd858b48a63cdcd7b891c))

## [1.73.5](https://github.com/kazi-org/kazi/compare/v1.73.4...v1.73.5) (2026-07-06)


### Bug Fixes

* route the default logger handler to stderr -- stdout purity under --json (issue [#804](https://github.com/kazi-org/kazi/issues/804)) ([1be4b8d](https://github.com/kazi-org/kazi/commit/1be4b8d927e8a9bce18471304ce08dbcd37b3855))

## [1.73.4](https://github.com/kazi-org/kazi/compare/v1.73.3...v1.73.4) (2026-07-06)


### Bug Fixes

* kazi dashboard /dag 500 when standalone (issue [#801](https://github.com/kazi-org/kazi/issues/801)) ([c63ed4e](https://github.com/kazi-org/kazi/commit/c63ed4ee3f80ef352602c7326819cc9040b3f51d))

## [1.73.3](https://github.com/kazi-org/kazi/compare/v1.73.2...v1.73.3) (2026-07-05)


### Bug Fixes

* wire the transcript sink into the live kazi apply path (T46.3) ([f2cd369](https://github.com/kazi-org/kazi/commit/f2cd369a16877fc9c14103d5d3d79d5ba6e50604))

## [1.73.2](https://github.com/kazi-org/kazi/compare/v1.73.1...v1.73.2) (2026-07-05)


### Bug Fixes

* **loop:** unknown/quarantined verdicts never satisfy convergence ([#795](https://github.com/kazi-org/kazi/issues/795)) ([6bac321](https://github.com/kazi-org/kazi/commit/6bac321dab5a0ecb4f66a6421d01d764671d165c))

## [1.73.1](https://github.com/kazi-org/kazi/compare/v1.73.0...v1.73.1) (2026-07-05)


### Bug Fixes

* wire the fleet run registry into the live kazi apply path (T46.1) ([c9a6afe](https://github.com/kazi-org/kazi/commit/c9a6afe5982685187e0dbaae3e7a82ccdbf6e560))

## [1.73.0](https://github.com/kazi-org/kazi/compare/v1.72.2...v1.73.0) (2026-07-04)


### Features

* **dashboard:** fleet run registry, starmap LiveView, kazi dashboard verb (E46 slice) ([090da6b](https://github.com/kazi-org/kazi/commit/090da6b26b6f852725ac22d7a66eecdff073c9ed))

## [1.72.2](https://github.com/kazi-org/kazi/compare/v1.72.1...v1.72.2) (2026-07-04)


### Bug Fixes

* remediate deep-review 001 code findings (H1,M2-M9,L4,lows) ([59cc094](https://github.com/kazi-org/kazi/commit/59cc0948bacb8c07f4edfbc1205c80ce382890ba))


### Reverts

* back out M8 lease-holder-monitor (broke lease CAS atomicity) ([f15f4cf](https://github.com/kazi-org/kazi/commit/f15f4cf175104d2af1de9e76377dc9592568f565))

## [1.72.1](https://github.com/kazi-org/kazi/compare/v1.72.0...v1.72.1) (2026-07-03)


### Bug Fixes

* **harness:** surface claude permission_denials in parse/1 ([#769](https://github.com/kazi-org/kazi/issues/769)) ([0262ed4](https://github.com/kazi-org/kazi/commit/0262ed4d4e6733cdacfbce478fb753ee339dd689))

## [1.72.0](https://github.com/kazi-org/kazi/compare/v1.71.0...v1.72.0) (2026-07-03)


### Features

* **goal:** parse permission_mode/allowed_tools in the [harness] table ([9ea9334](https://github.com/kazi-org/kazi/commit/9ea93343d9df5beb190de214e7d2affbde4ada81))


### Bug Fixes

* **runtime:** fold permission_mode/allowed_tools into adapter_opts ([#769](https://github.com/kazi-org/kazi/issues/769)) ([1599ff1](https://github.com/kazi-org/kazi/commit/1599ff1ae891cf5752107f27c6548b468517f64f))

## [1.71.0](https://github.com/kazi-org/kazi/compare/v1.70.1...v1.71.0) (2026-07-01)


### Features

* **cli:** thread --permission-mode/--allowed-tools through apply; fix stale propose/run verbs ([4496100](https://github.com/kazi-org/kazi/commit/449610065de777a43dc0d4ca7413df3d29c56301))

## [1.70.1](https://github.com/kazi-org/kazi/compare/v1.70.0...v1.70.1) (2026-06-30)


### Bug Fixes

* **providers:** scrub host release/ERTS env from spawned children (L-0022) ([5f884d7](https://github.com/kazi-org/kazi/commit/5f884d7395fafed6bf1b1019e781f57ae171298a))

## [1.70.0](https://github.com/kazi-org/kazi/compare/v1.69.0...v1.70.0) (2026-06-30)


### Features

* **economy:** price claude-sonnet-5 in the cost table ([cf8937e](https://github.com/kazi-org/kazi/commit/cf8937ebe9581654ac9e806099179edff3815b01))

## [1.69.0](https://github.com/kazi-org/kazi/compare/v1.68.0...v1.69.0) (2026-06-29)


### Features

* **harness:** forward claude --effort reasoning lever (T36.6) ([e2bfcba](https://github.com/kazi-org/kazi/commit/e2bfcba16f02592c0dc153114a7b39e01ab6cc80))

## [1.68.0](https://github.com/kazi-org/kazi/compare/v1.67.0...v1.68.0) (2026-06-28)


### Features

* **scheduler:** inject default lease on the CLI --parallel path (T21.9) ([3fcc7ce](https://github.com/kazi-org/kazi/commit/3fcc7ce4c40a5f8ce00d9b3bf1990006113df1fb))

## [1.67.0](https://github.com/kazi-org/kazi/compare/v1.66.0...v1.67.0) (2026-06-28)


### Features

* **assets:** replace proof-loop mockup with a real recorded cast (T25.2) ([e6ea9d2](https://github.com/kazi-org/kazi/commit/e6ea9d25a87aeb842fd021cc3ea93890efac75f1))
* **examples:** add hero-cast demo fixture (T25.2) ([36f5a62](https://github.com/kazi-org/kazi/commit/36f5a6278efe4498434ba08578bcf1c08c86e836))
* **site:** use the real recorded cast as the home proof asset (T25.2) ([5ac6613](https://github.com/kazi-org/kazi/commit/5ac66138d1f4ab836797edde934c50b944875f3a))

## [1.66.0](https://github.com/kazi-org/kazi/compare/v1.65.1...v1.66.0) (2026-06-27)


### Features

* **coordination:** readable native-lease registry (LeaseTable) ([d85632a](https://github.com/kazi-org/kazi/commit/d85632ac39cea134975547d58bd5f02d0cd92b1c))


### Bug Fixes

* **scheduler:** parallelize disjoint groups of a no-needs goal ([153b114](https://github.com/kazi-org/kazi/commit/153b1143220bb7e0a9327e851e9f8ea50f14809a))
* **web:** default /leases to a NATS-free coordination source ([162cdc8](https://github.com/kazi-org/kazi/commit/162cdc8e877819c6c5cf1159ae783955cf56c605))

## [1.65.1](https://github.com/kazi-org/kazi/compare/v1.65.0...v1.65.1) (2026-06-27)


### Bug Fixes

* **doc-freshness:** exclude oss-gates.md from dead-command-ref check (T31.7) ([2c5553a](https://github.com/kazi-org/kazi/commit/2c5553a6136d16e22f10372c0b4d0f92b5d24dff))

## [1.65.0](https://github.com/kazi-org/kazi/compare/v1.64.2...v1.65.0) (2026-06-27)


### Features

* **site:** add the dogfood "done" proof gallery (T25.7) ([25d7f9d](https://github.com/kazi-org/kazi/commit/25d7f9d090c05389321444a557127896e6ec9dc0))


### Bug Fixes

* **site:** keep per-run cost in the methodology doc, not the proof surface ([8f35d9e](https://github.com/kazi-org/kazi/commit/8f35d9e4dfa3cdf81dc0c4f925eb6c2d8d143b1a))

## [1.64.2](https://github.com/kazi-org/kazi/compare/v1.64.1...v1.64.2) (2026-06-26)


### Bug Fixes

* **partition:** term-scope the repo-map blast radius so disjoint groups split ([5b21475](https://github.com/kazi-org/kazi/commit/5b214756fb55d7517489b8d342065cf8f8377cad))
* **scheduler:** start PartitionSupervisor on CLI apply --parallel path ([1708f3b](https://github.com/kazi-org/kazi/commit/1708f3bda36b67eae3bbbb9b6cc4c66801a67ebe))

## [1.64.1](https://github.com/kazi-org/kazi/compare/v1.64.0...v1.64.1) (2026-06-26)


### Bug Fixes

* **site:** order /blog index by series part, not just date ([6120084](https://github.com/kazi-org/kazi/commit/61200840b561254e91ee4a9ab4b2a1b662f104e3))

## [1.64.0](https://github.com/kazi-org/kazi/compare/v1.63.0...v1.64.0) (2026-06-26)


### Features

* **blog:** T38.17 Post 12 -- your on-ramp (series finale) ([e91d302](https://github.com/kazi-org/kazi/commit/e91d3023c1a95304d35335e080323e3a4e47ba46))

## [1.63.0](https://github.com/kazi-org/kazi/compare/v1.62.0...v1.63.0) (2026-06-26)


### Features

* **blog:** T38.16 Post 11 — meet kazi: "done," proven ([541baaf](https://github.com/kazi-org/kazi/commit/541baaf71c7112526c3a93785420d544b39ecbc1))

## [1.62.0](https://github.com/kazi-org/kazi/compare/v1.61.0...v1.62.0) (2026-06-26)


### Features

* **blog:** T38.15 Post 10 — the pattern underneath: reconciliation ([0c4e2aa](https://github.com/kazi-org/kazi/commit/0c4e2aad9fa061344124281588a338b8ff0f0a01))

## [1.61.0](https://github.com/kazi-org/kazi/compare/v1.60.0...v1.61.0) (2026-06-26)


### Features

* **blog:** T38.14 Post 9 — one developer, many agents ([b635764](https://github.com/kazi-org/kazi/commit/b635764368c97edd0fcd63ac4d2d35927f3bcac8))

## [1.60.0](https://github.com/kazi-org/kazi/compare/v1.59.0...v1.60.0) (2026-06-26)


### Features

* **blog:** T38.13 Post 8 — a definition of "done" that can't lie ([e178360](https://github.com/kazi-org/kazi/commit/e1783600a19979e8f371bda918a4406b55aaf9c2))

## [1.59.0](https://github.com/kazi-org/kazi/compare/v1.58.0...v1.59.0) (2026-06-26)


### Features

* **blog:** T38.12 Post 7 -- plan the work, then work the plan ([27135da](https://github.com/kazi-org/kazi/commit/27135daa58a32d12896010e24c04e9d92c3715db))

## [1.58.0](https://github.com/kazi-org/kazi/compare/v1.57.0...v1.58.0) (2026-06-26)


### Features

* **blog:** T38.11 Post 6 — from prompts to skills ([0a47769](https://github.com/kazi-org/kazi/commit/0a47769a65b10dc537071141dfa4cb118df347fb))

## [1.57.0](https://github.com/kazi-org/kazi/compare/v1.56.0...v1.57.0) (2026-06-26)


### Features

* **blog:** T38.10 Post 5 — stop re-reading the whole repo ([3c5589e](https://github.com/kazi-org/kazi/commit/3c5589e7b3b8628cb1cf15c86be75bd6b1a2f67f))

## [1.56.0](https://github.com/kazi-org/kazi/compare/v1.55.0...v1.56.0) (2026-06-26)


### Features

* **blog:** T38.9 Post 4 — give your agent eyes (all the way to prod) ([50e2626](https://github.com/kazi-org/kazi/commit/50e2626fb92610a91eedc6f37d2e2b79cd2bd0aa))

## [1.55.0](https://github.com/kazi-org/kazi/compare/v1.54.0...v1.55.0) (2026-06-26)


### Features

* **blog:** T38.8 Post 3 — decisions need a home ([e782322](https://github.com/kazi-org/kazi/commit/e7823222732d9ab7a3c51ba996efd62cbe54b783))

## [1.54.0](https://github.com/kazi-org/kazi/compare/v1.53.0...v1.54.0) (2026-06-26)


### Features

* **blog:** T38.7 Post 2 — teach your agent to remember ([fea558e](https://github.com/kazi-org/kazi/commit/fea558eb6beb361b9837466a08088e5c0609d84e))

## [1.53.0](https://github.com/kazi-org/kazi/compare/v1.52.0...v1.53.0) (2026-06-26)


### Features

* **blog:** T38.6 Post 1 — the ceiling of "looks good to me" ([e7271b7](https://github.com/kazi-org/kazi/commit/e7271b7fc2949dfc7e1797a67d5c78d0994b93a3))

## [1.52.0](https://github.com/kazi-org/kazi/compare/v1.51.0...v1.52.0) (2026-06-26)


### Features

* **site:** T38.20 core series diagrams (loop, ladder, before/after) ([d2c771c](https://github.com/kazi-org/kazi/commit/d2c771c356b26ad5114a14df91175f01130916a3))
* **site:** T38.20 per-post header art + generator ([5b84b18](https://github.com/kazi-org/kazi/commit/5b84b186fae4e313aef0354b8dc2b9838b88c03c))
* **site:** T38.20 render series diagrams + per-post art with alt text ([c408383](https://github.com/kazi-org/kazi/commit/c40838348414bec0f4bc3c5c222c9613adb44139))

## [1.51.0](https://github.com/kazi-org/kazi/compare/v1.50.0...v1.51.0) (2026-06-26)


### Features

* **site:** T38.21 cookieless analytics, UTM, canonical instrumentation ([9f22a0f](https://github.com/kazi-org/kazi/commit/9f22a0f68ad66bdfa0fa3c9361211e3cc6756ee1))

## [1.50.0](https://github.com/kazi-org/kazi/compare/v1.49.0...v1.50.0) (2026-06-26)


### Features

* **site:** add blog RSS feed, sitemap, Blog nav + extend verb guard to .mdx ([b9cbfed](https://github.com/kazi-org/kazi/commit/b9cbfedf9017ff92aaaddf7280e6f656b0a523e0))

## [1.49.0](https://github.com/kazi-org/kazi/compare/v1.48.0...v1.49.0) (2026-06-26)


### Features

* **site:** add blog post route + layout (T38.3) ([c1dd7fe](https://github.com/kazi-org/kazi/commit/c1dd7fe69d8981236813c30dbcfa929c941fad41))

## [1.48.0](https://github.com/kazi-org/kazi/compare/v1.47.0...v1.48.0) (2026-06-26)


### Features

* **site:** add /blog index + series landing pages (T38.2) ([a0d6a87](https://github.com/kazi-org/kazi/commit/a0d6a8781e621e656a61f9daf765f8b5c46bf4c2))

## [1.47.0](https://github.com/kazi-org/kazi/compare/v1.46.2...v1.47.0) (2026-06-26)


### Features

* **site:** add blog content collection + frontmatter schema (T38.1) ([f7f1860](https://github.com/kazi-org/kazi/commit/f7f18600ae37ab8075b62e5a33f0b26a88a3eb4f))

## [1.46.2](https://github.com/kazi-org/kazi/compare/v1.46.1...v1.46.2) (2026-06-26)


### Bug Fixes

* **authoring:** pin custom_script config schema in drafting prompt ([4ac3a71](https://github.com/kazi-org/kazi/commit/4ac3a7114688896ef03525cf1c93a8c26265e375))

## [1.46.1](https://github.com/kazi-org/kazi/compare/v1.46.0...v1.46.1) (2026-06-26)


### Bug Fixes

* **harness:** tolerate stderr noise before the claude JSON envelope (T26.8) ([d6e1b9a](https://github.com/kazi-org/kazi/commit/d6e1b9aafdd87d401583a41e7e131218022c28f8))

## [1.46.0](https://github.com/kazi-org/kazi/compare/v1.45.0...v1.46.0) (2026-06-26)


### Features

* **harness:** add :gemini_cli profile ([8e59072](https://github.com/kazi-org/kazi/commit/8e59072d08eda519840157858344e56f71b5e686))

## [1.45.0](https://github.com/kazi-org/kazi/compare/v1.44.0...v1.45.0) (2026-06-26)


### Features

* **doc-freshness:** add doc-coverage + stale-task ratchet metrics (T31.6) ([cdfed44](https://github.com/kazi-org/kazi/commit/cdfed4438bf6ea51f6fe2ed749799632d851717d))
* **examples:** add doc-lifecycle standing goal (T31.6) ([d815a0c](https://github.com/kazi-org/kazi/commit/d815a0ce8026c8dd8d97486c451cfa57a3b7c1aa))

## [1.44.0](https://github.com/kazi-org/kazi/compare/v1.43.0...v1.44.0) (2026-06-26)


### Features

* **loader:** expose provider_kinds/0 as the single source of truth ([87a3c54](https://github.com/kazi-org/kazi/commit/87a3c543653a7778e0ac2958a6eb8b0236d9f31c))


### Bug Fixes

* **authoring:** accept nested/goal-file proposal shapes; map E32 providers ([0f9778a](https://github.com/kazi-org/kazi/commit/0f9778a5e2f7cbfbe24ca24492ef98811984c934))

## [1.43.0](https://github.com/kazi-org/kazi/compare/v1.42.1...v1.43.0) (2026-06-26)


### Features

* **scripts:** add gated knowledge-extraction tool (T31.3) ([2d91b14](https://github.com/kazi-org/kazi/commit/2d91b144edc91bd1265705d0f312d783560193f8))

## [1.42.1](https://github.com/kazi-org/kazi/compare/v1.42.0...v1.42.1) (2026-06-25)


### Bug Fixes

* **authoring:** extract JSON from fenced/prose harness output before decoding ([2be1c70](https://github.com/kazi-org/kazi/commit/2be1c709886ab26ad98ac84bd6322c9af3b9a70f))

## [1.42.0](https://github.com/kazi-org/kazi/compare/v1.41.1...v1.42.0) (2026-06-25)


### Features

* **plan:** deterministic, lossless plan-trim tool (T31.2) ([38cb252](https://github.com/kazi-org/kazi/commit/38cb25285fe04469a459d48e5ca85c72d175c8b6))

## [1.41.1](https://github.com/kazi-org/kazi/compare/v1.41.0...v1.41.1) (2026-06-25)


### Bug Fixes

* **cli:** keep the read-model repo running in the standalone binary ([077db2f](https://github.com/kazi-org/kazi/commit/077db2fa5ad705ee459a4cd1830b414aadbaec09))

## [1.41.0](https://github.com/kazi-org/kazi/compare/v1.40.1...v1.41.0) (2026-06-25)


### Features

* **app:** supervise the DAG-snapshot cache in the web tree (T23.7) ([d48846a](https://github.com/kazi-org/kazi/commit/d48846ad3c14ebc99ee2f9e990408f9dc3201c9b))
* **scheduler:** publish render-ready DAG snapshots on each transition (T23.7) ([1606130](https://github.com/kazi-org/kazi/commit/16061302ec335dd39ead39fb51c27cf13b64bb24))
* **web:** live dependency-DAG dashboard at /dag (T23.7, UC-038) ([7d12fdc](https://github.com/kazi-org/kazi/commit/7d12fdc643b52a3550b3d571b9acdaf87b7ed358))

## [1.40.1](https://github.com/kazi-org/kazi/compare/v1.40.0...v1.40.1) (2026-06-25)


### Bug Fixes

* **economy:** surface run-aggregate tokens in the --json economy object (T34.8) ([5501b1d](https://github.com/kazi-org/kazi/commit/5501b1dd254576a27e7c75d265fc5544f91770a2))

## [1.40.0](https://github.com/kazi-org/kazi/compare/v1.39.0...v1.40.0) (2026-06-25)


### Features

* **bench:** tier x surface arms + `mix kazi.bench --tier-surface` (T36.5) ([52dbb90](https://github.com/kazi-org/kazi/commit/52dbb90eb411096b837a944d32bc64eab04ceb40))
* **harness:** add :ambient dispatch-surface OFF switch (T36.5) ([f43005d](https://github.com/kazi-org/kazi/commit/f43005d9228f45e359e368b9fbd8fe86c067a492))

## [1.39.0](https://github.com/kazi-org/kazi/compare/v1.38.2...v1.39.0) (2026-06-25)


### Features

* **bench:** in-family tiering cost arms + `mix kazi.bench --tiering` (T19.7) ([4a348b8](https://github.com/kazi-org/kazi/commit/4a348b8817890889dfeed921e5453011f73fc7ee))

## [1.38.2](https://github.com/kazi-org/kazi/compare/v1.38.1...v1.38.2) (2026-06-25)


### Bug Fixes

* **site:** repair 9 Astro newline-stripped spacing bugs ([fb4c3d5](https://github.com/kazi-org/kazi/commit/fb4c3d5738c71a7ebf9f38563dd48f7384443e91))

## [1.38.1](https://github.com/kazi-org/kazi/compare/v1.38.0...v1.38.1) (2026-06-25)


### Bug Fixes

* **site:** repair "Afterkazi" spacing + drop the Context7 jargon ([722f055](https://github.com/kazi-org/kazi/commit/722f055012036ae32c9028b628b3587c580d3173))

## [1.38.0](https://github.com/kazi-org/kazi/compare/v1.37.0...v1.38.0) (2026-06-25)


### Features

* **site:** concrete /kazi plan -&gt; /kazi apply on-ramp step (T25.4) ([3f69a4c](https://github.com/kazi-org/kazi/commit/3f69a4cfdfb741a214f108ed388ab05f73f79c73))

## [1.37.0](https://github.com/kazi-org/kazi/compare/v1.36.0...v1.37.0) (2026-06-25)


### Features

* **site:** benefit-first &lt;title&gt;/OG + meta description (T25.4 follow-up) ([84e403f](https://github.com/kazi-org/kazi/commit/84e403f36dd1f8ddf2d1c91a360d035df0056412))
* **site:** lead the hero with the Claude Code benefit (T25.4) ([a50e170](https://github.com/kazi-org/kazi/commit/a50e170264d1c6601467909ba6168a1afa690db6))

## [1.36.0](https://github.com/kazi-org/kazi/compare/v1.35.0...v1.36.0) (2026-06-25)


### Features

* **context-store:** inner-prompt contract + inner-search-only gist (T35.9) ([1db6f35](https://github.com/kazi-org/kazi/commit/1db6f355207e85adaba218580f4e57bfcb432e46))

## [1.35.0](https://github.com/kazi-org/kazi/compare/v1.34.0...v1.35.0) (2026-06-25)


### Features

* **site:** lead with the 10-second on-ramp (T25.4) ([5b5ce70](https://github.com/kazi-org/kazi/commit/5b5ce709962900c4c31481e0c09371acc11e5a4b))

## [1.34.0](https://github.com/kazi-org/kazi/compare/v1.33.0...v1.34.0) (2026-06-25)


### Features

* **stuck-bundle:** compact escalation bundle on stuck (T35.6) ([998129e](https://github.com/kazi-org/kazi/commit/998129e8f12323f4d437bd1464076d9c9303b874))

## [1.33.0](https://github.com/kazi-org/kazi/compare/v1.32.0...v1.33.0) (2026-06-25)


### Features

* **cli:** kazi apply --context-store/--context-budget + additive stats (T35.5) ([19bb14d](https://github.com/kazi-org/kazi/commit/19bb14d0f5e8190288d24dfc191fa64c11a540ac))

## [1.32.0](https://github.com/kazi-org/kazi/compare/v1.31.0...v1.32.0) (2026-06-25)


### Features

* **loop:** wire context store for evidence compression (T35.4) ([82427d1](https://github.com/kazi-org/kazi/commit/82427d1c582b79a8f67d4502138e0b8465f77501))

## [1.31.0](https://github.com/kazi-org/kazi/compare/v1.30.0...v1.31.0) (2026-06-25)


### Features

* **context:** pure tier-escalation policy with stop rule (T36.4) ([fbec61e](https://github.com/kazi-org/kazi/commit/fbec61e06aac04253a76fa3cc5a9fa69538a7921))
* **loop:** escalate the active context tier on non-progress (T36.4) ([c3fa1b8](https://github.com/kazi-org/kazi/commit/c3fa1b8b8d0255dfae3e4ee9d0efe7bebd09f66e))

## [1.30.0](https://github.com/kazi-org/kazi/compare/v1.29.0...v1.30.0) (2026-06-25)


### Features

* **context-store:** redact content before indexing (T35.3) ([7030db0](https://github.com/kazi-org/kazi/commit/7030db0df7b0868d08d7c36bca7d6b104d3e6fe5))
* **prompt:** redact secrets in evidence before the harness (T35.3) ([7df95a2](https://github.com/kazi-org/kazi/commit/7df95a2ede8a0fe3126ef6ca25e668f043b35b9b))
* **redaction:** shared secret redactor for evidence egress (T35.3) ([88adeb0](https://github.com/kazi-org/kazi/commit/88adeb0e4925456f5e0732a776c95728cb24bf23))


### Bug Fixes

* **context-store:** unique gist staging filename (T35.3) ([b5eea80](https://github.com/kazi-org/kazi/commit/b5eea8050a75c404e0337777fcee815fdb953a86))

## [1.29.0](https://github.com/kazi-org/kazi/compare/v1.28.0...v1.29.0) (2026-06-25)


### Features

* **cli:** add `kazi context index|search|stats` wrapper (T35.7) ([3e38338](https://github.com/kazi-org/kazi/commit/3e38338e30f8d79dbcf0fc5ebca4a56b85c12451))

## [1.28.0](https://github.com/kazi-org/kazi/compare/v1.27.0...v1.28.0) (2026-06-25)


### Features

* **init:** add `kazi init --with-gist` to opt a repo into the Gist context store ([2a3a39e](https://github.com/kazi-org/kazi/commit/2a3a39eb494445ad49ed3d325a014bf94232ce2e))

## [1.27.0](https://github.com/kazi-org/kazi/compare/v1.26.0...v1.27.0) (2026-06-25)


### Features

* **context:** add context-budget tier ladder (T36.3) ([3e8552c](https://github.com/kazi-org/kazi/commit/3e8552c38b1b7883c57ea54738e6adeea1485553))
* **harness:** gate the graph MCP behind tier 2 in the dispatch surface (T36.3) ([57af522](https://github.com/kazi-org/kazi/commit/57af522cec0ab384c949f52d053eb7ec9102a294))
* **loop:** gate orientation prefix and record tier by context tier (T36.3) ([aeaed37](https://github.com/kazi-org/kazi/commit/aeaed37d4e59fd0ca4ad46eeead581a80596fc24))
* **loop:** record active context tier in the per-iteration envelope (T36.3) ([78f6ed9](https://github.com/kazi-org/kazi/commit/78f6ed9399f14fb71caaa4af947a395f3b5e2a16))

## [1.26.0](https://github.com/kazi-org/kazi/compare/v1.25.0...v1.26.0) (2026-06-25)


### Features

* **bench:** consume the economy KPIs in a per-arm breakdown table (T34.6) ([b55a5bb](https://github.com/kazi-org/kazi/commit/b55a5bba0b8b3d3bdca4ac71c6ca9543b3b43988))
* **cli:** surface the economy KPIs in the apply --json run result (T34.6) ([9125961](https://github.com/kazi-org/kazi/commit/9125961c03eed8b209469df29d167245998f5426))
* **economy:** pure run-end economy-KPI fold from iteration envelopes (T34.6) ([f4a4cb3](https://github.com/kazi-org/kazi/commit/f4a4cb30532281837e87ca3651a61fba688f9ff3))
* **mcp:** mirror the economy KPIs in the kazi_apply run result (T34.6) ([94fe9ff](https://github.com/kazi-org/kazi/commit/94fe9ff920e3e43ceb6b3e8582021dcd92f1eb19))

## [1.25.0](https://github.com/kazi-org/kazi/compare/v1.24.0...v1.25.0) (2026-06-25)


### Features

* **economy:** dated price map for cost_usd (T34.5) ([19d4254](https://github.com/kazi-org/kazi/commit/19d42548c2ededdb04616c96e11417ba4882e65e))
* **harness:** derive cost_usd from the price map when the harness omits it (T34.5) ([310b7e6](https://github.com/kazi-org/kazi/commit/310b7e6a3638e4479e302bda9d518029ad21a7ca))

## [1.24.0](https://github.com/kazi-org/kazi/compare/v1.23.0...v1.24.0) (2026-06-25)


### Features

* **budget:** discount cached reads in the token budget guard (T34.4) ([281f38c](https://github.com/kazi-org/kazi/commit/281f38c34bfd27485e5c550be8133f8986caa0c5))
* **goal:** accept budget.cached_read_weight config (T34.4) ([8bed21b](https://github.com/kazi-org/kazi/commit/8bed21ba3284d57b945d99c0c45c2ba0ffbf6b89))

## [1.23.0](https://github.com/kazi-org/kazi/compare/v1.22.0...v1.23.0) (2026-06-25)


### Features

* **harness:** surface claude tool-use names for per-iteration tool counters ([0447f36](https://github.com/kazi-org/kazi/commit/0447f36cdb6369183dcc9d9bc4cdc81acabc2dbc))
* **loop:** add Kazi.Loop.Counters for per-iteration context + tool counters ([619f19d](https://github.com/kazi-org/kazi/commit/619f19df369e274df96ec7761eb74425e89f8890))
* **loop:** record context + tool counters in the iteration event (T34.3) ([5089b58](https://github.com/kazi-org/kazi/commit/5089b580d65b824f443dd1296f6efa916d4fa3af))
* **read-model:** persist + round-trip per-iteration context + tool counters ([22a51f6](https://github.com/kazi-org/kazi/commit/22a51f68e534d8eac80ee32c2793768a98a4b49c))
* **runtime,cli:** project context + tool counters to read-model and stream ([129dace](https://github.com/kazi-org/kazi/commit/129dacef31c6af0248248bfef2c2f868a6b885a5))

## [1.22.0](https://github.com/kazi-org/kazi/compare/v1.21.0...v1.22.0) (2026-06-25)


### Features

* **enforcement:** add DiffGuard advisory diff-inspection scanner (T32.5) ([a0c9610](https://github.com/kazi-org/kazi/commit/a0c961097de3c586b69943a5660f7d2b07401901))
* **loop:** wire advisory diff-gaming guard with progress downgrade (T32.5) ([dc7c4d4](https://github.com/kazi-org/kazi/commit/dc7c4d43e5f5bfb29702fc5de6f24ccddda60c8f))

## [1.21.0](https://github.com/kazi-org/kazi/compare/v1.20.0...v1.21.0) (2026-06-25)


### Features

* **mcp:** canonical kazi mcp client config + `init --with-mcp` (T33.3) ([df9c8b9](https://github.com/kazi-org/kazi/commit/df9c8b93c20667823e61642336e39737c353754b))

## [1.20.0](https://github.com/kazi-org/kazi/compare/v1.19.0...v1.20.0) (2026-06-25)


### Features

* **context-store:** add GistCLI provider (T35.2) ([2acd9a9](https://github.com/kazi-org/kazi/commit/2acd9a99ae53c559b530adac0b4211ee92f6244d))

## [1.19.0](https://github.com/kazi-org/kazi/compare/v1.18.0...v1.19.0) (2026-06-25)


### Features

* **cli:** surface enforcement guarantees in `apply --json` (T32.4) ([4c197e6](https://github.com/kazi-org/kazi/commit/4c197e686fa91aa6be0b283f6e8440fb3436c17a))
* **enforcement:** Kazi.Enforcement profile + clean-tree isolation (T32.4) ([8ff7345](https://github.com/kazi-org/kazi/commit/8ff7345fa460a9b047f2f705e3104d0f303501fa))
* **goal:** carry the authored enforcement profile (T32.4) ([b1d3577](https://github.com/kazi-org/kazi/commit/b1d357758167be6904e2f85448d4eff8d928267f))
* **loader:** parse the [enforcement] goal-file table (T32.4) ([1686f15](https://github.com/kazi-org/kazi/commit/1686f152e3a4a4b36e4d85c8d18afbd6949fbbd8))
* **loop:** compose anti-gaming enforcement onto the reconcile tick (T32.4) ([88d901a](https://github.com/kazi-org/kazi/commit/88d901a34c3445851ad338ac94135a7c05e896bb))
* **runtime:** resolve enforcement + synthesize ratchet guards (T32.4) ([0e69a7a](https://github.com/kazi-org/kazi/commit/0e69a7aa7b876838088941123fbb8072fdfa519e))


### Bug Fixes

* **cli:** keep the usage envelope alongside enforcement in `apply --json` ([6be0c85](https://github.com/kazi-org/kazi/commit/6be0c850221844f4b6f65c7eb157b32826210aba))

## [1.18.0](https://github.com/kazi-org/kazi/compare/v1.17.0...v1.18.0) (2026-06-25)


### Features

* **ci:** add doc command-accuracy gate vs kazi CLI surface ([535f938](https://github.com/kazi-org/kazi/commit/535f938ce37c3e7e263b6d064ee273fac58dfbbc))

## [1.17.0](https://github.com/kazi-org/kazi/compare/v1.16.0...v1.17.0) (2026-06-25)


### Features

* **predicate:** :coverage first-class provider (T32.8) ([e5f3eab](https://github.com/kazi-org/kazi/commit/e5f3eabb6fef80aed211023d9acfd95812481137))
* **predicate:** :cve first-class provider (T32.8) ([daf85df](https://github.com/kazi-org/kazi/commit/daf85dfe9b468ba3c3e73ae79071fcdfdfc0dd68))
* **predicate:** :mutation first-class provider (T32.8) ([d776f9f](https://github.com/kazi-org/kazi/commit/d776f9fcdad8f486971ce624e62a5926467bac5d))
* **predicate:** :property first-class provider (T32.8) ([00b159a](https://github.com/kazi-org/kazi/commit/00b159a1573ce72ea9835cdedff8766963319728))

## [1.16.0](https://github.com/kazi-org/kazi/compare/v1.15.0...v1.16.0) (2026-06-25)


### Features

* **usage:** fold the per-field token split into the run-aggregate envelope (T34.2) ([53100c5](https://github.com/kazi-org/kazi/commit/53100c5e5c29e9be0bd7613e722a82090ff1026e))
* **usage:** map per-profile raw usage onto the economy envelope + fidelity (T34.2) ([d192ac5](https://github.com/kazi-org/kazi/commit/d192ac51c827f0e59b5498f0b24f891b3f131ce2))

## [1.15.0](https://github.com/kazi-org/kazi/compare/v1.14.0...v1.15.0) (2026-06-25)


### Features

* **harness:** minimal default dispatch surface (T36.2) ([c42b0d9](https://github.com/kazi-org/kazi/commit/c42b0d9a940532c1186c5932ab21719526cdba5b))

## [1.14.0](https://github.com/kazi-org/kazi/compare/v1.13.0...v1.14.0) (2026-06-25)


### Features

* **loader:** register + validate :static, add `kazi schema static` (T32.7) ([db6ba50](https://github.com/kazi-org/kazi/commit/db6ba502ee484418217bbc2909c95a090973261e))
* **predicate:** :static provider — Dialyzer-led analysis (T32.7) ([3456080](https://github.com/kazi-org/kazi/commit/3456080cf26d71c2a677dab5d62d37c42cabe005))

## [1.13.0](https://github.com/kazi-org/kazi/compare/v1.12.0...v1.13.0) (2026-06-25)


### Features

* **examples:** ship custom_script/ratchet recipes — contract/perf/secret/a11y/IaC/visual (T32.9) ([a7e5850](https://github.com/kazi-org/kazi/commit/a7e58504979d5d2fe027d5af20846dc5caafffeb))

## [1.12.0](https://github.com/kazi-org/kazi/compare/v1.11.0...v1.12.0) (2026-06-25)


### Features

* **predicate:** :metrics provider — windowed quantile + SLO burn-rate (T32.10) ([1551677](https://github.com/kazi-org/kazi/commit/155167786cd70a6c0447bc5a6d3cf2c3c07a384b))
* **predicate:** browser synthetic journey — X consecutive passes (T32.10) ([ea7445d](https://github.com/kazi-org/kazi/commit/ea7445d8ed8c46ef12118d79f617118a5c6abfad))
* **predicate:** http_probe sustained-health — N consecutive samples (T32.10) ([c98728b](https://github.com/kazi-org/kazi/commit/c98728bd30d86d0734ac1214fad951c4ed71aee5))

## [1.11.0](https://github.com/kazi-org/kazi/compare/v1.10.0...v1.11.0) (2026-06-25)


### Features

* **json:** add usage envelope renderer + schema descriptor (T34.1) ([5294c88](https://github.com/kazi-org/kazi/commit/5294c88b5cb321fdcb840a2983844157283004ea))
* **json:** render additive usage envelope + budget_spent.tokens (T34.1) ([85bcb3c](https://github.com/kazi-org/kazi/commit/85bcb3c2837a1c7f31f8040d667c85e1155a2fd7))
* **loop:** accumulate the run-aggregate usage envelope (T34.1) ([bcac448](https://github.com/kazi-org/kazi/commit/bcac448b31f5e512b238832f170e87d472bab282))
* **mcp:** mirror the usage envelope in the MCP run result (T34.1) ([e28250b](https://github.com/kazi-org/kazi/commit/e28250b2f794e13788133b7b6cf9ec97f04dd2d8))

## [1.10.0](https://github.com/kazi-org/kazi/compare/v1.9.0...v1.10.0) (2026-06-25)


### Features

* **cli:** add kazi mcp verb (T33.1) ([ed71107](https://github.com/kazi-org/kazi/commit/ed71107cae9d52574feee1f40e507fd3df32fe13))

## [1.9.0](https://github.com/kazi-org/kazi/compare/v1.8.1...v1.9.0) (2026-06-25)


### Features

* **predicate:** first-class ratchet provider, wiring + schema (T32.3) ([44830a6](https://github.com/kazi-org/kazi/commit/44830a6ce34a83d34dc50901df20a3d469ae1453))
* **predicate:** ratchet baseline-comparison machinery + store (T32.3) ([e1483e8](https://github.com/kazi-org/kazi/commit/e1483e835774ebb97f444dce7779683c0e5537f0))
* **predicate:** shared JSONPath + metric signal extraction (T32.3) ([ff848fa](https://github.com/kazi-org/kazi/commit/ff848fa6b60c8ff3eb283a917e8f29248dccccc9))

## [1.8.1](https://github.com/kazi-org/kazi/compare/v1.8.0...v1.8.1) (2026-06-25)


### Bug Fixes

* **site:** use kazi apply/plan verbs in Install + proof asset (T27.6) ([eb9db10](https://github.com/kazi-org/kazi/commit/eb9db1096d17988da8ee8e658fc9c37397bc7171))

## [1.8.0](https://github.com/kazi-org/kazi/compare/v1.7.0...v1.8.0) (2026-06-25)


### Features

* **harness:** advertise Claude economy opts in supported_opts (T36.1) ([dcc0569](https://github.com/kazi-org/kazi/commit/dcc056922782898cbeed2a714ff4d00d24db9138))
* **harness:** map Claude economy flags in build_args (T36.1) ([1006aa4](https://github.com/kazi-org/kazi/commit/1006aa4d10280e4dbaa576ba1ead009a3301d4a6))

## [1.7.0](https://github.com/kazi-org/kazi/compare/v1.6.0...v1.7.0) (2026-06-25)


### Features

* **loop:** held-out acceptance subset hidden from agent (T32.6) ([f8abf5c](https://github.com/kazi-org/kazi/commit/f8abf5cc1549f42b8f87d28472e22bad323d640b))

## [1.6.0](https://github.com/kazi-org/kazi/compare/v1.5.0...v1.6.0) (2026-06-25)


### Features

* **loader:** deprecate test_runner/prod_log provider names with a STDERR hint (T32.1b) ([f98ec15](https://github.com/kazi-org/kazi/commit/f98ec15145137a240214d6d2b50b0316bc526333))
* **schema:** document match_count verdict + match_regex/merge_stderr keys (T32.1b) ([7620dc6](https://github.com/kazi-org/kazi/commit/7620dc63b6fff4be593adbdb5a03f5a1d934fa1d))

## [1.5.0](https://github.com/kazi-org/kazi/compare/v1.4.0...v1.5.0) (2026-06-25)


### Features

* **site:** add command-accuracy scanner for removed kazi verbs ([3eaf0cf](https://github.com/kazi-org/kazi/commit/3eaf0cf07703bf346ce18f74a7a164349134578d))

## [1.4.0](https://github.com/kazi-org/kazi/compare/v1.3.0...v1.4.0) (2026-06-25)


### Features

* **site:** add Docs nav + community footer links (T25.12) ([3cfc635](https://github.com/kazi-org/kazi/commit/3cfc635bd09a5c7850a16a9ed18284fcfbfe7376))

## [1.3.0](https://github.com/kazi-org/kazi/compare/v1.2.0...v1.3.0) (2026-06-25)


### Features

* **cli:** emit additive envelope-v2 predicate fields under --json (T32.2) ([4a0dd63](https://github.com/kazi-org/kazi/commit/4a0dd63cdad0515df1c7f4854a2abe1c772f65b1))
* **evidence:** SARIF/JUnit parser + LSP-Diagnostic evidence item (T32.2) ([533dcbd](https://github.com/kazi-org/kazi/commit/533dcbd426ccbd0b553b12c14911d61e2c581375))
* **loop:** thread prior_score; stuck-detector reads the graded delta (T32.2) ([4b41f7a](https://github.com/kazi-org/kazi/commit/4b41f7ae6d9afd2dd1331a984d965220c78d7d90))
* **predicate:** envelope v2 — score/direction/prior_score/diagnostics (T32.2) ([9d9ad89](https://github.com/kazi-org/kazi/commit/9d9ad894654c723703e43b3a62001b67015fa47b))
* **read-model:** persist + round-trip envelope-v2 fields (T32.2) ([5b87e34](https://github.com/kazi-org/kazi/commit/5b87e3428c0c43daf3a7f8a831aec5ef78572011))

## [1.2.0](https://github.com/kazi-org/kazi/compare/v1.1.0...v1.2.0) (2026-06-25)


### Features

* **cli:** kazi schema custom_script provider-key schema (T32.1) ([bf2bb48](https://github.com/kazi-org/kazi/commit/bf2bb48839e57f3cf0740cf9592f76cd0aa176f4))
* **predicate:** custom_script generic command-runner provider (T32.1) ([371b1a7](https://github.com/kazi-org/kazi/commit/371b1a79a358456bd2d241b4d1e3b10f49c69a01))
* **predicate:** validate custom_script config keys in the loader (T32.1) ([af92813](https://github.com/kazi-org/kazi/commit/af92813ce6ee56755f01165acb9a669beda76f78))
* **site:** render decided tagline, invocation phrase + agent testimonial (T25.1/T25.5/T25.6) ([bdb3124](https://github.com/kazi-org/kazi/commit/bdb3124044aecc21bc6aa13db4e0fcd0c0b43579))
* **site:** wire decided tagline + invocation phrase into canonical strings (T25.1/T25.6) ([0a4e140](https://github.com/kazi-org/kazi/commit/0a4e14033ea6ab4d027d48a83df3cab706dfb2d8))
* **skill:** recognize + document the invocation phrase (T25.6) ([12f0f5a](https://github.com/kazi-org/kazi/commit/12f0f5aae7bf151c894f5a4f7186c39f38fd962e))

## [1.1.0](https://github.com/kazi-org/kazi/compare/v1.0.1...v1.1.0) (2026-06-25)


### Features

* **docs-freshness:** predicate (a) -- every CLI command in README (T31.4) ([9c11fbf](https://github.com/kazi-org/kazi/commit/9c11fbf22eaea3d5d1cd2cce78abc883471722f5))
* **docs-freshness:** predicate (b) -- no dead command refs in live docs (T31.4) ([66638dc](https://github.com/kazi-org/kazi/commit/66638dc3215063b130a40b7bd557f23478340dfb))
* **docs-freshness:** predicate (c) -- referenced ADRs exist (T31.4) ([bd925e1](https://github.com/kazi-org/kazi/commit/bd925e1c6857120004e15baf9205e0cbcfcd8990))
* **docs-freshness:** predicate (d) -- plan trimmed of released tasks (T31.4) ([73d12f8](https://github.com/kazi-org/kazi/commit/73d12f87ff003320b0c4a0eff0bd7cd3adc11211))
* **docs-freshness:** runner for the predicate set (T31.4) ([4f03bbd](https://github.com/kazi-org/kazi/commit/4f03bbd4105b887292015bce96beaf329211e862))
* **docs-freshness:** shared lib for doc-freshness predicates (T31.4) ([a458463](https://github.com/kazi-org/kazi/commit/a4584639bd4c722d9e62e90e7a6a55463be10c1c))
* **teach:** AGENTS.md defaults to in-family Claude tiering (T30.1) ([08d3af7](https://github.com/kazi-org/kazi/commit/08d3af7b76e6c38a6d90b17360d64c7339979310))
* **teach:** bounded escalate-on-stuck model ladder in the SKILL.md (T30.2) ([ac82f7b](https://github.com/kazi-org/kazi/commit/ac82f7bd258796716f5809a89abfee54ddb73af8))
* **teach:** SKILL.md template defaults to in-family Claude tiering (T30.1) ([37dac7f](https://github.com/kazi-org/kazi/commit/37dac7f9d8e8d8d32c36dfe12f5147e5e73e4dc6))


### Bug Fixes

* **ci:** doc-freshness WARN step must not errexit on a failing run ([9dc9d6d](https://github.com/kazi-org/kazi/commit/9dc9d6de0bdeeb62f3fb7e67d1bc153fb15bef0c))
* **docs-freshness:** exclude the freshness doc from (b)/(c) self-scan (T31.4) ([094df2f](https://github.com/kazi-org/kazi/commit/094df2f77c1c66a3c677cacd170508b64a2d07d9))

## [1.0.1](https://github.com/kazi-org/kazi/compare/v1.0.0...v1.0.1) (2026-06-25)


### Bug Fixes

* **release:** build on OTP 28.3 so `kazi version` prints no warning ([b68cc3f](https://github.com/kazi-org/kazi/commit/b68cc3f388d6e3d48c5e13f53bac6d6ad5f3eb73))

## [1.0.0](https://github.com/kazi-org/kazi/compare/v0.5.0...v1.0.0) (2026-06-24)


### ⚠ BREAKING CHANGES

* repoint run/propose to apply/plan in user-facing docs (T27.9)
* repoint run/propose to apply/plan; assert aliases now error (T27.9)
* mark run/propose aliases REMOVED in v1.0.0 (T27.9)
* **teach:** scrub run/propose from SKILL.md template and AGENTS.md (T27.9)
* **mcp:** MCP tools kazi_run/kazi_propose are removed; use kazi_apply/kazi_plan.
* **cli:** kazi schema run/propose no longer resolve.
* **cli:** kazi run/propose are removed; use kazi apply/plan.

### Features

* **cli:** drop run/propose schema aliases (T27.9) ([07a1578](https://github.com/kazi-org/kazi/commit/07a1578451b27771034a6b67d28ddcc0260378b5))
* **cli:** remove deprecated run/propose aliases (T27.9) ([160150e](https://github.com/kazi-org/kazi/commit/160150edecdcc2f8b17239cc788d2ecc028a444e))
* **mcp:** remove kazi_run/kazi_propose tool aliases (T27.9) ([9d11eb6](https://github.com/kazi-org/kazi/commit/9d11eb6d6ae1cd3bd9818c57f676d45f3bbd31f7))
* **site:** add 'by the team behind Sire' footer attribution link ([00ed31e](https://github.com/kazi-org/kazi/commit/00ed31e70891c615ef7cc38ed8122b012a5db669))
* **site:** dynamic version badge -- fetch latest release, never stale ([64a09c7](https://github.com/kazi-org/kazi/commit/64a09c7267efe65c2f55e40b05b443eb2dc4dcf9))
* **teach:** scrub run/propose from SKILL.md template and AGENTS.md (T27.9) ([433e915](https://github.com/kazi-org/kazi/commit/433e915fb0ac76218bf512fafaa18857d64ad461))


### Bug Fixes

* **oss-gates:** make the leak guard's full-tree mode actually scan ([f091b5d](https://github.com/kazi-org/kazi/commit/f091b5d8a89104dfe90a91551051a5ba452c9d06))


### Documentation

* mark run/propose aliases REMOVED in v1.0.0 (T27.9) ([0e2d537](https://github.com/kazi-org/kazi/commit/0e2d537209bea641f85b72d7e2d288aa6fe33231))
* repoint run/propose to apply/plan in user-facing docs (T27.9) ([f270548](https://github.com/kazi-org/kazi/commit/f2705485174bde495991110dceb4e945bb36d468))


### Tests

* repoint run/propose to apply/plan; assert aliases now error (T27.9) ([782aaaf](https://github.com/kazi-org/kazi/commit/782aaaf94be68f9ca9e57dbd5e5ffe4c080a3a57))

## [0.5.0](https://github.com/kazi-org/kazi/compare/v0.4.0...v0.5.0) (2026-06-24)


### Features

* **cli:** apply/plan primary verbs, run/propose deprecated aliases (T27.1) ([b000fc0](https://github.com/kazi-org/kazi/commit/b000fc0bf59489b7448b6383160109408fc97a90))
* **cli:** bump JSON result schema_version 1-&gt;2 + apply/plan command key (T27.3) ([aae6f84](https://github.com/kazi-org/kazi/commit/aae6f84627d083b7f45aa3ab32598a2d85b78d0e))
* **cli:** help --json marks apply/plan primary, run/propose deprecated (T27.4) ([bd5fba0](https://github.com/kazi-org/kazi/commit/bd5fba0667491666519c620a02181333b54f6698))
* **cli:** mix kazi.apply task + mix kazi.run deprecated alias (T27.2) ([1c63a8c](https://github.com/kazi-org/kazi/commit/1c63a8c5629f0ee17a474b4f52bb623bb150f2d1))
* **cli:** name the v0.5.0 removal in the deprecation hints (T27.7) ([aa42dd9](https://github.com/kazi-org/kazi/commit/aa42dd9a560df7e8f2b817a9f07e718ea83b2ba0))
* **cli:** schema resolves apply/plan; run/propose aliased (T27.4) ([4ca364a](https://github.com/kazi-org/kazi/commit/4ca364aca732c90eec1acfd1a59bd0c4d41a328d))
* **harness:** claude profile renders --model for in-family tiering (T19.6) ([302b18d](https://github.com/kazi-org/kazi/commit/302b18dd85862fa4f30843e2c7939edd9cf82cb8))
* **teach:** flesh out the `apply` sub-skill recipe (T26.3) ([389c1b1](https://github.com/kazi-org/kazi/commit/389c1b14b262ed560678d058c96071544ba299e4))
* **teach:** flesh out the `plan` sub-skill recipe (T26.2) ([d19a8e0](https://github.com/kazi-org/kazi/commit/d19a8e0d45b40e44dc1df506d8537066481c4dda))
* **teach:** flesh out the `status` + `adopt` sub-skill recipes (T26.4) ([b49736d](https://github.com/kazi-org/kazi/commit/b49736d63ed21e57884840dc726760d9db1b878d))
* **teach:** install-skill writes a plan/apply/status/adopt router SKILL.md (T26.1) ([360aeab](https://github.com/kazi-org/kazi/commit/360aeab63ebc34b4152ca28a67b8dbc9a7d80bb9))
* **teach:** rename MCP tools kazi_run-&gt;kazi_apply, kazi_propose-&gt;kazi_plan (T27.5) ([d0deee3](https://github.com/kazi-org/kazi/commit/d0deee357e8f0131ec8ede406fbac71fb8ce831a))


### Bug Fixes

* **cli:** deprecation hint names v1.0.0 as the removal version ([fa9c147](https://github.com/kazi-org/kazi/commit/fa9c147e14e34e5796fc17bfa09e7f1a37e76e18))

## [0.4.0](https://github.com/kazi-org/kazi/compare/v0.3.0...v0.4.0) (2026-06-24)


### Features

* **authoring:** caller-drafts mode via a supplied :proposal (T15.2) ([5e09014](https://github.com/kazi-org/kazi/commit/5e090142fec242b9ff069b3a98e44605964e16c1))
* **bench:** 3-arm token-benchmark harness + pure capture/report core (T19.4) ([376022f](https://github.com/kazi-org/kazi/commit/376022fbbfb3ffc218f09abe6878ea8e1b5f4cfd))
* **cli:** --json for run --stream, status, list/approve/reject (T15.4/T15.5/T15.6) ([37729b5](https://github.com/kazi-org/kazi/commit/37729b5399f80547a8847de0ba41e0fc955af505))
* **cli:** --json output framework + non-interactive guarantee (T15.1) ([1495bd5](https://github.com/kazi-org/kazi/commit/1495bd54b2f5309967176f235ed0fb4bc17849f6))
* **cli:** help --json + schema for agent introspection (T16.1) ([2c1441e](https://github.com/kazi-org/kazi/commit/2c1441e5806fc2534d09652cb81f54426c91af18))
* **cli:** kazi lint near-duplicate group-name warning (T12.7) ([058da16](https://github.com/kazi-org/kazi/commit/058da1624ec59ce676c170c495d4b57c79c9900b))
* **cli:** propose --json with kazi-drafts + caller-drafts modes (T15.2) ([9764dd5](https://github.com/kazi-org/kazi/commit/9764dd54a8bacb304455f1dc6e38f83a828e7e6e))
* **cli:** run --json versioned result contract (T15.3) ([03d742a](https://github.com/kazi-org/kazi/commit/03d742aba1f512bed83b04139bdfd343bb47c562))
* **cli:** run --parallel routes to the parallel scheduler + --json collective contract (T21.8) ([0793327](https://github.com/kazi-org/kazi/commit/0793327880cc11c4d825775f98106677746a1899))
* **cli:** schedule reporting + run --explain dry-run (T23.6) ([436e332](https://github.com/kazi-org/kazi/commit/436e3328b881a006ff899b53e360e37aa27d2210))
* **cli:** schema-as-data for the versioned --json result schemas (T16.1) ([44c9b7d](https://github.com/kazi-org/kazi/commit/44c9b7debd8408ee640268bc236c6f3b67937d35))
* **cli:** wire `kazi install-skill` into the command table (T16.2) ([099c39c](https://github.com/kazi-org/kazi/commit/099c39cbdffad20a37d3363ae361f9166a1e2ebc))
* **cli:** wire kazi export --obsidian into the command table (T12.6) ([c6e86a6](https://github.com/kazi-org/kazi/commit/c6e86a652b2cb4e108cc8f4b66b34e157302a0fb))
* **export:** Obsidian vault renderer for the group tree (T12.6) ([843082c](https://github.com/kazi-org/kazi/commit/843082ccfab762bab94bbea5e73d8939ca326235))
* **goal:** add needs dependency edges to Group struct (T23.1) ([4a9148c](https://github.com/kazi-org/kazi/commit/4a9148c5ed2be2f2ef51ded374e9753814ac4e8b))
* **goal:** declared [[group]] taxonomy in the loader (T12.1) ([5048077](https://github.com/kazi-org/kazi/commit/50480776365493ded9fe8b8cb627b2074d817445))
* **goal:** dependency DAG ready-set + blocked-subDAG computation (T23.2) ([ae8922c](https://github.com/kazi-org/kazi/commit/ae8922c903323c8c432a8d2ec4682b05a5bc39b3))
* **goal:** derive per-group effective budget rollup (T12.4) ([bad36a1](https://github.com/kazi-org/kazi/commit/bad36a19d1d73f71a4d0751cb82b17f6ee611a55))
* **goal:** group tree + per-group status rollup (T12.3) ([9e859b8](https://github.com/kazi-org/kazi/commit/9e859b85f927436ad1723b5f9467ba3024551b83))
* **goal:** GroupLint near-duplicate group-name fuzzy compare (T12.7) ([639014e](https://github.com/kazi-org/kazi/commit/639014e1bc32fbed3f60e1ee71bf9d7be41d487c))
* **goal:** parse + validate the needs DAG in the loader (T23.1, ADR-0028) ([3f35855](https://github.com/kazi-org/kazi/commit/3f3585554476bb1670198a69956bae73303234b9))
* **goal:** validate group references and parent cycles in loader (T12.2) ([8567597](https://github.com/kazi-org/kazi/commit/856759794061b2cf67bbe1be9f8229fbda5778af))
* **harness:** claw-code profile (:claw, best-effort) (T14.4) ([253195c](https://github.com/kazi-org/kazi/commit/253195c67089b95f92a9d38de5222c972f29760c))
* **harness:** Codex CLI profile (:codex) argv + JSONL parse (T14.2) ([74b5aec](https://github.com/kazi-org/kazi/commit/74b5aecfac91b03ebb929f3a729b8d6423cf238d))
* **harness:** Google Antigravity profile (:antigravity) with non-TTY workaround (T14.3) ([56b6bf0](https://github.com/kazi-org/kazi/commit/56b6bf073b8487d26f13eec9d60931b69e3d9f80))
* **loop:** additive :orientation_prefix flag to disable the T19.1 prefix ([d3c2ce0](https://github.com/kazi-org/kazi/commit/d3c2ce0f08cd9b2cd9371d70665457e481805467))
* **loop:** stable-prefix ordering + truncate evidence on the live dispatch (T19.2/T19.3) ([f7019c0](https://github.com/kazi-org/kazi/commit/f7019c0754c10dbf883d148524c37c0ca101f38e))
* **loop:** wire the cached orientation pack into the live dispatch prefix (T19.1, realize T4.3) ([a0edcba](https://github.com/kazi-org/kazi/commit/a0edcba69e739dcd2003416e845df4d382ed707f))
* **mcp:** mix kazi.mcp entrypoint for the MCP stdio server (T16.5) ([67f846c](https://github.com/kazi-org/kazi/commit/67f846c9989d9f6d19605cc87ebe30ddefac3ed6))
* **mcp:** self-describing JSON-RPC server wrapping the kazi tools (T16.5) ([40ac946](https://github.com/kazi-org/kazi/commit/40ac9469be7cd48faa4aa6f36b6c49146d0d78df))
* **pool:** /claim&lt;-&gt;lease compose-boundary (claim-first, lease-second) (T20.7) ([993cdf1](https://github.com/kazi-org/kazi/commit/993cdf10402e7be80e4189a436233a566ed822fa))
* **pool:** acc_to_predicates runner script (T20.1) ([8aaee5d](https://github.com/kazi-org/kazi/commit/8aaee5d2a0ac0e922f58b6f80ee761642807fc17))
* **pool:** acc: -&gt; predicates bridge module (T20.1) ([2c75cc7](https://github.com/kazi-org/kazi/commit/2c75cc7e33cdd6f1dc55cfc28ea14d15320e112a))
* **pool:** block-unless-converged gate decision (T20.2) ([65af1e8](https://github.com/kazi-org/kazi/commit/65af1e8511974ae29ef024a183f51e72ca66efe6))
* **pool:** per-task blast-radius lease helper for a pooled run (T20.6) ([8b3f84a](https://github.com/kazi-org/kazi/commit/8b3f84a0ad9b50d81485b23377ad8a0df4194944))
* **predicate:** add optional group field (T12.2) ([9fe9572](https://github.com/kazi-org/kazi/commit/9fe9572e47fea8426379477f77510133ba1449c8))
* **reconcile:** Elixir surface scanner (T13.4) ([282ea3a](https://github.com/kazi-org/kazi/commit/282ea3a73c9f471b58d87c073e26bf7c60bb9758))
* **reconcile:** gherkin importer -&gt; grouped acceptance predicates (T13.2) ([c36378b](https://github.com/kazi-org/kazi/commit/c36378ba697a790ef668d38177fdda61f6bd9576))
* **reconcile:** OpenAPI importer -&gt; grouped http_probe predicates (T13.1) ([ae527a5](https://github.com/kazi-org/kazi/commit/ae527a51258d018e4704a0313e9731fdbf8e5322))
* **reconcile:** prose-doc importer via the harness (T13.3) ([3c39e5f](https://github.com/kazi-org/kazi/commit/3c39e5f08698077ccb87d750447624dfcccace6f))
* **reconcile:** surface-coverage meta-predicate (T13.5) ([fd52029](https://github.com/kazi-org/kazi/commit/fd52029ff26e8fb9d2ffcc3b1ddbebe56487a1ad))
* **runtime:** compose a per-iteration stream observer over persistence (T15.4) ([8049bb3](https://github.com/kazi-org/kazi/commit/8049bb376b5386bc489a05b0c6689b3bc5419719))
* **scheduler:** add DepGraph.dependents_of/2 for regression re-gating (T23.4) ([de37853](https://github.com/kazi-org/kazi/commit/de378536e8a3c2f6de5e9d675e56b1bc3b64dda0))
* **scheduler:** dynamic blast-radius overlap policy (T21.6) ([aa7bcb9](https://github.com/kazi-org/kazi/commit/aa7bcb9bd510ccc0015a2aa76d686c0dc391738a))
* **scheduler:** injectable collective integration + merge convergence (T21.5) ([b2e56f8](https://github.com/kazi-org/kazi/commit/b2e56f8e8302849114021fc89df8dd7e61fc4eec))
* **scheduler:** isolated git worktree per partition (T21.4) ([d7fcf54](https://github.com/kazi-org/kazi/commit/d7fcf54076eae0b9db7f7395c56bffe49c649844))
* **scheduler:** parallel coordinator + partition DynamicSupervisor (T21.1) ([fdf8fcb](https://github.com/kazi-org/kazi/commit/fdf8fcb034a51a45fa43a1561a8c21a526f97491))
* **scheduler:** per-partition budgets with derived rollup (T21.7) ([8c14403](https://github.com/kazi-org/kazi/commit/8c14403539fe6477c49fe7a62d23f81120ccde7f))
* **scheduler:** per-partition crash restart/escalation + integrate wiring (T21.10/T21.5) ([059f139](https://github.com/kazi-org/kazi/commit/059f1398a8f69f6db178c23356bf535d1586e448))
* **scheduler:** per-partition lease lifecycle (T21.3) ([3da1c04](https://github.com/kazi-org/kazi/commit/3da1c04f695dfc64b2f8386386ee9359c23e4232))
* **scheduler:** pipelined topological scheduler over the needs-DAG (T23.3) ([644be45](https://github.com/kazi-org/kazi/commit/644be4566c70d034830c80ba5931717c74734129))
* **scheduler:** regression re-gating + blocked-dep escalation (T23.4/T23.5) ([918331d](https://github.com/kazi-org/kazi/commit/918331debbdb0ae7f4d514da208669e99921371b))
* **scheduler:** route run_goals/2 single needs-DAG goal to the pipelined scheduler (T23.3) ([0033514](https://github.com/kazi-org/kazi/commit/0033514215cebe7710a49a85e358295a88571132))
* **scheduler:** run_goals/2 composes partition + lease + worktree (T21.2/T21.3/T21.4) ([271b816](https://github.com/kazi-org/kazi/commit/271b8160a0390c0ca384be11f48f5a2c3a6b1772))
* **scheduler:** supervise the partition DynamicSupervisor in the app tree (T21.1) ([607d47a](https://github.com/kazi-org/kazi/commit/607d47af7ad13f24a5a55f16464ee4cc532f4e53))
* **scheduler:** wire Kazi.Partition blast-radius partitioning (T21.2) ([a6eab42](https://github.com/kazi-org/kazi/commit/a6eab42c1d52e8de01a8c7c6c9b63fc872795fcc))
* **site:** add 'Bring Your Own Model' + 'AI-Ready Execution' feature cards ([37d0737](https://github.com/kazi-org/kazi/commit/37d073777b6bb9da2015d72f60cfb669e3d767b6))
* **site:** OG raster card, OG/Twitter meta, and prefers-color-scheme ([e3bc48d](https://github.com/kazi-org/kazi/commit/e3bc48d7a0bd8ba417cdf9f5570b31427a3825c1))
* **site:** semantic landmarks, heading order, and theme-aware classes ([2266141](https://github.com/kazi-org/kazi/commit/22661414b5675a39e47fc1889c41708d80e14981))
* **site:** source version from manifest, add proof visual + sections ([2dbd4ec](https://github.com/kazi-org/kazi/commit/2dbd4eca205c47a73b514d9dda62311bf9c01067))
* **teach:** the kazi Claude Code SKILL.md writer (T16.2) ([8d89d2f](https://github.com/kazi-org/kazi/commit/8d89d2f11ec658bfb14158c0c5ebe51430abfe4e))


### Bug Fixes

* **examples:** split test_runner cmd into cmd+args (T18.1) ([6f95a2d](https://github.com/kazi-org/kazi/commit/6f95a2dcda4c9de2815d7328235d5181e7bc69ea))
* **read-model:** deep-sanitize predicate evidence to JSON-safe (T18.2) ([38e1db2](https://github.com/kazi-org/kazi/commit/38e1db2a0e97880b5fee3b6f85e618b46e379445))
* **read-model:** idempotent terminal iteration persistence (T18.3) ([3641ff5](https://github.com/kazi-org/kazi/commit/3641ff595d6a9ef8668cffaf05a0e524bb48cdef))
* **readme:** escape quotes in Mermaid diagram label ([1086fd3](https://github.com/kazi-org/kazi/commit/1086fd3f8e7a9af1332d916dc75d1bf42c53b285))
* **readme:** make the reconcile-loop Mermaid diagram render on GitHub ([16c0b48](https://github.com/kazi-org/kazi/commit/16c0b486fa95730623187878c42cef3c068c5b80))
* **runtime:** idempotent iteration projection + over-budget regression test (T18.3/T18.4) ([7d86600](https://github.com/kazi-org/kazi/commit/7d86600eca0bb05366230b186a9af01c5c7dbd60))

## [0.3.0](https://github.com/kazi-org/kazi/compare/v0.2.0...v0.3.0) (2026-06-23)


### Features

* **authoring:** --adr ADR-lite rationale writer (T11.7) ([11f4a61](https://github.com/kazi-org/kazi/commit/11f4a61c0e4db3880e0497271b1d9ebb9dbc2699))
* **authoring:** harness-drafted candidate questions on the stub seam (T11.3) ([e1284a0](https://github.com/kazi-org/kazi/commit/e1284a00df10c96173448b4d5f104a90cf5d1771))
* **authoring:** pure clarify core + deterministic gap floor (T11.1, T11.2) ([cb99011](https://github.com/kazi-org/kazi/commit/cb990117c2b7f2955f0cc4f0d57d66410648a205))
* **authoring:** two-phase propose with clarify + inline rationale (T11.4, T11.5) ([fd5e36a](https://github.com/kazi-org/kazi/commit/fd5e36a97ab78f9667bff0d88dce2de2c4c57e1a))
* **cli:** interactive clarify phase + --yes/--strict/--adr + refine loop (T11.6, T11.8) ([4c2ac1b](https://github.com/kazi-org/kazi/commit/4c2ac1b0a0a3de2d2c78e2db8def256755b9e110))

## [0.2.0](https://github.com/kazi-org/kazi/compare/v0.1.1...v0.2.0) (2026-06-23)


### Features

* **site:** Astro + Tailwind landing page for kazi (T9.1/T9.2/T9.9) ([8f4501f](https://github.com/kazi-org/kazi/commit/8f4501f461fa6c1c78fd20fc2d7d6835e22e9d89))
