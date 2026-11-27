-- Applied only through NStack's allocated app schema migration contract/search_path.
-- No public schema, grants, triggers, functions or app-specific server tables.
CREATE TABLE goals (
  workspace_id uuid NOT NULL, channel_id uuid NOT NULL, owner_npub text NOT NULL,
  id text PRIMARY KEY, revision bigint NOT NULL CHECK (revision > 0),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 120 AND length(btrim(name)) > 0),
  description text NOT NULL CHECK (length(description) BETWEEN 1 AND 2000 AND length(btrim(description)) > 0),
  start_date date, target_date date,
  status text NOT NULL CHECK (status IN ('active','completed','archived')),
  focus_rank text COLLATE "C", default_channel_id uuid,
  extensions text NOT NULL DEFAULT '{}', present_fields jsonb NOT NULL DEFAULT '[]',
  created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, updated_by_npub text NOT NULL,
  tombstoned_at timestamptz,
  UNIQUE (id, workspace_id, channel_id),
  UNIQUE (workspace_id, channel_id, owner_npub, id),
  CHECK (target_date IS NULL OR start_date IS NULL OR target_date >= start_date),
  CHECK (focus_rank IS NULL OR (focus_rank ~ '^[0-9A-Za-z]{1,64}$' AND right(focus_rank,1) <> '0')),
  CHECK (jsonb_typeof(extensions::jsonb) = 'object' AND jsonb_typeof(present_fields) = 'array')
);
CREATE INDEX goals_focus ON goals (workspace_id, channel_id, owner_npub, status, focus_rank, id);
CREATE INDEX goals_changes ON goals (workspace_id, updated_at, id);
CREATE TABLE goal_checkpoints (
  id text PRIMARY KEY,
  workspace_id uuid NOT NULL, channel_id uuid NOT NULL, owner_npub text NOT NULL, goal_id text NOT NULL,
  checkpoint_id text NOT NULL CHECK (checkpoint_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 120 AND length(btrim(title)) > 0),
  date date, description text CHECK (length(description) <= 500), reached boolean NOT NULL,
  position integer NOT NULL CHECK (position >= 0 AND position < 100), revision bigint NOT NULL CHECK (revision > 0),
  extensions text NOT NULL DEFAULT '{}', present_fields jsonb NOT NULL DEFAULT '[]',
  UNIQUE (workspace_id, goal_id, checkpoint_id),
  UNIQUE (workspace_id, goal_id, position) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (goal_id, workspace_id, channel_id) REFERENCES goals(id, workspace_id, channel_id),
  FOREIGN KEY (workspace_id, channel_id, owner_npub, goal_id) REFERENCES goals(workspace_id, channel_id, owner_npub, id),
  CHECK (jsonb_typeof(extensions::jsonb) = 'object' AND jsonb_typeof(present_fields) = 'array')
);
CREATE INDEX goal_checkpoints_order ON goal_checkpoints (workspace_id, goal_id, position, checkpoint_id);
CREATE TABLE goal_associations (
  id text PRIMARY KEY,
  workspace_id uuid NOT NULL, channel_id uuid NOT NULL, owner_npub text NOT NULL, goal_id text NOT NULL,
  lane text NOT NULL CHECK (lane IN ('link','pin')),
  kind text NOT NULL CHECK (kind IN ('chat','task','doc','file')), record_id uuid NOT NULL, target_channel_id uuid,
  position integer NOT NULL CHECK (position >= 0 AND position < 500), revision bigint NOT NULL CHECK (revision > 0),
  extensions text NOT NULL DEFAULT '{}', present_fields jsonb NOT NULL DEFAULT '[]',
  UNIQUE (workspace_id, goal_id, lane, kind, record_id),
  UNIQUE (workspace_id, goal_id, lane, position) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (goal_id, workspace_id, channel_id) REFERENCES goals(id, workspace_id, channel_id),
  FOREIGN KEY (workspace_id, channel_id, owner_npub, goal_id) REFERENCES goals(workspace_id, channel_id, owner_npub, id),
  CHECK (lane <> 'pin' OR (kind IN ('doc','file') AND position < 100)),
  CHECK (jsonb_typeof(extensions::jsonb) = 'object' AND jsonb_typeof(present_fields) = 'array')
);
CREATE INDEX goal_associations_order ON goal_associations (workspace_id, goal_id, lane, position, kind, record_id);
CREATE INDEX goal_associations_reverse ON goal_associations (workspace_id, kind, record_id, goal_id);
CREATE TABLE goal_imports (
  id text PRIMARY KEY,
  workspace_id uuid NOT NULL, channel_id uuid NOT NULL, owner_npub text NOT NULL, goal_id text NOT NULL,
  source_version_id uuid NOT NULL, source_file_revision bigint NOT NULL,
  source_sha256 text NOT NULL CHECK (source_sha256 ~ '^[0-9a-f]{64}$'), source_size_bytes integer NOT NULL CHECK (source_size_bytes BETWEEN 0 AND 262144),
  mapper_version text NOT NULL, mapper_sha256 text NOT NULL CHECK (mapper_sha256 ~ '^[0-9a-f]{64}$'),
  normalized_sha256 text NOT NULL CHECK (normalized_sha256 ~ '^[0-9a-f]{64}$'),
  imported_revision bigint NOT NULL CHECK (imported_revision > 0), imported_at timestamptz NOT NULL,
  revision bigint NOT NULL CHECK (revision > 0),
  UNIQUE (workspace_id, goal_id, source_version_id),
  FOREIGN KEY (workspace_id, channel_id, owner_npub, goal_id) REFERENCES goals(workspace_id, channel_id, owner_npub, id),
  FOREIGN KEY (goal_id, workspace_id, channel_id) REFERENCES goals(id, workspace_id, channel_id)
);
-- Immutable normalized recovery revisions, appended atomically with current rows.
CREATE TABLE goal_history (
  id text PRIMARY KEY,
  workspace_id uuid NOT NULL, channel_id uuid NOT NULL, owner_npub text NOT NULL, goal_id text NOT NULL,
  revision bigint NOT NULL CHECK (revision > 0), content_revision bigint NOT NULL CHECK (content_revision > 0), name text NOT NULL, description text NOT NULL,
  start_date date, target_date date, status text NOT NULL, focus_rank text COLLATE "C", default_channel_id uuid,
  extensions text NOT NULL, present_fields jsonb NOT NULL,
  updated_at timestamptz NOT NULL, updated_by_npub text NOT NULL, tombstoned_at timestamptz,
  UNIQUE (id, workspace_id, channel_id),
  FOREIGN KEY (goal_id, workspace_id, channel_id) REFERENCES goals(id, workspace_id, channel_id),
  UNIQUE (workspace_id, goal_id, content_revision),
  UNIQUE (workspace_id, channel_id, owner_npub, goal_id, content_revision)
);
CREATE TABLE goal_checkpoint_history (
  id text PRIMARY KEY,
  workspace_id uuid NOT NULL, channel_id uuid NOT NULL, owner_npub text NOT NULL, goal_id text NOT NULL, revision bigint NOT NULL, content_revision bigint NOT NULL,
  history_id text NOT NULL,
  FOREIGN KEY (history_id, workspace_id, channel_id) REFERENCES goal_history(id, workspace_id, channel_id),
  checkpoint_id text NOT NULL, title text NOT NULL, date date, description text, reached boolean NOT NULL, position integer NOT NULL,
  extensions text NOT NULL, present_fields jsonb NOT NULL,
  UNIQUE (workspace_id, goal_id, content_revision, checkpoint_id),
  FOREIGN KEY (workspace_id, channel_id, owner_npub, goal_id, content_revision) REFERENCES goal_history(workspace_id, channel_id, owner_npub, goal_id, content_revision)
);
CREATE TABLE goal_association_history (
  id text PRIMARY KEY,
  workspace_id uuid NOT NULL, channel_id uuid NOT NULL, owner_npub text NOT NULL, goal_id text NOT NULL, revision bigint NOT NULL, content_revision bigint NOT NULL,
  history_id text NOT NULL,
  FOREIGN KEY (history_id, workspace_id, channel_id) REFERENCES goal_history(id, workspace_id, channel_id),
  lane text NOT NULL, kind text NOT NULL, record_id uuid NOT NULL, target_channel_id uuid, position integer NOT NULL,
  extensions text NOT NULL, present_fields jsonb NOT NULL,
  UNIQUE (workspace_id, goal_id, content_revision, lane, kind, record_id),
  FOREIGN KEY (workspace_id, channel_id, owner_npub, goal_id, content_revision) REFERENCES goal_history(workspace_id, channel_id, owner_npub, goal_id, content_revision)
);
CREATE TABLE goals_authority (
  id text PRIMARY KEY, workspace_id uuid NOT NULL, channel_id uuid NOT NULL, revision bigint NOT NULL CHECK (revision > 0),
  owner_npub text NOT NULL, mode text NOT NULL CHECK (mode IN ('legacy','frozen','relational')),
  epoch bigint NOT NULL CHECK (epoch > 0), contract_version integer NOT NULL CHECK (contract_version = 1),
  schema_version text NOT NULL, mapper_sha256 text NOT NULL CHECK (mapper_sha256 ~ '^[0-9a-f]{64}$'),
  manifest_sha256 text NOT NULL CHECK (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  source_fence_revision bigint NOT NULL CHECK (source_fence_revision >= 0),
  updated_at timestamptz NOT NULL, updated_by_npub text NOT NULL,
  UNIQUE (workspace_id, channel_id)
);
CREATE INDEX goals_snapshot ON goals (workspace_id, channel_id, id COLLATE "C");
CREATE INDEX goal_checkpoints_snapshot ON goal_checkpoints (workspace_id, channel_id, id COLLATE "C");
CREATE INDEX goal_associations_snapshot ON goal_associations (workspace_id, channel_id, id COLLATE "C");
CREATE INDEX goal_imports_snapshot ON goal_imports (workspace_id, channel_id, id COLLATE "C");
CREATE INDEX goal_history_snapshot ON goal_history (workspace_id, channel_id, id COLLATE "C");
CREATE INDEX goal_checkpoint_history_snapshot ON goal_checkpoint_history (workspace_id, channel_id, id COLLATE "C");
CREATE INDEX goal_association_history_snapshot ON goal_association_history (workspace_id, channel_id, id COLLATE "C");
CREATE INDEX goals_authority_snapshot ON goals_authority (workspace_id, channel_id, id COLLATE "C");
