# Learnings

## [LRN-20260728-001] correction

**Logged**: 2026-07-28T15:30:00+08:00
**Priority**: high
**Status**: pending
**Area**: infra

### Summary

中国大陆服务器使用非标准 HTTPS 端口不能作为规避 ICP 备案的合规迁移路线。

### Details

工信部现行规则按“在境内通过域名或 IP 提供互联网信息服务”判断，并不以 80/443 端口为边界。非标准端口可能暂时避开个别接入商的端口级技术拦截，但不免除备案义务，且仍可能被接入商阻断。已备案域名迁入新的境内接入商时，也应核对并完成相应接入备案。

### Suggested Action

从宁波云迁移计划中删除“非标准 HTTPS 端口可作为 ICP 替代路线”的表述。合规路线应为完成 ICP/接入备案，或将服务部署在中国大陆以外节点。

### Metadata

- Source: conversation
- Related Files: PROJECT_PLAN.md
- Tags: icp, migration, compliance, mainland-china

---
