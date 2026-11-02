-- Our Plate Passport: database setup
-- Paste this whole file into Supabase > SQL Editor > New query, change the email on the last line, then press Run.
-- Safe to run more than once.

-- Who is in the group. Only these emails can create an account and see anything.
create table if not exists public.members (
  email      text primary key,
  is_admin   boolean not null default false,
  added_at   timestamptz not null default now()
);

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members m where lower(m.email) = lower(auth.jwt() ->> 'email'));
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members m where lower(m.email) = lower(auth.jwt() ->> 'email') and m.is_admin);
$$;

-- Is this account's email still on the members list? Removed members disappear from the group until added back.
create or replace function public.is_member_uid(uid uuid) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from auth.users u join public.members m on lower(m.email) = lower(u.email) where u.id = uid);
$$;

-- Each person's profile: the name friends see, their photo, and dishes saved to try.
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  nick        text not null default '',
  photo_path  text,
  saved       text[] not null default '{}',
  joined      date not null default current_date
);

-- Meals logged by the group.
create table if not exists public.meals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  dish        text,
  custom      text not null default '',
  country     text not null,
  date        date,
  place       text not null default '',
  caption     text not null default '',
  ratings     jsonb not null default '{}'::jsonb,
  rating      numeric not null default 0,
  price       jsonb,
  ratio       text not null default '4:3',
  photo_path  text,
  thumb_path  text,
  created_at  timestamptz not null default now()
);
create index if not exists meals_user_idx on public.meals (user_id);

-- Likes: one row per person per meal.
create table if not exists public.likes (
  meal_id     uuid not null references public.meals (id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (meal_id, user_id)
);

-- Row level security: everything is private to group members; people can only change their own things.
alter table public.members  enable row level security;
alter table public.profiles enable row level security;
alter table public.meals    enable row level security;
alter table public.likes    enable row level security;

drop policy if exists "members see the group"  on public.members;
drop policy if exists "admins add members"     on public.members;
drop policy if exists "admins remove members"  on public.members;
create policy "members see the group" on public.members for select using (public.is_member());
create policy "admins add members"    on public.members for insert with check (public.is_admin());
create policy "admins remove members" on public.members for delete using (public.is_admin() and lower(email) <> lower(auth.jwt() ->> 'email'));

drop policy if exists "members read profiles"  on public.profiles;
drop policy if exists "create own profile"     on public.profiles;
drop policy if exists "update own profile"     on public.profiles;
create policy "members read profiles" on public.profiles for select using (public.is_member() and public.is_member_uid(id));
create policy "create own profile"    on public.profiles for insert with check (id = auth.uid() and public.is_member());
create policy "update own profile"    on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "members read meals"     on public.meals;
drop policy if exists "log own meals"          on public.meals;
drop policy if exists "edit own meals"         on public.meals;
drop policy if exists "delete own meals"       on public.meals;
create policy "members read meals" on public.meals for select using (public.is_member() and public.is_member_uid(user_id));
create policy "log own meals"      on public.meals for insert with check (user_id = auth.uid() and public.is_member());
create policy "edit own meals"     on public.meals for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "delete own meals"   on public.meals for delete using (user_id = auth.uid());

drop policy if exists "members read likes"     on public.likes;
drop policy if exists "like as yourself"       on public.likes;
drop policy if exists "unlike your own"        on public.likes;
create policy "members read likes" on public.likes for select using (public.is_member() and public.is_member_uid(user_id));
create policy "like as yourself"   on public.likes for insert with check (user_id = auth.uid() and public.is_member());
create policy "unlike your own"    on public.likes for delete using (user_id = auth.uid());

-- Stop people outside the group from creating accounts at all.
create or replace function public.only_members_sign_up() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.members m where lower(m.email) = lower(new.email)) then
    raise exception 'This email has not been added to the group yet';
  end if;
  return new;
end;
$$;
drop trigger if exists only_members_sign_up on auth.users;
create trigger only_members_sign_up before insert on auth.users
  for each row execute function public.only_members_sign_up();

-- Live updates in the app when friends post, like or edit.
do $$
declare t text;
begin
  foreach t in array array['meals','likes','profiles','members'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Photo storage. Files are only readable by their (unguessable) address; only members can upload, into their own folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 5242880, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg'];

drop policy if exists "members upload to own folder" on storage.objects;
drop policy if exists "delete own photos"            on storage.objects;
drop policy if exists "see own photo files"          on storage.objects;
-- removing a file needs both select and delete on it
create policy "see own photo files" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "members upload to own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text and public.is_member());
create policy "delete own photos" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- Helper functions are only for the privacy rules above, not to be called from outside.
revoke execute on function public.only_members_sign_up() from public, anon, authenticated;
revoke execute on function public.is_member() from public, anon;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_member() to authenticated;
grant execute on function public.is_admin() to authenticated;
revoke execute on function public.is_member_uid(uuid) from public, anon;
grant execute on function public.is_member_uid(uuid) to authenticated;

-- You, as the group's first member and admin. Change this to the email you'll sign in with.
insert into public.members (email, is_admin) values (lower('YOUR-EMAIL@example.com'), true)
on conflict (email) do update set is_admin = true;
