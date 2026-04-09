-- SkyBridge Compass: user_settings table for syncing app settings to Supabase.
-- Apply this in Supabase SQL editor.

create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  schema_version int not null default 1,
  settings_json jsonb not null,
  updated_at timestamptz not null default now()
);

-- Enable RLS
alter table public.user_settings enable row level security;

-- User can read own row
create policy "user_settings_select_own"
on public.user_settings
for select
to authenticated
using (auth.uid() = user_id);

-- User can insert own row
create policy "user_settings_insert_own"
on public.user_settings
for insert
to authenticated
with check (auth.uid() = user_id);

-- User can update own row
create policy "user_settings_update_own"
on public.user_settings
for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);


