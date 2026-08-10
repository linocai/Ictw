# Learnings

已解决记录归档于 `archive/learnings/LEARNINGS-through-2026-08-08.md`。

## [LRN-20260728-001] correction

**Logged**: 2026-07-28T15:30:00+08:00
**Priority**: high
**Status**: pending
**Area**: infra

### Summary

中国大陆服务器使用非标准 HTTPS 端口不能作为规避 ICP 备案的合规迁移路线。

### Details

工信部规则按“在境内通过域名或 IP 提供互联网信息服务”判断，并不以 80/443 端口为边界。非标准端口不免除备案义务，已备案域名迁入新的境内接入商时也应核对接入备案。

### Suggested Action

境内服务使用合规的 ICP／接入备案路线；不得把非标准 HTTPS 端口描述为备案替代方案。

### Metadata

- Source: conversation
- Related Files: `/Users/linotsai/Lino/hk_info.md`
- Tags: icp, migration, compliance, mainland-china
