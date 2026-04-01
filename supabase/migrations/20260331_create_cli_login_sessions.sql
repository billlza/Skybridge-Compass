create table if not exists public.cli_login_sessions (
    session_id uuid primary key,
    client_id text not null,
    code_challenge text not null,
    redirect_uri text not null,
    state text not null,
    status text not null check (status in ('pending', 'approved', 'cancelled', 'expired')),
    auth_code_hash text,
    auth_user_id uuid,
    encrypted_access_token text,
    encrypted_refresh_token text,
    user_identifier text,
    display_name text,
    approved_at timestamptz,
    consumed_at timestamptz,
    expires_at timestamptz not null,
    created_at timestamptz not null default now(),
    cli_metadata jsonb not null default '{}'::jsonb
);

create index if not exists cli_login_sessions_status_expires_idx
    on public.cli_login_sessions (status, expires_at desc);

create index if not exists cli_login_sessions_auth_user_idx
    on public.cli_login_sessions (auth_user_id)
    where auth_user_id is not null;
