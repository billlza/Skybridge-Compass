-- SkyBridge Compass: user profile projection tables for username/avatar/nebula_id.
-- Apply this in Supabase SQL editor.

-- Canonical cross-platform projection used first by iOS/macOS/Android for avatar,
-- and by Android for Nebula ID after auth metadata.
create table if not exists public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  custom_user_id text,
  nebula_id text,
  avatar_url text,
  updated_at timestamptz not null default now()
);

alter table public.user_profiles add column if not exists email text;
alter table public.user_profiles add column if not exists full_name text;
alter table public.user_profiles add column if not exists custom_user_id text;
alter table public.user_profiles add column if not exists nebula_id text;
alter table public.user_profiles add column if not exists avatar_url text;
alter table public.user_profiles add column if not exists updated_at timestamptz not null default now();

alter table public.user_profiles enable row level security;

drop policy if exists "user_profiles_read" on public.user_profiles;
create policy "user_profiles_read"
on public.user_profiles
for select
to authenticated
using (auth.uid() = id);

drop policy if exists "user_profiles_insert_own" on public.user_profiles;
create policy "user_profiles_insert_own"
on public.user_profiles
for insert
to authenticated
with check (auth.uid() = id);

drop policy if exists "user_profiles_update_own" on public.user_profiles;
create policy "user_profiles_update_own"
on public.user_profiles
for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

-- Legacy profile table kept for macOS/iOS compatibility and older rows.
create table if not exists public.profiles (
  -- Use auth.users.id as primary key (common Supabase convention)
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  display_name text,
  full_name text,
  -- Matches Pro release (`updateProfilesTable` uses phone_number)
  phone_number text,
  nebula_id text,
  avatar_url text,
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists full_name text;
alter table public.profiles add column if not exists phone_number text;
alter table public.profiles add column if not exists nebula_id text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

-- Enable RLS
alter table public.profiles enable row level security;

-- Keep profile projection self-readable only; the app reads the current user's
-- row by id and should not expose profile metadata across authenticated users.
drop policy if exists "profiles_read" on public.profiles;
create policy "profiles_read"
on public.profiles
for select
to authenticated
using (auth.uid() = id);

-- Users can upsert their own profile
drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
on public.profiles
for insert
to authenticated
with check (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

-- Optional: auto-create a profile row on signup
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, updated_at)
  values (new.id, now())
  on conflict (id) do update set updated_at = now();
  return new;
end;
$$ language plpgsql security definer set search_path = public, pg_temp;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();
