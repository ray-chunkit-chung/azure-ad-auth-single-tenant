# Security-Group-Only Authorization End-to-End Implementation Plan

## 1. Goal

Implement a production-safe authorization model for this project using only Azure AD (Entra ID) security groups that supports:

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

### 2.1 Single-source authorization model

- Capability and scope are both derived from Entra security group membership.
- No app role dependency for authorization decisions.

### 2.2 Enforcement source of truth

- Backend is authoritative for all access decisions.
- Frontend is only for user experience gating (hide/show pages), never security.

### 2.3 Group identity rules

- Always use group object IDs for authorization decisions.
- Never depend on group display names in policy logic.
- Group names are for operator readability only.

### 2.4 Recommended group pattern

For each team `<X>`:

- `<prefix>-Team-<X>-Managers`
- `<prefix>-Team-<X>-Members`

Global:

- `<prefix>-Admins`

---

## 3. Claim Contract (Auth Context v3)

### 3.1 Required token claims

Validate on every request:

- `iss`: tenant v2 issuer
- `aud`: `api://<application-id>`
- `tid`: expected tenant ID
- `ver`: should be `2.0`
- `scp`: includes `chat.access`
- `oid` (preferred) or `sub` (fallback)

### 3.2 Authorization claims

- `groups`: group object IDs when present
- `_claim_names` and `_claim_sources`: detect group overage indicators

### 3.3 Effective runtime context

Build once per request:

- `principal_id`
- `is_admin`
- `managed_team_ids`
- `member_team_ids`
- `access_mode` (`ADMIN`, `TEAM`, `SELF`)
- `membership_source` (`TOKEN`, `GRAPH`, `CACHE`)

---

## 4. Workstreams and Delivery Phases

## Phase 0: Prerequisites and Design Freeze

### Tasks

- Confirm team ID format used internally (for example: `TEAM_A`, `TEAM_B`).
- Confirm final group naming standard and ownership model.
- Define who can create teams and approve manager/member assignments.
- Define hard deny defaults for unknown or missing claims.
- Approve source of truth for group ID to team ID mapping.

### Deliverables

- Signed-off group matrix and mapping source.
- Signed-off operational ownership for group lifecycle.

### Acceptance criteria

- Stakeholders agree on group semantics, escalation flow, and deny defaults.

---

## Phase 1: Entra Configuration (Groups Only)

### Tasks

- Create security groups for admins and initial teams:
  - `<prefix>-Admins`
  - `<prefix>-Team-<X>-Managers`
  - `<prefix>-Team-<X>-Members`
- Add initial users to corresponding groups.
- Configure token group claim behavior for API tokens.
- Ensure Graph delegated permission and consent for overage fallback:
  - `GroupMember.Read.All`
  - `User.Read`
- Verify `requestedAccessTokenVersion = 2`.

### Deliverables

- Group assignments completed for initial users.
- Admin consent completed for Graph fallback path.

### Acceptance criteria

- Test users receive expected group membership path (direct claim or overage indicators).

---

## Phase 2: AWS and Secret/Config Setup

### Tasks

- Store OBO client credentials (or certificate metadata) in AWS Secrets Manager.
- Add environment variables to backend Lambda:
  - Entra tenant ID
  - Entra client ID
  - OBO secret reference
  - Group ID to team ID mapping source
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
- Add group-based capability resolver:
  - `is_admin` if principal is in admin group ID.
- Add scope resolver from group memberships:
  - If token contains `groups`, use them.
  - If overage indicators are present, resolve through OBO + Graph `transitiveMemberOf`.
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
  - Attributes: `managedTeamIds`, `memberTeamIds`, `isAdmin`, `resolvedAt`, `ttl`, `source`
- Implement read-through cache:
  - Cache hit (not expired) -> use cached scope
  - Cache miss/expired -> resolve from token groups or Graph fallback, then persist
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

- Extend auth hook to expose capability hints from resolved context.
- Add route/page gating for UX:
  - Admin pages visible only to admin group members
  - Team views visible to team managers and admins
- Keep API calls unchanged regarding token source:
  - Continue sending only API access token
  - Do not request Graph scopes in frontend
- Add clear forbidden-state UI for backend 403 responses.

### Deliverables

- Group-aware navigation and page-level UX controls.

### Acceptance criteria

- Users only see UI surfaces appropriate to effective scope, and all data remains backend-enforced.

---

## Phase 7: Observability, Audit, and Security Hardening

### Tasks

- Add structured authorization logs:
  - `principal_id`, `action`, `resource`, `decision`, `reason`, `team_scope`, `membership_source`
- Add metrics:
  - OBO failures by category
  - Graph latency
  - cache hit/miss rate
  - authorization deny rate
- Add alerting thresholds for repeated OBO failure spikes.
- Secret hygiene:
  - rotation policy and rollout runbook

### Deliverables

- Operational visibility into auth behavior and failures.

### Acceptance criteria

- On-call can diagnose failed authorization paths in minutes.

---

## Phase 8: Testing and Validation

### Test matrix users

- Admin group member
- Team A manager group member
- Team A member group member
- Team B manager group member
- Team B member group member
- User with no mapped group
- Overage test user (high group count)

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

| Endpoint | SELF (Team Member) | TEAM (Team Manager) | ADMIN (Admin Group) |
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
6. Add frontend group-aware UX gating.
7. Add observability and staged rollout controls.

---

## 7. Risks and Mitigations

- Risk: Group misconfiguration in Entra.
  - Mitigation: pre-production validation script and assignment checklist.
- Risk: Group overage breaks scope resolution.
  - Mitigation: mandatory OBO fallback path + alarms.
- Risk: Graph latency increases API latency.
  - Mitigation: short TTL cache and async warm paths.
- Risk: Team logic encoded in mutable names.
  - Mitigation: group ID mapping table as authority.
- Risk: Graph outage creates authorization instability.
  - Mitigation: safe fallback policy and fail-closed privileged actions.

---

## 8. Definition of Done

Authorization implementation is complete when:

- All protected endpoints use centralized policy checks.
- Capability and scope are both enforced in backend via group membership.
- Team managers are strictly team-bounded.
- Team members are self-only.
- Admin group members can access all intended admin/team data.
- Overages, outages, and cache behavior are tested and monitored.
- Frontend reflects group-based UX, with backend as final authority.

---

## 9. Explicit Trade-offs of Security-Group-Only Model

- Pros:
  - Natural fit for team-based organizational growth.
  - IT-friendly membership administration in Entra.
  - No app-role lifecycle dependency for authorization logic.
- Cons:
  - Group overage handling is mandatory at scale.
  - Graph dependency is required for completeness in some flows.
  - More backend complexity for membership resolution and caching.
  - Strict group governance is required to avoid policy drift.

---

## 10. New Team + New Manager Onboarding Runbook (Groups Only)

Scenario: a new manager joins and creates Team D.

### Steps

1. Create team groups in Entra:
   - `<prefix>-Team-D-Managers`
   - `<prefix>-Team-D-Members`
2. Add the new manager to `<prefix>-Team-D-Managers`.
3. Optionally add the manager to `<prefix>-Team-D-Members` if your policy requires explicit member inclusion.
4. Update the app group mapping source with the two new group object IDs:
   - Team D manager group ID -> `TEAM_D` manager scope
   - Team D member group ID -> `TEAM_D` member scope
5. Validate token path:
   - If `groups` claim includes Team D group IDs, validate authorization directly.
   - If overage indicators appear, validate Graph fallback resolves Team D memberships.
6. Execute post-change checks:
   - Manager can access `/team/*` for Team D only.
   - Manager cannot access Team A/B data unless assigned.
   - Non-admin manager cannot access `/admin/*`.

### Operational controls

- Enforce change approval for mapping updates.
- Log mapping changes with operator identity and timestamp.
- Keep emergency rollback: remove group mapping or membership to revoke access quickly.

### Acceptance criteria

- New manager receives Team D manager access within expected propagation window.
- Cross-team access remains denied.
- Audit log captures who made group and mapping changes.

---

## 11. Appendix: Choosing v2 vs v3

Use this appendix to decide between:

- v2: app-role-only model in `USER_ROLE_PLAN_v2.md`
- v3: security-group-only model in this document

### 11.1 Choose v2 (app-role-only) when

- You want the most predictable request-path behavior and minimal external dependency.
- Your team can own internal access administration tooling and data quality.
- You want to avoid group overage and Graph fallback complexity.
- You prefer tighter application-level control over scope assignments.

### 11.2 Choose v3 (groups-only) when

- Your organization already manages access centrally in Entra groups.
- Team onboarding/offboarding must be handled by IT or identity operations.
- You expect frequent team membership changes and want directory-native workflows.
- You are prepared to operate Graph fallback, cache, and outage-safe authorization paths.

### 11.3 Decision matrix

| Decision factor | v2 App-role-only | v3 Groups-only |
|---|---|---|
| Runtime simplicity | Higher | Lower |
| External dependency in auth path | Lower | Higher (Graph on overage path) |
| Alignment with enterprise IAM ops | Medium | High |
| Team growth scalability without app admin overhead | Medium | High |
| Deterministic token contract | High | Medium |
| Operational burden in application backend | Medium | High |

### 11.4 Recommended default

- If your primary risk is authorization runtime failure, choose v2.
- If your primary risk is access governance drift outside Entra, choose v3.
- If allowed in future, the strongest long-term pattern is hybrid:
  - app roles for global capability
  - groups for team scope
