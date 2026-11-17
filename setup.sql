-- =====================================================================
-- BeRightBack - database setup. Paste ALL of this into Supabase
-- (SQL Editor -> New query) and click Run. Safe to run more than once.
-- =====================================================================

-- ---------- TABLES ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null check (char_length(display_name) between 1 and 30),
  personal_message text not null default '' check (char_length(personal_message) <= 100),
  avatar text not null default '🙂' check (char_length(avatar) <= 8),
  status text not null default 'online' check (status in ('online','busy','away','invisible')),
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_email_lower on public.profiles (lower(email));

-- Music sharing: the song a person is currently listening to (empty = nothing)
alter table public.profiles add column if not exists now_playing text not null default '' check (char_length(now_playing) <= 120);

create table if not exists public.friendships (
  id bigint generated always as identity primary key,
  requester uuid not null references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','blocked')),
  blocked_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
create unique index if not exists friendships_pair
  on public.friendships (least(requester, addressee), greatest(requester, addressee));

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  sender uuid not null references public.profiles(id) on delete cascade,
  recipient uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  kind text not null default 'text' check (kind in ('text','nudge')),
  fmt text not null default '' check (fmt ~ '^b?i?(#[0-9a-fA-F]{6})?$'),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists messages_pair_idx on public.messages (sender, recipient, created_at desc);
create index if not exists messages_inbox_idx on public.messages (recipient, read_at);

-- ---------- HELPER FUNCTIONS ----------
create or replace function public.can_see_profile(p_other uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.friendships f
    where ((f.requester = auth.uid() and f.addressee = p_other)
        or (f.requester = p_other and f.addressee = auth.uid()))
      and (f.status in ('accepted','pending') or f.blocked_by = auth.uid())
  );
$$;

-- Stops people changing their own email/id (so nobody can pretend to be someone else)
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.email := coalesce((select email from auth.users where id = new.id), new.id::text);
  else
    new.email := old.email;
    new.id := old.id;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard_trg on public.profiles;
create trigger profiles_guard_trg before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- Creates a profile automatically when someone signs up
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, display_name)
  values (
    new.id,
    coalesce(new.email, new.id::text),
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
                  nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'User'), 30)
  )
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Anti-spam: max 15 messages per 10 seconds per person
create or replace function public.messages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.messages
      where sender = new.sender and created_at > now() - interval '10 seconds') >= 15 then
    raise exception 'rate_limited: slow down';
  end if;
  return new;
end $$;
drop trigger if exists messages_guard_trg on public.messages;
create trigger messages_guard_trg before insert on public.messages
  for each row execute function public.messages_guard();

-- ---------- CONTACT ACTIONS (the only way to change friendships) ----------
create or replace function public.send_friend_request(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_target uuid; v_row public.friendships;
begin
  if v_me is null then raise exception 'not signed in'; end if;
  if (select count(*) from public.friendships
      where requester = v_me and created_at > now() - interval '1 hour') >= 20 then
    return 'rate_limited';
  end if;
  select id into v_target from public.profiles where lower(email) = lower(trim(p_email));
  if v_target is null then return 'not_found'; end if;
  if v_target = v_me then return 'self'; end if;
  select * into v_row from public.friendships
   where (requester = v_me and addressee = v_target) or (requester = v_target and addressee = v_me);
  if found then
    if v_row.status = 'blocked' then return 'not_found'; end if;
    if v_row.status = 'pending' and v_row.addressee = v_me then
      update public.friendships set status = 'accepted' where id = v_row.id;
      return 'accepted';
    end if;
    return 'exists';
  end if;
  insert into public.friendships (requester, addressee) values (v_me, v_target);
  return 'sent';
end $$;

create or replace function public.respond_friend_request(p_requester uuid, p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'not signed in'; end if;
  if p_action = 'accept' then
    update public.friendships set status = 'accepted'
     where requester = p_requester and addressee = v_me and status = 'pending';
  elsif p_action = 'decline' then
    delete from public.friendships
     where requester = p_requester and addressee = v_me and status = 'pending';
  elsif p_action = 'block' then
    update public.friendships set status = 'blocked', blocked_by = v_me
     where requester = p_requester and addressee = v_me and status = 'pending';
  end if;
end $$;

create or replace function public.remove_friend(p_other uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.friendships
   where status in ('accepted','pending')
     and ((requester = auth.uid() and addressee = p_other) or (requester = p_other and addressee = auth.uid()));
$$;

create or replace function public.block_user(p_other uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null or p_other = v_me then return; end if;
  update public.friendships set status = 'blocked', blocked_by = v_me
   where (requester = v_me and addressee = p_other) or (requester = p_other and addressee = v_me);
  if not found then
    insert into public.friendships (requester, addressee, status, blocked_by)
    values (v_me, p_other, 'blocked', v_me);
  end if;
end $$;

create or replace function public.unblock_user(p_other uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.friendships where status = 'blocked' and blocked_by = auth.uid()
   and ((requester = auth.uid() and addressee = p_other) or (requester = p_other and addressee = auth.uid()));
$$;

create or replace function public.mark_read(p_from uuid) returns void
language sql security definer set search_path = public as $$
  update public.messages set read_at = now()
   where recipient = auth.uid() and sender = p_from and read_at is null;
$$;

-- Lets a person delete their own account and ALL their data (privacy / PDPA)
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ---------- SECURITY RULES (Row Level Security) ----------
alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.messages enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.can_see_profile(id));
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = auth.uid());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists friendships_select on public.friendships;
create policy friendships_select on public.friendships for select to authenticated
  using (requester = auth.uid() or addressee = auth.uid());

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (sender = auth.uid() or recipient = auth.uid());
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    sender = auth.uid()
    and exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and ((f.requester = messages.sender and f.addressee = messages.recipient)
          or (f.requester = messages.recipient and f.addressee = messages.sender))
    )
  );

-- ---------- PERMISSIONS (least privilege) ----------
revoke all on public.profiles, public.friendships, public.messages from anon;
revoke insert, update, delete on public.friendships from authenticated;
revoke update, delete on public.messages from authenticated;
revoke delete on public.profiles from authenticated;
revoke update, insert on public.profiles from authenticated;
grant update (display_name, personal_message, avatar, status, last_seen, now_playing) on public.profiles to authenticated;
grant insert (id, display_name) on public.profiles to authenticated;

revoke all on function public.send_friend_request(text), public.respond_friend_request(uuid, text),
  public.remove_friend(uuid), public.block_user(uuid), public.unblock_user(uuid),
  public.mark_read(uuid), public.delete_my_account(), public.can_see_profile(uuid)
  from public, anon;
grant execute on function public.send_friend_request(text), public.respond_friend_request(uuid, text),
  public.remove_friend(uuid), public.block_user(uuid), public.unblock_user(uuid),
  public.mark_read(uuid), public.delete_my_account(), public.can_see_profile(uuid)
  to authenticated;
revoke all on function public.profiles_guard(), public.handle_new_user(), public.messages_guard()
  from public, anon, authenticated;

-- ---------- LIVE UPDATES (Realtime) ----------
do $$
declare t text;
begin
  foreach t in array array['messages','profiles','friendships'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------- Create profiles for any accounts that already exist ----------
insert into public.profiles (id, email, display_name)
select id, coalesce(email, id::text), left(coalesce(nullif(split_part(coalesce(email, ''), '@', 1), ''), 'User'), 30)
from auth.users
on conflict (id) do nothing;

-- =====================================================================
-- VERSION 2 ADDITIONS: names with symbols, profile pictures, photos & videos
-- (safe to run more than once)
-- =====================================================================

-- Remove the old limits on name, picture and message type, then add the new ones
do $$
declare r record;
begin
  for r in
    select c.conname, c.conrelid::regclass as tbl
    from pg_constraint c
    where c.contype = 'c'
      and c.conrelid in ('public.profiles'::regclass, 'public.messages'::regclass)
      and pg_get_constraintdef(c.oid) ~ '(display_name|avatar|kind)'
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;
end $$;

alter table public.messages add column if not exists media_path text;

-- Names: 1-40 characters, symbols and emoji allowed; hidden/direction-changing characters are not
alter table public.profiles add constraint profiles_display_name_check
  check (char_length(display_name) between 1 and 40
         and display_name !~ E'[\\u0001-\\u001F\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069]');
-- Picture: an emoji, 'preset:1'..'preset:10', or 'img:<your id>/<file>'
alter table public.profiles add constraint profiles_avatar_check
  check (char_length(avatar) <= 200);
alter table public.messages add constraint messages_kind_check
  check (kind in ('text','nudge','image','video','wink','audio','game'));
-- A picture/video message must point at a file inside the SENDER'S OWN folder
alter table public.messages add constraint messages_media_chk
  check ((kind in ('image','video','audio')) = (media_path is not null)
         and (media_path is null
              or (left(media_path, 37) = sender::text || '/' and char_length(media_path) <= 200)));

-- ---------- File storage (profile pictures + chat photos/videos) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',    'avatars',    true,  2097152,  array['image/jpeg','image/png','image/webp']),
  ('chat-media', 'chat-media', false, 20971520, array['image/jpeg','image/png','image/gif','image/webp','video/mp4','video/webm','video/quicktime'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Profile pictures: each person can only add/change/remove files in their own folder
drop policy if exists brb_avatars_insert on storage.objects;
create policy brb_avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists brb_avatars_select on storage.objects;
create policy brb_avatars_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists brb_avatars_delete on storage.objects;
create policy brb_avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- Chat photos/videos (private): only the sender, and the person the message was sent to, can open a file
drop policy if exists brb_media_insert on storage.objects;
create policy brb_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists brb_media_select on storage.objects;
create policy brb_media_select on storage.objects for select to authenticated
  using (bucket_id = 'chat-media' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.messages m where m.media_path = name and m.recipient = auth.uid())
  ));
drop policy if exists brb_media_delete on storage.objects;
create policy brb_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'chat-media' and (storage.foldername(name))[1] = auth.uid()::text);


-- ===== VERSION 3: Winks =====
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check
  check (kind in ('text','nudge','image','video','wink','audio','game'));


-- ===== VERSION 4: voice clips =====
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check
  check (kind in ('text','nudge','image','video','wink','audio','game'));
alter table public.messages drop constraint if exists messages_media_chk;
alter table public.messages add constraint messages_media_chk
  check ((kind in ('image','video','audio')) = (media_path is not null)
         and (media_path is null
              or (left(media_path, 37) = sender::text || '/' and char_length(media_path) <= 200)));
update storage.buckets set allowed_mime_types = array['image/jpeg','image/png','image/gif','image/webp','video/mp4','video/webm','video/quicktime','audio/webm','audio/mp4','audio/ogg']
  where id = 'chat-media';

-- =====================================================================
-- VERSION 5 (PHASE 1): SAFETY AND PRIVACY
-- Friend codes (emails are no longer shown to anyone), anonymous mode,
-- who can add me, reports, admin tool, paused accounts, rotate my code.
-- Safe to run more than once. Run this whole block once.
-- =====================================================================

alter table public.profiles add column if not exists friend_code text;
alter table public.profiles add column if not exists anon boolean not null default false;
alter table public.profiles add column if not exists find_by_email boolean not null default false;
alter table public.profiles add column if not exists allow_requests boolean not null default true;
alter table public.profiles add column if not exists suspended boolean not null default false;

update public.profiles
   set friend_code = upper(substr(md5(random()::text || id::text || clock_timestamp()::text), 1, 8))
 where friend_code is null;
alter table public.profiles alter column friend_code
  set default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
alter table public.profiles alter column friend_code set not null;
create unique index if not exists profiles_friend_code_u on public.profiles (friend_code);

-- The "email" column now holds the friend code, so a real email address is never visible to anyone else.
-- (Real emails stay only in the private login system.)
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_priv boolean := coalesce(current_setting('brb.priv', true), '') = '1';
begin
  if tg_op = 'INSERT' then
    new.suspended := false;
    new.email := new.friend_code;
  else
    new.id := old.id;
    if v_priv then
      new.email := new.friend_code;
    else
      new.friend_code := old.friend_code;
      new.suspended := old.suspended;
      new.email := old.friend_code;
    end if;
  end if;
  if new.anon then new.now_playing := ''; end if;
  return new;
end $$;

alter table public.profiles disable trigger profiles_guard_trg;
update public.profiles set email = friend_code;
alter table public.profiles enable trigger profiles_guard_trg;

-- Add a contact by friend code (or by email only if that person switched "find me by email" on)
create or replace function public.send_friend_request(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_target uuid; v_row public.friendships; v_in text := trim(coalesce(p_email, ''));
begin
  if v_me is null then raise exception 'not signed in'; end if;
  if exists (select 1 from public.profiles where id = v_me and suspended) then return 'suspended'; end if;
  if (select count(*) from public.friendships
      where requester = v_me and created_at > now() - interval '1 hour') >= 20 then
    return 'rate_limited';
  end if;
  if position('@' in v_in) > 0 then
    select p.id into v_target from public.profiles p join auth.users u on u.id = p.id
     where lower(u.email) = lower(v_in) and p.find_by_email;
  else
    select id into v_target from public.profiles
     where friend_code = upper(regexp_replace(v_in, '[^A-Za-z0-9]', '', 'g'));
  end if;
  if v_target is null then return 'not_found'; end if;
  if v_target = v_me then return 'self'; end if;
  select * into v_row from public.friendships
   where (requester = v_me and addressee = v_target) or (requester = v_target and addressee = v_me);
  if found then
    if v_row.status = 'blocked' then return 'not_found'; end if;
    if v_row.status = 'pending' and v_row.addressee = v_me then
      update public.friendships set status = 'accepted' where id = v_row.id;
      return 'accepted';
    end if;
    return 'exists';
  end if;
  if exists (select 1 from public.profiles where id = v_target and (not allow_requests or suspended)) then
    return 'not_found';
  end if;
  insert into public.friendships (requester, addressee) values (v_me, v_target);
  return 'sent';
end $$;

-- A new private code (use this if your code was shared with someone you do not want)
create or replace function public.new_friend_code() returns text
language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
  perform set_config('brb.priv', '1', true);
  update public.profiles set friend_code = v_code where id = auth.uid();
  return v_code;
end $$;

-- ---------- REPORTS AND ADMIN ----------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
create table if not exists public.reports (
  id bigint generated always as identity primary key,
  reporter uuid references public.profiles(id) on delete set null,
  reported uuid references public.profiles(id) on delete set null,
  reporter_name text not null default '',
  reported_name text not null default '',
  reason text not null check (char_length(reason) <= 40),
  details text not null default '' check (char_length(details) <= 600),
  evidence text not null default '' check (char_length(evidence) <= 2000),
  status text not null default 'open' check (status in ('open','done')),
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
alter table public.reports enable row level security;
revoke all on public.admins, public.reports from anon, authenticated;

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.report_user(p_other uuid, p_reason text, p_details text, p_msg bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_ev text := ''; v_kind text; v_body text;
begin
  if v_me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.profiles where id = p_other) or p_other = v_me then return; end if;
  if (select count(*) from public.reports where reporter = v_me and created_at > now() - interval '1 day') >= 15 then
    raise exception 'rate_limited: too many reports today';
  end if;
  if p_msg is not null then
    select kind, body into v_kind, v_body from public.messages where id = p_msg and sender = p_other and recipient = v_me;
    if found then v_ev := case when v_kind = 'text' then v_body else '[' || v_kind || ' message]' end; end if;
  end if;
  insert into public.reports (reporter, reported, reporter_name, reported_name, reason, details, evidence)
  values (v_me, p_other,
          (select display_name from public.profiles where id = v_me),
          (select display_name from public.profiles where id = p_other),
          left(coalesce(p_reason, 'other'), 40), left(coalesce(p_details, ''), 600), left(v_ev, 2000));
end $$;

create or replace function public.contact_admin(p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if char_length(trim(coalesce(p_text, ''))) = 0 then return; end if;
  if (select count(*) from public.reports where reporter = auth.uid() and created_at > now() - interval '1 day') >= 15 then
    raise exception 'rate_limited: too many messages today';
  end if;
  insert into public.reports (reporter, reporter_name, reason, details)
  values (auth.uid(), (select display_name from public.profiles where id = auth.uid()), 'Message to admin', left(trim(p_text), 600));
end $$;

create or replace function public.admin_reports() returns table (
  id bigint, created_at timestamptz, reporter_name text, reported_id uuid, reported_name text,
  reason text, details text, evidence text, status text, reported_suspended boolean)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    select r.id, r.created_at, r.reporter_name, r.reported, r.reported_name, r.reason, r.details, r.evidence, r.status,
           coalesce((select p.suspended from public.profiles p where p.id = r.reported), false)
      from public.reports r
     order by (r.status = 'open') desc, r.created_at desc limit 200;
end $$;

create or replace function public.admin_resolve_report(p_id bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.reports set status = case when p_status = 'open' then 'open' else 'done' end where id = p_id;
end $$;

create or replace function public.admin_set_suspended(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if exists (select 1 from public.admins where user_id = p_user) then raise exception 'cannot pause an admin'; end if;
  perform set_config('brb.priv', '1', true);
  update public.profiles set suspended = p_on where id = p_user;
end $$;

-- Paused accounts cannot send messages
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    sender = auth.uid()
    and not exists (select 1 from public.profiles s where s.id = auth.uid() and s.suspended)
    and exists (
      select 1 from public.friendships f
      where f.status = 'accepted'
        and ((f.requester = messages.sender and f.addressee = messages.recipient)
          or (f.requester = messages.recipient and f.addressee = messages.sender))
    )
  );

-- Permissions
grant update (display_name, personal_message, avatar, status, last_seen, now_playing, anon, find_by_email, allow_requests)
  on public.profiles to authenticated;
revoke all on function public.new_friend_code(), public.is_admin(), public.report_user(uuid, text, text, bigint),
  public.contact_admin(text), public.admin_reports(), public.admin_resolve_report(bigint, text),
  public.admin_set_suspended(uuid, boolean) from public, anon;
grant execute on function public.new_friend_code(), public.is_admin(), public.report_user(uuid, text, text, bigint),
  public.contact_admin(text), public.admin_reports(), public.admin_resolve_report(bigint, text),
  public.admin_set_suspended(uuid, boolean) to authenticated;

-- =====================================================================
-- MAKE YOURSELF THE ADMIN (do this once, after the block above ran):
-- replace you@example.com with the email you sign in with, then run only this line:
--
-- insert into public.admins (user_id) select id from auth.users where lower(email) = lower('you@example.com') on conflict do nothing;
-- =====================================================================

-- =====================================================================
-- VERSION 6 (PHASE 2): MY STYLE (name effects, frames, about me) and
-- settings that follow your account to every device.
-- Safe to run more than once.
-- =====================================================================
alter table public.profiles add column if not exists name_style text not null default ''
  check (name_style ~ '^(#[0-9a-fA-F]{6})?(:[a-z]{3,10})?$');
alter table public.profiles add column if not exists frame text not null default ''
  check (frame in ('','gold','rainbow','hearts','stars','neon','flame','pixel'));
alter table public.profiles add column if not exists about text not null default ''
  check (char_length(about) <= 200);

create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  check (pg_column_size(data) <= 30000)
);
alter table public.user_settings enable row level security;
drop policy if exists user_settings_select on public.user_settings;
create policy user_settings_select on public.user_settings for select to authenticated using (user_id = auth.uid());
drop policy if exists user_settings_insert on public.user_settings;
create policy user_settings_insert on public.user_settings for insert to authenticated with check (user_id = auth.uid());
drop policy if exists user_settings_update on public.user_settings;
create policy user_settings_update on public.user_settings for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.user_settings from anon;
revoke delete on public.user_settings from authenticated;
grant select, insert, update on public.user_settings to authenticated;

grant update (display_name, personal_message, avatar, status, last_seen, now_playing, anon, find_by_email,
              allow_requests, name_style, frame, about) on public.profiles to authenticated;

-- =====================================================================
-- VERSION 7 (PHASE 3): ATTENTION FEATURES
-- Mood, birthday, streaks, "Look at me" broadcast, profile views,
-- secret admirer (opt-in), nudge limits.
-- Safe to run more than once.
-- =====================================================================
alter table public.profiles add column if not exists mood text not null default '' check (char_length(mood) <= 30);
alter table public.profiles add column if not exists birthday text not null default ''
  check (birthday ~ '^((0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]))?$');
alter table public.profiles add column if not exists views_on boolean not null default true;
alter table public.profiles add column if not exists allow_admirer boolean not null default false;
alter table public.profiles add column if not exists accept_broadcasts boolean not null default true;
alter table public.profiles add column if not exists last_broadcast timestamptz;

-- Rate limits: 15 messages / 10 s (not for a broadcast) and at most 10 nudges a minute to one person
create or replace function public.messages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('brb.bcast', true), '') <> '1' then
    if (select count(*) from public.messages
        where sender = new.sender and created_at > now() - interval '10 seconds') >= 15 then
      raise exception 'rate_limited: slow down';
    end if;
  end if;
  if new.kind = 'nudge' and (select count(*) from public.messages
        where sender = new.sender and recipient = new.recipient and kind = 'nudge'
          and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'rate_limited: too many nudges';
  end if;
  return new;
end $$;

-- Streaks: days in a row (Singapore time) when BOTH people sent something
create or replace function public.my_streaks() returns table (friend uuid, days int, last_day date)
language sql security definer stable set search_path = public as $$
  with d as (
    select case when m.sender = auth.uid() then m.recipient else m.sender end as f,
           (m.created_at at time zone 'Asia/Singapore')::date as dy,
           (m.sender = auth.uid()) as mine
      from public.messages m
     where (m.sender = auth.uid() or m.recipient = auth.uid())
       and m.created_at > now() - interval '150 days'
  ), both_days as (
    select f, dy from d group by f, dy having bool_or(mine) and bool_or(not mine)
  ), g as (
    select f, dy, dy - (row_number() over (partition by f order by dy))::int as grp from both_days
  ), runs as (
    select f, count(*)::int as n, max(dy) as ld from g group by f, grp
  )
  select f, n, ld from runs
   where ld >= (now() at time zone 'Asia/Singapore')::date - 1 and n >= 2;
$$;

-- "Look at me": one loud wink to every contact who is online and accepts them (max 50, once per 10 minutes)
create or replace function public.broadcast_look(p_wink text) returns int
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); n int := 0;
begin
  if v_me is null then raise exception 'not signed in'; end if;
  if p_wink !~ '^[A-Za-z0-9_-]{1,30}$' then raise exception 'bad wink'; end if;
  if exists (select 1 from public.profiles
              where id = v_me and (suspended or (last_broadcast is not null and last_broadcast > now() - interval '10 minutes'))) then
    raise exception 'rate_limited: wait 10 minutes between broadcasts';
  end if;
  perform set_config('brb.bcast', '1', true);
  insert into public.messages (sender, recipient, body, kind)
  select v_me, p.id, p_wink, 'wink'
    from public.profiles p
    join public.friendships f on f.status = 'accepted'
     and ((f.requester = v_me and f.addressee = p.id) or (f.requester = p.id and f.addressee = v_me))
   where p.accept_broadcasts and not p.suspended and p.status <> 'invisible'
     and p.last_seen > now() - interval '150 seconds'
   limit 50;
  get diagnostics n = row_count;
  update public.profiles set last_broadcast = now() where id = v_me;
  return n;
end $$;

-- Who looked at my profile (only between contacts; nothing is saved if either person switched it off or is anonymous)
create table if not exists public.profile_views (
  viewer uuid not null references public.profiles(id) on delete cascade,
  viewed uuid not null references public.profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (viewer, viewed)
);
alter table public.profile_views enable row level security;
revoke all on public.profile_views from anon, authenticated;

create or replace function public.log_profile_view(p_other uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_other = auth.uid() then return; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and views_on and not anon) then return; end if;
  if not exists (select 1 from public.friendships f where f.status = 'accepted'
       and ((f.requester = auth.uid() and f.addressee = p_other) or (f.requester = p_other and f.addressee = auth.uid()))) then return; end if;
  insert into public.profile_views (viewer, viewed, viewed_at) values (auth.uid(), p_other, now())
  on conflict (viewer, viewed) do update set viewed_at = now();
end $$;

create or replace function public.my_profile_views() returns table (viewer_id uuid, viewer_name text, seen_at timestamptz)
language sql security definer stable set search_path = public as $$
  select v.viewer, p.display_name, v.viewed_at
    from public.profile_views v join public.profiles p on p.id = v.viewer
   where v.viewed = auth.uid()
     and exists (select 1 from public.profiles me where me.id = auth.uid() and me.views_on)
     and v.viewed_at > now() - interval '30 days'
   order by v.viewed_at desc limit 50;
$$;

-- Secret admirer (opt-in): the sender stays hidden from the receiver; the admin can still act on reports
create table if not exists public.admirer_notes (
  id bigint generated always as identity primary key,
  from_user uuid not null references public.profiles(id) on delete cascade,
  to_user uuid not null references public.profiles(id) on delete cascade,
  wink text not null check (wink ~ '^[A-Za-z0-9_-]{1,30}$'),
  tries int not null default 0,
  guessed boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.admirer_notes enable row level security;
revoke all on public.admirer_notes from anon, authenticated;

create or replace function public.send_admirer(p_to uuid, p_wink text) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'not signed in'; end if;
  if exists (select 1 from public.profiles where id = v_me and suspended) then raise exception 'admirer_blocked'; end if;
  if not exists (select 1 from public.friendships f where f.status = 'accepted'
       and ((f.requester = v_me and f.addressee = p_to) or (f.requester = p_to and f.addressee = v_me))) then raise exception 'admirer_blocked'; end if;
  if not exists (select 1 from public.profiles where id = p_to and allow_admirer and not suspended) then raise exception 'admirer_blocked'; end if;
  if (select count(*) from public.admirer_notes where from_user = v_me and created_at > now() - interval '1 day') >= 3
     or exists (select 1 from public.admirer_notes where from_user = v_me and to_user = p_to and created_at > now() - interval '1 day') then
    raise exception 'admirer_blocked';
  end if;
  insert into public.admirer_notes (from_user, to_user, wink) values (v_me, p_to, left(p_wink, 30));
end $$;

create or replace function public.my_admirer_notes() returns table (note_id bigint, sent_at timestamptz, wink text, guessed boolean, tries int)
language sql security definer stable set search_path = public as $$
  select a.id, a.created_at, a.wink, a.guessed, a.tries from public.admirer_notes a
   where a.to_user = auth.uid() order by a.created_at desc limit 30;
$$;

create or replace function public.guess_admirer(p_note bigint, p_guess uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_row public.admirer_notes;
begin
  select * into v_row from public.admirer_notes where id = p_note and to_user = auth.uid();
  if not found or v_row.guessed or v_row.tries >= 3 then return false; end if;
  update public.admirer_notes set tries = tries + 1 where id = p_note;
  if v_row.from_user = p_guess then
    update public.admirer_notes set guessed = true where id = p_note;
    return true;
  end if;
  return false;
end $$;

create or replace function public.report_admirer(p_note bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_row public.admirer_notes;
begin
  select * into v_row from public.admirer_notes where id = p_note and to_user = auth.uid();
  if not found then return; end if;
  insert into public.reports (reporter, reported, reporter_name, reported_name, reason, details, evidence)
  values (auth.uid(), v_row.from_user,
          (select display_name from public.profiles where id = auth.uid()),
          (select display_name from public.profiles where id = v_row.from_user),
          'Secret admirer note', 'Reported by the receiver', '[secret admirer wink: ' || v_row.wink || ']');
end $$;

grant update (display_name, personal_message, avatar, status, last_seen, now_playing, anon, find_by_email,
              allow_requests, name_style, frame, about, mood, birthday, views_on, allow_admirer, accept_broadcasts)
  on public.profiles to authenticated;
revoke all on function public.my_streaks(), public.broadcast_look(text), public.log_profile_view(uuid),
  public.my_profile_views(), public.send_admirer(uuid, text), public.my_admirer_notes(),
  public.guess_admirer(bigint, uuid), public.report_admirer(bigint) from public, anon;
grant execute on function public.my_streaks(), public.broadcast_look(text), public.log_profile_view(uuid),
  public.my_profile_views(), public.send_admirer(uuid, text), public.my_admirer_notes(),
  public.guess_admirer(bigint, uuid), public.report_admirer(bigint) to authenticated;

-- =====================================================================
-- VERSION 8 (PHASE 4): GAMES LEADERBOARD and voice effects
-- Safe to run more than once.
-- =====================================================================
create table if not exists public.game_results (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  opponent uuid references public.profiles(id) on delete set null,
  game text not null check (game ~ '^[a-z0-9_]{1,20}$'),
  result text not null check (result in ('win','loss','draw')),
  played_at timestamptz not null default now()
);
create index if not exists game_results_user_idx on public.game_results (user_id, played_at desc);
alter table public.game_results enable row level security;
revoke all on public.game_results from anon, authenticated;

-- Each player records their own result (games are friendly, so results are trusted)
create or replace function public.record_game(p_other uuid, p_game text, p_result text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_result not in ('win','loss','draw') or p_game !~ '^[a-z0-9_]{1,20}$' then return; end if;
  if not exists (select 1 from public.friendships f where f.status = 'accepted'
       and ((f.requester = auth.uid() and f.addressee = p_other) or (f.requester = p_other and f.addressee = auth.uid()))) then return; end if;
  if (select count(*) from public.game_results where user_id = auth.uid() and played_at > now() - interval '1 day') >= 100 then return; end if;
  insert into public.game_results (user_id, opponent, game, result) values (auth.uid(), p_other, p_game, p_result);
end $$;

-- Me and my contacts: wins, losses and draws in the last 30 days
create or replace function public.game_leaderboard() returns table (uid uuid, nm text, w int, l int, d int)
language sql security definer stable set search_path = public as $$
  select p.id, p.display_name,
         (count(r.id) filter (where r.result = 'win'))::int,
         (count(r.id) filter (where r.result = 'loss'))::int,
         (count(r.id) filter (where r.result = 'draw'))::int
    from public.profiles p
    left join public.game_results r on r.user_id = p.id and r.played_at > now() - interval '30 days'
   where p.id = auth.uid()
      or exists (select 1 from public.friendships f where f.status = 'accepted'
                  and ((f.requester = auth.uid() and f.addressee = p.id) or (f.requester = p.id and f.addressee = auth.uid())))
   group by p.id, p.display_name
   order by 3 desc, 5 desc, 2;
$$;
revoke all on function public.record_game(uuid, text, text), public.game_leaderboard() from public, anon;
grant execute on function public.record_game(uuid, text, text), public.game_leaderboard() to authenticated;

-- Voice clips with effects are sent as WAV files
update storage.buckets
   set allowed_mime_types = array['image/jpeg','image/png','image/gif','image/webp','video/mp4','video/webm','video/quicktime',
                                  'audio/webm','audio/mp4','audio/ogg','audio/wav','audio/x-wav']
 where id = 'chat-media';


-- ===== VERSION 9: reliable games (moves travel as short-lived 'game' rows) =====
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check
  check (kind in ('text','nudge','image','video','wink','audio','game'));

create or replace function public.messages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'game' then
    -- game moves: tidy up this sender's old game rows, and allow a generous burst
    delete from public.messages where sender = new.sender and kind = 'game' and created_at < now() - interval '15 minutes';
    if (select count(*) from public.messages
        where sender = new.sender and kind = 'game' and created_at > now() - interval '10 seconds') >= 40 then
      raise exception 'rate_limited: slow down';
    end if;
    return new;
  end if;
  if coalesce(current_setting('brb.bcast', true), '') <> '1' then
    if (select count(*) from public.messages
        where sender = new.sender and kind <> 'game' and created_at > now() - interval '10 seconds') >= 15 then
      raise exception 'rate_limited: slow down';
    end if;
  end if;
  if new.kind = 'nudge' and (select count(*) from public.messages
        where sender = new.sender and recipient = new.recipient and kind = 'nudge'
          and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'rate_limited: too many nudges';
  end if;
  return new;
end $$;

-- Streaks must ignore game rows
create or replace function public.my_streaks() returns table (friend uuid, days int, last_day date)
language sql security definer stable set search_path = public as $$
  with d as (
    select case when m.sender = auth.uid() then m.recipient else m.sender end as f,
           (m.created_at at time zone 'Asia/Singapore')::date as dy,
           (m.sender = auth.uid()) as mine
      from public.messages m
     where (m.sender = auth.uid() or m.recipient = auth.uid())
       and m.kind <> 'game'
       and m.created_at > now() - interval '150 days'
  ), both_days as (
    select f, dy from d group by f, dy having bool_or(mine) and bool_or(not mine)
  ), g as (
    select f, dy, dy - (row_number() over (partition by f order by dy))::int as grp from both_days
  ), runs as (
    select f, count(*)::int as n, max(dy) as ld from g group by f, grp
  )
  select f, n, ld from runs
   where ld >= (now() at time zone 'Asia/Singapore')::date - 1 and n >= 2;
$$;


-- ===== VERSION 10: group chats ("rooms") + call server settings =====
create table if not exists public.app_config (key text primary key, value jsonb not null default '{}'::jsonb);
alter table public.app_config enable row level security;
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config for select to authenticated using (key in ('turn'));
insert into public.app_config (key, value) values ('turn', '{"urls":[],"username":"","credential":""}'::jsonb) on conflict (key) do nothing;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  owner uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.room_members (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create table if not exists public.room_messages (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  sender uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists room_messages_room_idx on public.room_messages (room_id, created_at);
alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.room_messages enable row level security;

create or replace function public.is_room_member(p_room uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.room_members where room_id = p_room and user_id = auth.uid());
$$;

drop policy if exists rooms_read on public.rooms;
create policy rooms_read on public.rooms for select to authenticated using (public.is_room_member(id));
drop policy if exists room_members_read on public.room_members;
create policy room_members_read on public.room_members for select to authenticated using (public.is_room_member(room_id));
drop policy if exists room_messages_read on public.room_messages;
create policy room_messages_read on public.room_messages for select to authenticated using (public.is_room_member(room_id));
drop policy if exists room_messages_send on public.room_messages;
create policy room_messages_send on public.room_messages for insert to authenticated
  with check (sender = auth.uid() and public.is_room_member(room_id)
              and not exists (select 1 from public.profiles where id = auth.uid() and suspended));

create or replace function public.room_messages_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.room_messages where sender = new.sender and created_at > now() - interval '10 seconds') >= 10 then
    raise exception 'rate_limited: slow down';
  end if;
  return new;
end $$;
drop trigger if exists room_messages_guard_trg on public.room_messages;
create trigger room_messages_guard_trg before insert on public.room_messages for each row execute function public.room_messages_guard();

create or replace function public.is_friend_of(p_a uuid, p_b uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.friendships f where f.status = 'accepted'
    and ((f.requester = p_a and f.addressee = p_b) or (f.requester = p_b and f.addressee = p_a)));
$$;

-- Create a room. Everyone you add must be your accepted contact. Maximum 10 people.
create or replace function public.create_room(p_name text, p_members uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id uuid; u uuid; n int := 0;
begin
  if v_me is null then raise exception 'not signed in'; end if;
  if exists (select 1 from public.profiles where id = v_me and suspended) then raise exception 'account paused'; end if;
  if char_length(trim(coalesce(p_name,''))) not between 1 and 40 then raise exception 'bad name'; end if;
  if (select count(*) from public.rooms where owner = v_me) >= 10 then raise exception 'You can own at most 10 group chats'; end if;
  insert into public.rooms (name, owner) values (trim(p_name), v_me) returning id into v_id;
  insert into public.room_members (room_id, user_id) values (v_id, v_me);
  foreach u in array coalesce(p_members, '{}'::uuid[]) loop
    if u <> v_me and public.is_friend_of(v_me, u) and n < 9
       and not exists (select 1 from public.room_members where room_id = v_id and user_id = u) then
      insert into public.room_members (room_id, user_id) values (v_id, u); n := n + 1;
    end if;
  end loop;
  return v_id;
end $$;

create or replace function public.add_room_member(p_room uuid, p_user uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if not public.is_room_member(p_room) then return 'no'; end if;
  if not public.is_friend_of(v_me, p_user) then return 'not_contact'; end if;
  if (select count(*) from public.room_members where room_id = p_room) >= 10 then return 'full'; end if;
  if exists (select 1 from public.friendships f join public.room_members m on (m.user_id = f.requester or m.user_id = f.addressee)
              where f.status = 'blocked' and m.room_id = p_room and (f.requester = p_user or f.addressee = p_user) and m.user_id <> p_user) then return 'blocked'; end if;
  insert into public.room_members (room_id, user_id) values (p_room, p_user) on conflict do nothing;
  return 'ok';
end $$;

create or replace function public.leave_room(p_room uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.room_members where room_id = p_room and user_id = auth.uid();
  if not exists (select 1 from public.room_members where room_id = p_room) then delete from public.rooms where id = p_room; end if;
end $$;

-- Only the person who made the room can remove someone
create or replace function public.remove_room_member(p_room uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.rooms where id = p_room and owner = auth.uid()) and p_user <> auth.uid() then
    delete from public.room_members where room_id = p_room and user_id = p_user;
  end if;
end $$;

-- Names of the people in a room (members only). Pictures and details stay private.
create or replace function public.room_people(p_room uuid) returns table (user_id uuid, display_name text, is_owner boolean)
language sql security definer stable set search_path = public as $$
  select m.user_id, p.display_name, (r.owner = m.user_id)
    from public.room_members m join public.profiles p on p.id = m.user_id join public.rooms r on r.id = m.room_id
   where m.room_id = p_room and public.is_room_member(p_room);
$$;

revoke all on function public.is_room_member(uuid), public.is_friend_of(uuid, uuid), public.create_room(text, uuid[]), public.add_room_member(uuid, uuid),
  public.leave_room(uuid), public.remove_room_member(uuid, uuid), public.room_people(uuid), public.room_messages_guard() from public, anon;
grant execute on function public.is_room_member(uuid), public.create_room(text, uuid[]), public.add_room_member(uuid, uuid),
  public.leave_room(uuid), public.remove_room_member(uuid, uuid), public.room_people(uuid) to authenticated;

do $$ declare t text; begin
  foreach t in array array['room_messages','room_members','rooms'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;


-- ===== VERSION 11: push notifications (messages reach people even when the app is closed) =====
create extension if not exists pg_net with schema extensions;

create table if not exists public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;   -- no policies: only the functions below and the server can touch it

create table if not exists public.private_config (key text primary key, value text not null);
alter table public.private_config enable row level security;       -- no policies: nobody can read it from the app

create or replace function public.save_push(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if char_length(p_endpoint) > 1000 or char_length(p_p256dh) > 200 or char_length(p_auth) > 100 then raise exception 'bad subscription'; end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $$;
create or replace function public.drop_push(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;
revoke all on function public.save_push(text, text, text), public.drop_push(text) from public, anon;
grant execute on function public.save_push(text, text, text), public.drop_push(text) to authenticated;

-- After every new message, ask the server function to send a push (never blocks the message if anything fails)
create or replace function public.push_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_url text; v_secret text; v_name text; v_body text;
begin
  if new.kind = 'game' then return new; end if;
  select value into v_url from public.private_config where key = 'push_url';
  select value into v_secret from public.private_config where key = 'push_secret';
  if v_url is null or v_secret is null then return new; end if;
  if not exists (select 1 from public.push_subscriptions where user_id = new.recipient) then return new; end if;
  select display_name into v_name from public.profiles where id = new.sender;
  v_body := case new.kind when 'text' then left(new.body, 80) when 'nudge' then 'sent you a nudge! 📳' when 'wink' then 'sent you a wink ✨'
                          when 'image' then 'sent you a picture 📷' when 'video' then 'sent you a video 🎬' when 'audio' then 'sent you a voice clip 🎙' else 'sent you a message' end;
  perform net.http_post(url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-brb-secret', v_secret),
    body := jsonb_build_object('recipient', new.recipient, 'title', coalesce(v_name, 'BeRightBack'), 'body', v_body, 'tag', 'm-' || new.sender, 'open', new.sender));
  return new;
exception when others then
  return new;
end $$;
revoke all on function public.push_notify() from public, anon, authenticated;
drop trigger if exists push_notify_trg on public.messages;
create trigger push_notify_trg after insert on public.messages for each row execute function public.push_notify();
