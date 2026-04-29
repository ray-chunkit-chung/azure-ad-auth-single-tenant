# App-Role-Only Authorization End-to-End Implementation Plan

## 1. Goal

Implement a production-safe authorization model for this project using only app roles that supports:

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

### 2.1 Single-layer capability with app-owned scope

- Capability layer: App Roles (`Admin`, `TeamManager`, `User`)
- Scope layer: Application data store (not Entra groups)
  - Team assignments are stored and managed by the application backend.

### 2.2 Enforcement source of truth

- Backend is authoritative for all access decisions.
- Frontend is only for user experience gating (hide/show pages), never security.

### 2.3 Scope identity rule

- Always use internal immutable team IDs for authorization decisions.
- Never depend on display names in policy logic.

---

## 3. Claim Contract (Auth Context v2)

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
- No dependency on `groups`, `_claim_names`, or `_claim_sources`

### 3.3 Effective runtime context

Build once per request:

- `principal_id`
- `app_role` (`Admin`, `TeamManager`, `User`)
- `managed_team_ids` (resolved from app data store)
- `member_team_ids` (resolved from app data store)
- `access_mode` (`ADMIN`, `TEAM`, `SELF`)

---

## 4. Workstreams and Delivery Phases

## Phase 0: Prerequisites and Design Freeze

### Tasks

- Confirm final role names: `Admin`, `TeamManager`, `User`.
- Confirm team ID format used internally (for example: `TEAM_A`, `TEAM_B`).
- Confirm who can assign users to teams in the application.
- Define hard deny defaults for unknown or missing claims.
- Define single-role precedence rule if multiple roles appear in token.

### Deliverables

- Signed-off role/scope matrix.
- Signed-off team assignment ownership and update workflow.

### Acceptance criteria

- Stakeholders agree on role semantics and team assignment governance.

---

## Phase 1: Entra Configuration (Roles Only)

### Tasks

- Create app roles in app registration:
  - `Admin`
  - `TeamManager`
  - `User`
- Assign app roles to users or Entra application assignments as your org requires.
- Verify `requestedAccessTokenVersion = 2`.
- Remove any requirement for group claims in API tokens.

### Deliverables

- Role assignments completed for initial users.

### Acceptance criteria

- Test users in each role receive expected `roles` claim in API token.

---

## Phase 2: Application Scope Data Setup

### Tasks

- Create an app-owned team access store (for example, DynamoDB):
  - `UserTeamAccess` table
  - PK: `userId`
  - Attributes: `managedTeamIds`, `memberTeamIds`, `updatedAt`, `updatedBy`
- Define admin-only APIs or tooling to manage assignments.
- Add environment variables to backend Lambda:
  - Table name for user-team access
  - Cache TTL setting (if caching enabled)
- Ensure Lambda IAM allows read/write as required.

### Deliverables

- Team scope source of truth in application data.

### Acceptance criteria

- Backend can resolve team scope for any authenticated user without Graph calls.

---

## Phase 3: Backend Authorization Foundation

Target file(s):

- `backend/src/handler.py` (initial implementation)
- Optional later split: `backend/src/authz.py`, `backend/src/access_store.py`

### Tasks

- Add centralized claim extraction and validation helpers:
  - Validate issuer/audience/scope/tenant/version from trusted authorizer claims.
- Add capability resolver from `roles` claim.
- Add scope resolver from application access store:
  - Load `managed_team_ids` and `member_team_ids` by `principal_id`.
- Build `effective_context` object for each request.
- Add deny-by-default policy entrypoint:
  - `authorize(action, resource, effective_context)`.

### Deliverables

- Reusable authorization functions with explicit decisions and reasons.

### Acceptance criteria

- Every protected route calls centralized authorization.
- Unauthorized requests fail with 403 and structured reason code.

---

## Phase 4: Scope Resolution Caching (Optional but Recommended)

### Tasks

- Add read-through cache for resolved user scope.
- Cache hit (not expired) -> use cached scope.
- Cache miss/expired -> load from `UserTeamAccess` and refresh cache.
- Define safe fallback:
  - If cache exists and store is temporarily unavailable, use short-lived cached scope for read requests.
  - If no cache and store unavailable, deny team/admin operations.

### Deliverables

- Stable scope resolution path with predictable latency.

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
  - scope store latency/errors
  - cache hit/miss rate
  - authorization deny rate
- Add alerting thresholds for repeated scope resolution failures.
- Add admin change audit trail for team assignments.

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
- User with no team assignment

### Test scenarios

- Token claim validation failures (`iss`, `aud`, `scp`, `tid`) return 401/403 as designed.
- Team manager can read own team only.
- Team manager cannot read other team.
- Normal user cannot read others.
- Admin can read all.
- Scope cache expiry and refresh work.
- Scope store temporary outage behavior is safe.

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
2. Implement app-owned user-team access store and resolver.
3. Add optional scope caching for latency and resilience.
4. Add data query enforcement and team metadata where needed.
5. Add frontend role-aware UX gating.
6. Add observability and staged rollout controls.

---

## 7. Risks and Mitigations

- Risk: Role misconfiguration in Entra.
  - Mitigation: pre-production validation script and assignment checklist.
- Risk: Team assignment drift in app data store.
  - Mitigation: change audit log and periodic reconciliation checks.
- Risk: Scope store latency impacts API latency.
  - Mitigation: short TTL cache and warmed reads.
- Risk: Over-permissive fallback during dependency failure.
  - Mitigation: fail closed for write/admin paths and strict emergency mode.

---

## 8. Definition of Done

Authorization implementation is complete when:

- All protected endpoints use centralized policy checks.
- App roles are enforced for capability in backend.
- Team scope is enforced from app-owned assignment data.
- Team managers are strictly team-bounded.
- Normal users are self-only.
- Admins can access all intended admin/team data.
- Dependency outages and cache behavior are tested and monitored.
- Frontend reflects role-based UX, with backend as final authority.

---

## 9. Explicit Trade-offs of App-Role-Only Model

- Pros:
  - Simpler token contract (`roles` only).
  - No group overage handling.
  - No Microsoft Graph dependency in request path.
- Cons:
  - You must build and operate your own team assignment system.
  - Identity governance is split between Entra (roles) and app data (scope).
  - Extra admin tooling is needed for assignment lifecycle.

---

## 10. v2.1 Concrete Scope Store Design (DynamoDB)

### 10.1 Recommended table

Use one table named `AccessControl` with denormalized items for both read patterns.

- Partition key: `pk` (string)
- Sort key: `sk` (string)
- TTL attribute (optional): `ttl`

### 10.2 Item shapes

User aggregate item (fast authorization lookup by user):

```json
{
  "pk": "USER#<userId>",
  "sk": "PROFILE",
  "managedTeamIds": ["TEAM_A", "TEAM_B"],
  "memberTeamIds": ["TEAM_A", "TEAM_C"],
  "version": 3,
  "updatedAt": "2026-04-29T10:20:30Z",
  "updatedBy": "<adminUserId>"
}
```

Team membership index item (fast reverse lookup by team):

```json
{
  "pk": "TEAM#<teamId>",
  "sk": "USER#<userId>",
  "roleType": "MANAGER|MEMBER",
  "updatedAt": "2026-04-29T10:20:30Z",
  "updatedBy": "<adminUserId>"
}
```

### 10.3 Access patterns covered

- Resolve auth context: `GetItem(pk=USER#<userId>, sk=PROFILE)`
- List team members/managers: `Query(pk=TEAM#<teamId>)`
- Rebuild user profile from team assignments (repair job support)

### 10.4 Write consistency rules

- Every assignment update must write both user aggregate and team index records.
- Use `TransactWriteItems` to keep dual writes atomic.
- Include `version` and optimistic concurrency checks on the user aggregate item.

### 10.5 Authorization cache key

- Cache key: `authctx:<userId>:v<version>`
- Invalidate naturally when `version` increments.

---

## 11. v2.1 Admin API Contract (Sample)

All endpoints below require `Admin` app role.

### 11.1 Get user access profile

- `GET /admin/access/users/{userId}`

Response 200:

```json
{
  "userId": "<userId>",
  "managedTeamIds": ["TEAM_A"],
  "memberTeamIds": ["TEAM_A", "TEAM_B"],
  "version": 3,
  "updatedAt": "2026-04-29T10:20:30Z",
  "updatedBy": "<adminUserId>"
}
```

### 11.2 Upsert full user access profile

- `PUT /admin/access/users/{userId}`

Request body:

```json
{
  "managedTeamIds": ["TEAM_A"],
  "memberTeamIds": ["TEAM_A", "TEAM_B"],
  "expectedVersion": 3,
  "reason": "Quarterly access review"
}
```

Behavior:

- Validates team IDs exist.
- Enforces `managedTeamIds` is a subset of `memberTeamIds` (recommended policy).
- Writes atomically to user aggregate and team index records.
- Returns 409 on `expectedVersion` mismatch.

### 11.3 Add one team assignment

- `POST /admin/access/users/{userId}/teams`

Request body:

```json
{
  "teamId": "TEAM_C",
  "roleType": "MANAGER",
  "reason": "Backfill manager coverage"
}
```

Behavior:

- `roleType=MANAGER` adds user to both `managedTeamIds` and `memberTeamIds`.
- `roleType=MEMBER` adds user only to `memberTeamIds`.
- Idempotent if assignment already exists.

### 11.4 Remove one team assignment

- `DELETE /admin/access/users/{userId}/teams/{teamId}?roleType=MANAGER|MEMBER`

Behavior:

- Removing `MEMBER` also removes `MANAGER` for same team if present.
- Returns 204 for successful and idempotent delete.

### 11.5 List team users

- `GET /admin/access/teams/{teamId}/users?roleType=MANAGER|MEMBER|ALL&limit=50&cursor=...`

Response 200:

```json
{
  "teamId": "TEAM_A",
  "items": [
    { "userId": "u1", "roleType": "MANAGER" },
    { "userId": "u2", "roleType": "MEMBER" }
  ],
  "nextCursor": "..."
}
```

### 11.6 Error model

Use structured error codes across all admin APIs:

- `ACCESS_INVALID_TEAM_ID`
- `ACCESS_VERSION_CONFLICT`
- `ACCESS_INVALID_ROLE_TYPE`
- `ACCESS_FORBIDDEN`
- `ACCESS_PROFILE_NOT_FOUND`

---

## 12. v2.1 Implementation Notes for This Repo

- Add admin handlers in `backend/src/handler.py` first, then split later to `backend/src/access_admin.py` if needed.
- Keep policy checks centralized in one `authorize(...)` path before data fetch.
- For frontend admin UX, render read-only membership data first, then add update actions after backend audit logging is in place.

---

## 13. Explicit Execution Plan (Implement First, Then Expand)

This section defines the exact implementation order for this repository.

### 13.1 Step 1: Backend authorization skeleton (no behavior change)

Scope:

- Create centralized auth helpers in `backend/src/handler.py`:
  - `extract_claims(event)`
  - `validate_required_claims(claims)`
  - `resolve_app_role(claims)`
  - `build_effective_context(claims, access_profile)`
  - `authorize(action, resource, effective_context)`
- Wire helpers into existing request flow in shadow mode (log-only decisions).

Deliverables:

- Centralized auth helper block committed.
- Structured deny reason codes defined and logged.

Exit criteria:

- Existing endpoints still behave as before.
- Logs include computed decision and reason for each protected endpoint.

### 13.2 Step 2: AccessControl store and resolver

Scope:

- Add data access module (initially in `backend/src/handler.py`, later split):
  - `get_user_access_profile(user_id)`
  - `put_user_access_profile(...)`
  - `list_team_users(team_id, role_type, cursor, limit)`
- Implement DynamoDB access for `AccessControl` table using section 10 schema.
- Add environment variables and config loading:
  - `ACCESS_CONTROL_TABLE_NAME`
  - `AUTHCTX_CACHE_TTL_SECONDS`

Deliverables:

- Read/write operations for user profile and team index.
- Profile version increment behavior on each write.

Exit criteria:

- Backend can resolve `managedTeamIds` and `memberTeamIds` for any user ID.
- Writes are atomic via transaction and return conflict on version mismatch.

### 13.3 Step 3: Admin APIs for assignment lifecycle

Scope:

- Implement endpoints from section 11:
  - `GET /admin/access/users/{userId}`
  - `PUT /admin/access/users/{userId}`
  - `POST /admin/access/users/{userId}/teams`
  - `DELETE /admin/access/users/{userId}/teams/{teamId}`
  - `GET /admin/access/teams/{teamId}/users`
- Enforce `Admin` role on all admin access endpoints.
- Add input validation and standardized error responses.

Deliverables:

- Full assignment CRUD path in backend.
- Structured errors (`ACCESS_*`) returned consistently.

Exit criteria:

- Endpoints pass positive and negative tests for authorization and validation.

### 13.4 Step 4: Enforce authorization on chat endpoints

Scope:

- Replace shadow mode with enforcement mode for chat routes.
- Enforce policy table in section 5:
  - `SELF`: owner-only
  - `TEAM`: managed teams only
  - `ADMIN`: full access
- Ensure all reads and writes evaluate policy before data return/mutation.

Deliverables:

- Policy checks active on each protected chat route.

Exit criteria:

- Cross-user and cross-team unauthorized access returns 403 with reason code.

### 13.5 Step 5: Frontend role-aware UX gating

Scope:

- Update `frontend/hooks/use-auth.ts` to expose role hints.
- Update `frontend/app/page.tsx` to conditionally show admin/team navigation.
- Add forbidden-state handling for backend 403 responses.

Deliverables:

- Role-aware UI behavior aligned with backend enforcement.

Exit criteria:

- Non-admin users cannot see admin UI elements.
- Unauthorized API responses render clear UX state.

### 13.6 Step 6: Observability and runbook readiness

Scope:

- Add structured auth decision logs and latency metrics.
- Add counters for deny rate, version conflicts, and dependency failures.
- Document incident fallback: force non-admin to `SELF` mode.

Deliverables:

- Dashboards/alarms and operational runbook updates.

Exit criteria:

- On-call can identify root cause for deny spikes or access resolution failures.

### 13.7 Step 7: Rollout gates

Use these gates before full enforcement:

1. Shadow mode in lower environment with no regressions.
2. Soft enforcement on non-critical routes.
3. Full enforcement in production with feature flag fallback enabled.

Go-live checklist:

- Test matrix in section 8 fully passed.
- Admin APIs validated with at least two real team scenarios.
- Audit logs confirm who changed access, when, and why.
