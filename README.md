# Full Structured DB Schema (Supabase / Postgres)

This repository contains a **Supabase-ready Postgres schema** for the KINETIC app domain: user profiles, exercises, video-backed form analyses, AI analysis results, workout planning, and workout session logs. The schema is defined as a Supabase migration under `supabase/migrations/`.

The intended workflow is:

- **Supabase Auth** (`auth.users`) is the source of truth for users.
- App-owned data lives in **`public`** tables with **Row Level Security (RLS)** enabled.
- Videos/frames live in **Supabase Storage** in a private bucket, accessed via signed URLs and protected by Storage RLS.

---

## What’s in this repo

- **`supabase/migrations/20260508045559_kinetic_schema.sql`**
  - Creates tables, indexes, and RLS policies.
  - Seeds a small starter list of exercises.
  - Creates a private Storage bucket (`form-videos`) and adds Storage policies for per-user access.
- **`supabase/config.toml`**
  - Local Supabase CLI configuration (ports, enabled services, etc.).
- **`package.json` / `package-lock.json`**
  - Installs the Supabase CLI as a dev dependency so you can run it with `npx supabase ...`.

---

## Data model (high-level)

### `auth.users` (Supabase-managed)

Supabase Auth maintains user records in `auth.users`. This schema **does not** create a separate users table.

### `public.user_profiles`

Stores user-facing profile information and onboarding metadata.

- **Primary key**: `profile_id` (UUID)
- **One-to-one** with `auth.users` via:
  - `user_profiles.user_id` → `auth.users.id` (**unique**, `ON DELETE CASCADE`)
- **Automatic profile creation**:
  - A trigger on `auth.users` runs `public.handle_new_user()` and inserts a profile row for every new auth user.

### `public.exercises`

Canonical exercise catalog used by both form analyses and workout planning/logging.

- Includes fields like `name`, `type`, `muscle_groups`, `equipment`, `difficulty`, `description`, `is_active`.
- Contains a small seed list to get started.

### `public.form_analyses`

Represents an uploaded movement video and the metadata needed to process/score it.

Typical lifecycle:

1. A user uploads a video to Storage (private).
2. The app inserts a row in `public.form_analyses` with the `video_url` (storage object path) and metadata.
3. Background processing updates `status` from `pending` → `processing` → `completed` (or `failed`).

Key columns:

- `session_id`: UUID primary key
- `user_id`: the owner (`auth.users.id`)
- `exercise_id`: which movement is being analyzed (`public.exercises.exercise_id`)
- `video_url`: Storage object path (string)
- `status`: constrained to `pending|processing|completed|failed`
- `created_at`: timestamp

Indexes are provided for common access patterns:

- queries by `user_id`
- filtering by `exercise_id`
- filtering by `status`
- recent activity per user (`(user_id, created_at DESC)`)

### `public.form_analysis_results`

Stores the AI/ML outputs for a single `form_analyses` row.

Relationship and cardinality:

- `form_analysis_results.session_id` → `form_analyses.session_id`
- Marked **`UNIQUE`** which makes it **one result per analysis session**.

Typical fields:

- scalar scores (`overall_score`, `depth_score`, `alignment_score`, `tempo_score`)
- structured findings (`issues` JSONB)
- structured coaching output (`coaching_output` JSONB)
- `progression_recommendation` enum-like constraint (`deload|maintain|progress|regress`)
- `annotated_frame_urls` (array of storage object paths)
- `model_version`

### `public.workout_plan_exercises`

Stores a user’s plan definition (what exercise, what day, sets/reps/weight targets, order, notes).

Relationship:

- `workout_plan_exercises.user_id` → `auth.users.id`
- `workout_plan_exercises.exercise_id` → `public.exercises.exercise_id`

### `public.workout_session_logs`

Records what the user actually performed on a date/time.

Optional links:

- `plan_exercise_id` can link a log back to a plan entry.
- `form_session_id` can link a log to a **form analysis session**:
  - `workout_session_logs.form_session_id` → `public.form_analyses.session_id`

This lets you attach analysis-backed technique outcomes to real training history.

---

## Row Level Security (RLS) behavior

The migration enables RLS on all domain tables:

- `public.user_profiles`
- `public.exercises`
- `public.form_analyses`
- `public.form_analysis_results`
- `public.workout_plan_exercises`
- `public.workout_session_logs`

Policies included:

- **`user_profiles`**
  - authenticated users can **view/update** only their own profile (`auth.uid() = user_id`).
- **`exercises`**
  - authenticated users can **read** active exercises (`is_active = true`).
  - (No write policy is included; intended to be admin/service-role managed.)
- **`form_analyses`**
  - authenticated users can **view/insert** only their own rows (`auth.uid() = user_id`).
- **`form_analysis_results`**
  - authenticated users can read results **only if** they own the linked `form_analyses` row (checked via an `EXISTS` subquery).
- **`workout_plan_exercises`** and **`workout_session_logs`**
  - authenticated users can **manage** (ALL) only their own rows.

Notes:

- There are intentionally **no UPDATE/DELETE policies** on `form_analyses` or `form_analysis_results` in this migration. If your app needs them (e.g., letting users delete uploads), add policies carefully.

---

## Supabase Storage setup

The migration attempts to create a **private** Storage bucket:

- bucket id/name: **`form-videos`**
- `public = false`

Storage RLS policies:

- **Insert**: users can upload only into a folder named with their user id (first path segment equals `auth.uid()`).
- **Select**: users can read only objects in their own folder.

Expected object key convention:

```
<user_id>/<anything-you-like>
```

Examples:

- `9f2...c1a/raw/session-123.mp4`
- `9f2...c1a/annotated/session-123/frame-0042.jpg`

---

## How to apply the schema

### Prerequisites

- Node.js installed (the lockfile indicates modern Node; Supabase CLI typically expects recent Node versions).
- A Supabase project (for remote) or Docker (for local Supabase).

Install dependencies:

```bash
npm install
```

### Run locally (Supabase CLI)

From the repo root:

```bash
npx supabase start
```

This boots a local Supabase stack and applies migrations.

To reset (drops + recreates local DB, then re-applies migrations):

```bash
npx supabase db reset
```

### Push to a remote Supabase project

Link to your project (one-time per repo/dir):

```bash
npx supabase link
```

Then push migrations:

```bash
npx supabase db push
```

---

## How the app is expected to use this schema

### Creating an analysis session

Typical app flow:

- Upload video to Storage under `<user_id>/...`
- Insert `public.form_analyses` row with:
  - `user_id = auth.uid()`
  - `exercise_id`
  - `video_url` = object path
  - optional training metadata (`weight_kg`, `reps`, `sets`, `video_duration_s`)

### Writing results

A backend job (often using the **service role**) would:

- process video
- compute scores and issues
- insert or upsert into `public.form_analysis_results` for the `session_id`
- update `public.form_analyses.status`

If you plan to write results from an authenticated client (not recommended), you must add strict insert/update policies to prevent tampering.

---

## Extending safely

Common additions you may want:

- **`updated_at`** columns + triggers on mutable tables.
- **Soft-delete** semantics (e.g. `deleted_at`) instead of DELETE policies.
- Separate tables for:
  - per-set workout logging,
  - exercise variations,
  - coaching program templates,
  - multiple analyses per session (remove `UNIQUE` on results if you want versioning).

When extending:

- Keep RLS enabled by default on new tables.
- Add indexes for your most common query patterns (especially user-scoped feeds).
- Be deliberate about what operations run as **service role** vs. user session.

---

## License

No license is currently specified in this repository. If you intend others to use or contribute, add a `LICENSE` file (e.g., MIT, Apache-2.0, or proprietary).

