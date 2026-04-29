# Claim + Role Policy End-to-End Implementation Plan

## 1. Goal

Implement a production-safe authorization model for this project that supports:

- Global admins with full visibility.
- Team managers with team-scoped visibility.
- Normal users with self-only visibility.
- Future team growth without role explosion.

This plan is designed for the current stack:

- Next.js frontend in `frontend/`
- Python Lambda backend in `backend/src/handler.py`
- API Gateway JWT authorizer
- Entra ID (Azure AD) single-tenant identity

---

## 2. Target Authorization Model

### 2.1 Two-layer authorization

- Capability layer: App Roles (`Admin`, `TeamManager`, `User`)
- Scope layer: Entra security groups (team membership and manager assignment)

### 2.2 Enforcement source of truth

- Backend is authoritative for all access decisions.
- Frontend is only for user experience gating (hide/show pages), never security.

### 2.3 Group identity rule

- Always use group object IDs for authorization decisions.
- Never depend on group display names in policy logic.

---

## 3. Claim Contract (Auth Context v1)

## 3.1 Required token claims

Validate on every request:

- `iss`: tenant v2 issuer
- `aud`: `api://<application-id>`
- `tid`: expected tenant ID
- `ver`: should be `2.0`
- `scp`: includes `chat.access`
- `oid` (preferred) or `sub` (fallback)

### 3.2 Authorization claims

- `roles`: app roles for capability checks
- `groups`: direct group IDs when present
- `_claim_names` and `_claim_sources`: detect group overage and trigger Graph lookup

### 3.3 Effective runtime context

Build once per request:

- `principal_id`
- `is_admin`
- `managed_team_ids`
- `member_team_ids`
- `access_mode` (`ADMIN`, `TEAM`, `SELF`)

---

## 4. Workstreams and Delivery Phases

## Phase 0: Prerequisites and Design Freeze

### Tasks

- Confirm final role names: `Admin`, `TeamManager`, `User`.
- Confirm team ID format used internally (for example: `TEAM_A`, `TEAM_B`).
- Confirm who can assign users to groups and approve access.
- Define hard deny defaults for unknown or missing claims.

### Deliverables

- Signed-off role/scope matrix.
- Signed-off group naming convention and group ID mapping source.

### Acceptance criteria

- Stakeholders agree on role semantics and escalation process.

---

## Phase 1: Entra Configuration

### Tasks

- Create app roles in app registration:
  - `Admin`
  - `TeamManager`
  - `User`
- Create security groups for each team:
  - `<prefix>-Team-<X>-Managers`
  - `<prefix>-Team-<X>-Members`
- Assign app roles to groups:
  - Managers groups -> `TeamManager`
  - Members groups -> `User`
  - Admin group -> `Admin`
- Ensure Graph delegated permission and consent for OBO fallback:
  - `GroupMember.Read.All`
  - `User.Read`
- Verify `requestedAccessTokenVersion = 2`.

### Deliverables

- Role assignments completed for initial teams.
- Admin consent completed.

### Acceptance criteria

- Test users in each group receive expected role claim in API token.

---

## Phase 2: AWS and Secret/Config Setup

### Tasks

- Store OBO client credentials (or certificate metadata) in AWS Secrets Manager.
- Add environment variables to backend Lambda:
  - Entra tenant ID
  - Entra client ID
  - OBO secret reference
  - Group-to-team mapping source
  - Cache TTL setting
- Ensure Lambda IAM allows:
  - Read secrets
  - Read/write membership cache table
  - HTTPS egress to Graph

### Deliverables

- Secure secret path and IAM least privilege policy.

### Acceptance criteria

- Lambda can retrieve secret and reach Graph endpoint from runtime.

---

## Phase 3: Backend Authorization Foundation

Target file(s):

- `backend/src/handler.py` (initial implementation)
- Optional later split: `backend/src/authz.py`, `backend/src/graph_client.py`

### Tasks

- Add centralized claim extraction and validation helpers:
  - Validate issuer/audience/scope/tenant/version from trusted authorizer claims.
- Add capability resolver from `roles` claim.
- Add scope resolver from groups:
  - If token has groups, use them.
  - If overage, use OBO + Graph `transitiveMemberOf`.
- Build `effective_context` object for each request.
- Add deny-by-default policy entrypoint:
  - `authorize(action, resource, effective_context)`.

### Deliverables

- Reusable authorization functions with explicit decisions and reasons.

### Acceptance criteria

- Every protected route calls centralized authorization.
- Unauthorized requests fail with 403 and structured reason code.

---

## Phase 4: Membership Resolution and Caching

### Tasks

- Create `UserMembershipCache` DynamoDB table:
  - PK: `userId`
  - Attributes: `managedTeamIds`, `memberTeamIds`, `resolvedAt`, `ttl`
- Implement read-through cache:
  - Cache hit (not expired) -> use cached scope
  - Cache miss/expired -> OBO + Graph resolve, then persist
- Implement resilient fallback:
  - If Graph fails and fresh cache exists, use cache for read requests
  - If no cache and Graph fails, deny privileged team/admin operations

### Deliverables

- Stable membership resolution path with predictable latency.

### Acceptance criteria

- Cache hit ratio and fallback behavior are observable in logs.

---

## Phase 5: Data Model and Query Enforcement

### Tasks

- Extend chat session/message records with team metadata (if not already present):
  - `teamId`
  - `ownerUserId`
- Add query guardrails:
  - `SELF`: query only caller `ownerUserId`
  - `TEAM`: query only where `teamId in managedTeamIds`
  - `ADMIN`: unrestricted with pagination and audit logging
- Add guardrails for item reads/writes:
  - Validate ownership or team scope before returning any record.

### Deliverables

- Policy-compliant data access for all chat APIs.

### Acceptance criteria

- Cross-team and cross-user access attempts are rejected by backend.

---

## Phase 6: Frontend UX Gating

Target file(s):

- `frontend/hooks/use-auth.ts`
- `frontend/app/page.tsx`
- new pages for admin/team features as needed

### Tasks

- Extend auth hook to expose capability hints from token roles.
- Add route/page gating for UX:
  - Admin pages visible only to `Admin`
  - Team views visible to `TeamManager` and `Admin`
- Keep API calls unchanged regarding token source:
  - Continue sending only API access token
  - Do not request Graph scopes in frontend
- Add clear forbidden-state UI for backend 403 responses.

### Deliverables

- Role-aware navigation and page-level UX controls.

### Acceptance criteria

- Users only see UI surfaces appropriate to role, and all data remains backend-enforced.

---

## Phase 7: Observability, Audit, and Security Hardening

### Tasks

- Add structured authorization logs:
  - `principal_id`, `action`, `resource`, `decision`, `reason`, `team_scope`
- Add metrics:
  - OBO failures by category
  - Graph latency
  - cache hit/miss rate
  - authorization deny rate
- Add alerting thresholds for repeated OBO failure spikes.
- Secret hygiene:
  - Rotation policy and rollout runbook

### Deliverables

- Operational visibility into auth behavior and failures.

### Acceptance criteria

- On-call can diagnose failed authorization paths in minutes.

---

## Phase 8: Testing and Validation

### Test matrix users

- Admin user
- Team A manager
- Team A member
- Team B manager
- Team B member
- User with no mapped group

### Test scenarios

- Token claim validation failures (`iss`, `aud`, `scp`, `tid`) return 401/403 as designed.
- Team manager can read own team only.
- Team manager cannot read other team.
- Normal user cannot read others.
- Admin can read all.
- Group overage path works (Graph fallback).
- Cache expiry and refresh work.
- Graph temporary outage behavior is safe.

### Deliverables

- Integration tests and manual verification checklist.

### Acceptance criteria

- All critical authorization scenarios pass before rollout.

---

## Phase 9: Rollout Strategy

### Tasks

- Roll out in stages:
  1. Shadow logging mode (decision computed, existing behavior unchanged)
  2. Soft enforcement on non-critical endpoints
  3. Full enforcement
- Keep emergency feature flag to force `SELF` mode for non-admin users if incident occurs.
- Run migration for existing data needing `teamId` attribution.

### Deliverables

- Low-risk deployment with rollback path.

### Acceptance criteria

- No unintended privilege escalation and no major outage during cutover.

---

## 5. Endpoint Policy Table (Initial)

| Endpoint | SELF (`User`) | TEAM (`TeamManager`) | ADMIN (`Admin`) |
|---|---|---|---|
| `GET /chat/sessions` | Own sessions only | Team users + self within managed teams | All users |
| `GET /chat/sessions/{id}` | Must own session | Session owner must be in managed team | Any session |
| `POST /chat/messages` | Own session only | Own session only (recommended default) | Own or delegated mode (if explicitly enabled) |
| `DELETE /chat/sessions/{id}` | Own session only | Team-scoped delete only if business-approved | Any session |
| `GET /admin/*` | Deny | Deny | Allow |
| `GET /team/*` | Deny | Allow for managed teams | Allow |

---

## 6. Recommended Implementation Order (Practical)

1. Build centralized backend claim validation + authorization function.
2. Add group ID mapping and static team scope resolution from token groups.
3. Add OBO + Graph fallback for overage.
4. Add membership cache table.
5. Add data query enforcement and team metadata where needed.
6. Add frontend role-aware UX gating.
7. Add observability and staged rollout controls.

---

## 7. Risks and Mitigations

- Risk: Role/group misconfiguration in Entra.
  - Mitigation: pre-production validation script and assignment checklist.
- Risk: Group overage breaks scope resolution.
  - Mitigation: mandatory OBO fallback path + alarms.
- Risk: Graph latency increases API latency.
  - Mitigation: short TTL cache and async warm paths.
- Risk: Team logic encoded in mutable names.
  - Mitigation: group ID mapping table as authority.

---

## 8. Definition of Done

Authorization implementation is complete when:

- All protected endpoints use centralized policy checks.
- Capability and scope are both enforced in backend.
- Team managers are strictly team-bounded.
- Normal users are self-only.
- Admins can access all intended admin/team data.
- Overages, outages, and cache behavior are tested and monitored.
- Frontend reflects role-based UX, with backend as final authority.
