---
task: Make HA control-plane configurable to skip
slug: 20260328-000000_ha-configurable-cp
effort: standard
phase: complete
progress: 9/9
mode: interactive
started: 2026-03-28T00:00:00Z
updated: 2026-03-28T00:00:00Z
---

## Context

Add `ha_enabled` boolean variable (default `true`) to gate all kube-vip and multi-CP behavior. When false, kubeadm init runs without `--control-plane-endpoint` or `--upload-certs`, kube-vip is skipped entirely, and no secondary CPs are joined. Existing HA behavior is unchanged when true.

## Criteria

- [x] ISC-1: `ha_enabled` variable added to variables.tf with default `true`
- [x] ISC-2: When `ha_enabled=false`, kube-vip phase 1 commands are skipped
- [x] ISC-3: When `ha_enabled=false`, VIP ping-wait is skipped
- [x] ISC-4: When `ha_enabled=false`, kubeadm init omits `--control-plane-endpoint` and `--upload-certs`
- [x] ISC-5: When `ha_enabled=false`, kube-vip.conf creation and RBAC are skipped
- [x] ISC-6: When `ha_enabled=false`, kube-vip phase 2 manifest and patch are skipped
- [x] ISC-7: `join_secondary_cps` count is 0 when `ha_enabled=false`
- [x] ISC-8: `fetch_join_commands` skips CP join script fetch when `ha_enabled=false`
- [x] ISC-9: VIP-based apiserver wait loop is skipped when `ha_enabled=false`

## Decisions

## Verification
