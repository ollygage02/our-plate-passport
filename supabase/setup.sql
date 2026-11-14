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

-- ---------- Notifications ----------
-- Which kinds of notification each person wants.
alter table public.profiles add column if not exists notify jsonb not null default '{"meals":true,"likes":true,"done":true}'::jsonb;

-- One row per phone/browser that has turned notifications on.
create table if not exists public.push_subscriptions (
  endpoint    text primary key,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists push_subs_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists "see own devices"    on public.push_subscriptions;
drop policy if exists "add own device"     on public.push_subscriptions;
drop policy if exists "update own device"  on public.push_subscriptions;
drop policy if exists "remove own device"  on public.push_subscriptions;
create policy "see own devices"   on public.push_subscriptions for select using (user_id = auth.uid());
create policy "add own device"    on public.push_subscriptions for insert with check (user_id = auth.uid() and public.is_member());
create policy "update own device" on public.push_subscriptions for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "remove own device" on public.push_subscriptions for delete using (user_id = auth.uid());

-- Private sending keys: no policies, so only the server-side sender (supabase/functions/notify) can read this.
-- Fill it with a freshly generated VAPID key pair; put the public half in config.js as vapidPublicKey.
create table if not exists public.push_config (
  id            int primary key default 1 check (id = 1),
  vapid_public  text not null,
  vapid_private text not null,
  subject       text not null
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;
-- ---------- Groups ----------
-- People belong to one or more named groups (Family, Friends...). You see the meals and
-- profiles of everyone you share at least one group with. Anyone in a group can start a new one.

create table if not exists public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 1 and 40),
  created_by  uuid default auth.uid() references auth.users (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id  uuid not null references public.groups (id) on delete cascade,
  email     text not null check (email = lower(btrim(email))),
  role      text not null default 'member' check (role in ('admin','member')),
  added_at  timestamptz not null default now(),
  primary key (group_id, email)
);
create index if not exists group_members_email_idx on public.group_members (email);

-- profiles carry the account email so the app can tell who is in which group
alter table public.profiles add column if not exists email text;
create or replace function public.profile_email() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  new.email := (select lower(u.email) from auth.users u where u.id = new.id);
  return new;
end;
$$;
drop trigger if exists profile_email on public.profiles;
create trigger profile_email before insert or update on public.profiles
  for each row execute function public.profile_email();
update public.profiles p set email = lower(u.email) from auth.users u where u.id = p.id;

-- helpers used by the privacy rules
create or replace function public.my_email() returns text
language sql stable set search_path = public, auth as $$ select lower(auth.jwt() ->> 'email'); $$;

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members gm where gm.email = public.my_email());
$$;

create or replace function public.is_in_group(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members gm where gm.group_id = gid and gm.email = public.my_email());
$$;

create or replace function public.is_group_admin(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members gm where gm.group_id = gid and gm.email = public.my_email() and gm.role = 'admin');
$$;

create or replace function public.shares_group(uid uuid) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.group_members mine
    join public.group_members theirs on theirs.group_id = mine.group_id
    join auth.users u on lower(u.email) = theirs.email
    where mine.email = public.my_email() and u.id = uid);
$$;

-- whoever creates a group is its first admin
create or replace function public.group_creator_joins() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_email() is not null then
    insert into public.group_members (group_id, email, role) values (new.id, public.my_email(), 'admin')
    on conflict do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists group_creator_joins on public.groups;
create trigger group_creator_joins after insert on public.groups
  for each row execute function public.group_creator_joins();

-- privacy rules for groups
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
drop policy if exists "see your groups"      on public.groups;
drop policy if exists "start a group"        on public.groups;
drop policy if exists "admins rename"        on public.groups;
drop policy if exists "admins delete"        on public.groups;
create policy "see your groups" on public.groups for select using (public.is_in_group(id));
create policy "start a group"   on public.groups for insert with check (public.is_member() and created_by = auth.uid());
create policy "admins rename"   on public.groups for update using (public.is_group_admin(id)) with check (public.is_group_admin(id));
create policy "admins delete"   on public.groups for delete using (public.is_group_admin(id));

drop policy if exists "see group members"    on public.group_members;
drop policy if exists "admins add people"    on public.group_members;
drop policy if exists "admins remove, members leave" on public.group_members;
create policy "see group members" on public.group_members for select using (public.is_in_group(group_id));
create policy "admins add people" on public.group_members for insert with check (public.is_group_admin(group_id) and role = 'member');
create policy "admins remove, members leave" on public.group_members for delete using (
  (public.is_group_admin(group_id) and email <> public.my_email())
  or (email = public.my_email() and role = 'member'));

-- you see profiles, meals and likes of people you share a group with
drop policy if exists "members read profiles" on public.profiles;
drop policy if exists "members read meals"    on public.meals;
drop policy if exists "members read likes"    on public.likes;
create policy "members read profiles" on public.profiles for select using (public.shares_group(id));
create policy "members read meals"    on public.meals    for select using (public.shares_group(user_id));
create policy "members read likes"    on public.likes    for select using (exists (select 1 from public.meals m where m.id = likes.meal_id));

-- only people invited to some group can create an account
create or replace function public.only_members_sign_up() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.group_members gm where gm.email = lower(new.email)) then
    raise exception 'This email has not been added to a group yet';
  end if;
  return new;
end;
$$;

-- helpers are for the rules above, not to be called from outside
revoke execute on function public.profile_email() from public, anon, authenticated;
revoke execute on function public.group_creator_joins() from public, anon, authenticated;
revoke execute on function public.is_in_group(uuid) from public, anon;
revoke execute on function public.is_group_admin(uuid) from public, anon;
revoke execute on function public.shares_group(uuid) from public, anon;
grant execute on function public.is_in_group(uuid) to authenticated;
grant execute on function public.is_group_admin(uuid) to authenticated;
grant execute on function public.shares_group(uuid) to authenticated;

-- live updates
do $$
declare t text;
begin
  foreach t in array array['groups','group_members'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
-- move the existing members list into a first group called "Friends"
insert into public.groups (id, name, created_by)
select '00000000-0000-4000-8000-000000000001'::uuid, 'Friends', (select u.id from auth.users u join public.members m on lower(m.email) = lower(u.email) where m.is_admin limit 1)
where not exists (select 1 from public.groups);
insert into public.group_members (group_id, email, role)
select '00000000-0000-4000-8000-000000000001'::uuid, lower(m.email), case when m.is_admin then 'admin' else 'member' end
from public.members m
where exists (select 1 from public.groups g where g.id = '00000000-0000-4000-8000-000000000001'::uuid)
on conflict do nothing;

-- Admins can make other members admins (or back to members). An admin can leave once someone else is admin.
create or replace function public.has_other_admin(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members gm where gm.group_id = gid and gm.role = 'admin' and gm.email <> public.my_email());
$$;
revoke execute on function public.has_other_admin(uuid) from public, anon;
grant execute on function public.has_other_admin(uuid) to authenticated;
drop policy if exists "admins change roles" on public.group_members;
create policy "admins change roles" on public.group_members for update
  using (public.is_group_admin(group_id) and email <> public.my_email())
  with check (public.is_group_admin(group_id) and email <> public.my_email());
drop policy if exists "admins remove, members leave" on public.group_members;
create policy "admins remove, members leave" on public.group_members for delete using (
  (public.is_group_admin(group_id) and email <> public.my_email())
  or (email = public.my_email() and (role = 'member' or public.has_other_admin(group_id))));

-- ---------- Several photos per meal (carousel) ----------
-- Photo 1 stays in photo_path / thumb_path; photos 2 to 10 go here, in order: [{"photo_path":..., "thumb_path":...}]
alter table public.meals add column if not exists extra_photos jsonb not null default '[]'::jsonb;
alter table public.meals drop constraint if exists meals_extra_photos_max;
alter table public.meals add constraint meals_extra_photos_max check (jsonb_typeof(extra_photos) = 'array' and jsonb_array_length(extra_photos) <= 9);
