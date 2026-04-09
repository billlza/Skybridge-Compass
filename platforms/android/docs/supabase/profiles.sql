-- SkyBridge Compass: profiles table for username/avatar/nebula_id (macOS-like profile source).
-- Apply this in Supabase SQL editor.

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

-- Enable RLS
alter table public.profiles enable row level security;

-- Public read (optional). If you don't want profiles to be publicly readable, remove this policy.
-- For device discovery / UX parity, you may want read access for authenticated users only.
create policy "profiles_read"
on public.profiles
for select
to authenticated
using (true);

-- Users can upsert their own profile
create policy "profiles_insert_own"
on public.profiles
for insert
to authenticated
with check (auth.uid() = id);

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
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();


