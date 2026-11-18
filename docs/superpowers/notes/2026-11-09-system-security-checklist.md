# Security checklist for the system pages (input for Task 10)

One row per requirement: where it is enforced, the test or check that proves it, and the result of the last run
(integration run of 2026-11-19: Python 528 tests OK with 10 skipped, ObjC tests OK). A row marked "by hand" needs the
running app and is listed in the acceptance note under "For the user".

| Requirement | Test or check | Result |
|---|---|---|
| The local API listens on loopback only | `tests/test_api_server.py` `test_binds_loopback_only`, `test_foreign_host_header_rejected` | pass |
| The API key is compared in constant time; no key or a wrong key gets 401 | `test_key_compare_is_constant_time`, `test_no_key_401_wrong_key_401_right_key_200`, `test_bad_auth_lockout_never_blocks_correct_key` | pass |
| The key lives in the Keychain (signed build) and never in a log | `test_server_logs_never_contain_key`; Keychain prompt with the signed app: by hand | pass / by hand |
| Size limits: JSON, per-route ceilings, uploads, quota, TTL | `test_oversized_json_413_without_reading_body`, `test_per_route_json_ceilings`, `test_upload_over_limit_413_and_nothing_left_on_disk`, `test_upload_quota_and_ttl`, `test_pair_body_ceiling_2k` | pass |
| No path ever comes from a request: uploads are named by the server, outputs stay in the Outputs folder, answers carry no paths | `test_upload_name_is_server_chosen`, `test_output_outside_outputs_dir_is_refused`, `test_job_snapshot_never_exposes_paths`, `test_error_and_status_strings_never_leak_paths`; `tests/test_ytdl.py` `test_roots_come_from_the_app_not_from_the_request` | pass |
| CORS, Origin and Host: a browser origin is refused, no CORS headers anywhere, OPTIONS refused | `test_origin_header_403_and_no_cors_headers_anywhere`, `test_options_is_rejected`, `test_foreign_host_header_rejected` | pass |
| Rate limits, connection cap, slow clients, trickled headers and bodies | `test_rate_limit_429_with_retry_after`, `test_connection_cap_503`, `test_slow_client_times_out`, `test_header_trickle_dropped_within_deadline_and_legit_request_works`, `test_body_trickle_dropped_within_deadline`, `test_upload_trickle_below_minimum_rate_dropped` | pass |
| Request schema: unknown fields, bad types and ranges are refused; cloning needs explicit consent | `test_schema_rejects_unknown_fields_bad_types_ranges`, `test_clone_requires_consent_true`, `test_job_id_format_enforced` | pass |
| Bridge pairing: the Mac approves every device, requests expire, pending ones are capped | `test_pair_flow_requires_mac_approval`, `test_pair_denied_and_expired`, `test_pair_pending_cap_and_rate_limit`, `test_approved_token_not_collected_in_time_expires`; a real pairing with a phone: by hand | pass / by hand |
| Token isolation: the local key is not valid on the Bridge, a device token not on the local port, jobs are scoped to the device, a revoked device gets 401 | `test_local_key_not_accepted_on_bridge_and_device_token_not_on_local`, `test_bridge_jobs_scoped_to_device`, `test_revoked_device_401`, `test_unpaired_device_gets_nothing`, `test_bridge_routes_absent_on_local_listener` | pass |
| The tunnel helper is pinned and checked before it runs; it dies with the app | `tests/test_bridge_pin.py` (`test_pin_shape`, `test_pin_is_copied_into_the_app`), `test_refuses_a_changed_or_unsafe_file`, `test_stdin_eof_kills_the_tunnel`, `test_parent_death_without_eof_kills_the_tunnel`; running the real download: by hand | pass / by hand |
| Plugins: allowlisted environment, sandbox (no writes outside the work folder, no network unless allowed, no `~/.ssh`, no home), manifest checks, digest and trust reset | `tests/test_plugins.py` `test_build_env_contains_only_allowlist`, `test_sandbox_blocks_*`, `test_manifest_*`, `test_folder_digest_changes_when_any_file_changes_and_is_stable`, `test_trust_reset_when_digest_changes`, `test_relay_drops_forged_outputs_and_keeps_inside_ones` | pass |
| Secrets are not stored in jobs or logs (`token`, `key`, `password`, `secret`, `authorization` become `***`) | `tests/objc/jobs_test.m` (redaction and retry after relaunch) | pass |
| The offline gate: Offline mode blocks Edge TTS, YouTube, Bridge, plugin network and model downloads; every network-capable file is listed | `tests/objc/network_test.m`, `tests/test_net.py` `test_model_download_is_blocked_offline`, `tests/test_network_allowlist.py`, `tests/test_privacy_catalog.py` | pass |
| Engines run sandboxed, offline, with a fixed set of write folders; output folders come from the app | `tests/test_pro_run.py`, `tests/test_engines.py`, `tests/test_stems.py`, `tests/test_rvc.py`; `lsof -iTCP -sTCP:ESTABLISHED` on a running engine: by hand | pass / by hand |
| Downloaded JSON answers are capped (8 MB) and a non-https Hugging Face address is refused | `tests/objc/modelfolder_test.m` (`endpointIsSecure`); the cap is in `OVFetchJSON` (`OVDownloader.m`) | pass (cap: reviewed, not unit-tested) |

Rows not closed: none that a scanner would find in the code. The "by hand" rows need a person with the signed build.
