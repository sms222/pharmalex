-- PharmaLex v2 · migration 1/4 · core: enums, helper schema, schools, profiles, acts
-- NOT applied to any live project. Review first.

create type public.user_role      as enum ('student', 'lecturer', 'admin');
create type public.content_status as enum ('draft', 'needs_review', 'verified');
create type public.quiz_mode      as enum ('casual', 'sprint', 'act_mock', 'full_mock');

-- Helper functions live in a schema that PostgREST does not expose, so they cannot be called as RPC.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, anon;

-- Generic updated_at trigger
create function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

-- ───────────────────────── schools ─────────────────────────
create table public.schools (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code = upper(code)),   -- 'UKM', 'USM'
  name       text not null,
  created_at timestamptz not null default now()
);
insert into public.schools (code, name) values
  ('UKM', 'Universiti Kebangsaan Malaysia'),
  ('USM', 'Universiti Sains Malaysia');

-- ───────────────────────── profiles ─────────────────────────
-- One row per auth user. Email stays in auth.users only (PDPA: store the minimum).
create table public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  school_id           uuid references public.schools (id) on delete set null,   -- nullable by design
  role                public.user_role not null default 'student',
  nickname            text check (nickname ~ '^[A-Za-z0-9_.-]{3,20}$'),
  leaderboard_opt_in  boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index profiles_nickname_key on public.profiles (lower(nickname)) where nickname is not null;
create index profiles_school_idx on public.profiles (school_id);
create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

-- Role/school helpers used by RLS. SECURITY DEFINER avoids recursive RLS on profiles.
create function private.current_role() returns public.user_role
language sql stable security definer set search_path = '' as
$$ select role from public.profiles where id = (select auth.uid()) $$;

create function private.is_staff() returns boolean
language sql stable security definer set search_path = '' as
$$ select coalesce((select role in ('lecturer','admin') from public.profiles where id = (select auth.uid())), false) $$;

create function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as
$$ select coalesce((select role = 'admin' from public.profiles where id = (select auth.uid())), false) $$;

create function private.my_school() returns uuid
language sql stable security definer set search_path = '' as
$$ select school_id from public.profiles where id = (select auth.uid()) $$;

-- Can the caller see content/people belonging to this school? NULL school = shared by everyone.
create function private.school_visible(sid uuid) returns boolean
language sql stable security definer set search_path = '' as
$$ select sid is null or private.is_admin() or sid is not distinct from private.my_school() $$;

-- Is the target user in the caller's school (for lecturer analytics)? Admin sees all.
create function private.same_school(uid uuid) returns boolean
language sql stable security definer set search_path = '' as
$$ select private.is_admin()
       or (private.is_staff() and exists (
            select 1 from public.profiles p
            where p.id = uid and p.school_id is not null and p.school_id = private.my_school())) $$;

-- Create profile on signup. Everyone starts as student; promotion is an admin action.
create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- Block privilege escalation: only admins change role; school can be self-set once (when null).
create function private.profiles_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then return new; end if;            -- service role / migrations
  if not private.is_admin() then
    if new.role is distinct from old.role then
      raise exception 'only an admin can change role';
    end if;
    if new.school_id is distinct from old.school_id and old.school_id is not null then
      raise exception 'only an admin can change an assigned school';
    end if;
  end if;
  return new;
end $$;
create trigger profiles_guard before update on public.profiles
  for each row execute function private.profiles_guard();

-- ───────────────────────── acts (reference data) ─────────────────────────
-- exam_group collapses legacy buckets: SODA+CDCR is one bucket; ETHICS+GGM+DUNAS are one bucket.
create table public.acts (
  code        text primary key check (code = upper(code)),
  title       text not null,
  reg_title   text,
  exam_group  text,                      -- 'ROPA','POISON','SODA_CDCR','MASA','DDA','ETHICS'; null = not examinable (TIPS)
  exam_quota  smallint check (exam_quota >= 0),  -- per-group quota in a full mock; set on one row per group
  sort_order  smallint not null default 0
);
insert into public.acts (code, title, reg_title, exam_group, exam_quota, sort_order) values
  ('ROPA',   'Registration of Pharmacists Act 1951',        'Registration of Pharmacists Regulations 2004',            'ROPA',      20, 1),
  ('POISON', 'Poisons Act 1952',                            'Poisons & Psychotropic Regulations',                      'POISON',    35, 2),
  ('SODA',   'Sale of Drugs Act 1952',                      'Control of Drugs & Cosmetics Regulations 1984',           'SODA_CDCR', 15, 3),
  ('MASA',   'Medicines (Advertisement and Sale) Act 1956', 'Medicine Advertisements Board Regulations 1976',          'MASA',      10, 4),
  ('DDA',    'Dangerous Drugs Act 1952',                    'Dangerous Drugs Regulations 1952',                        'DDA',       10, 5),
  ('ETHICS', 'Code of Ethics for Pharmacists 2018',         'Guidance & Disciplinary Procedure (RPA 1951)',            'ETHICS',    10, 6),
  ('GGM',    'Good Governance in Medicine (GGM)',           'Framework, Code of Conduct & Vulnerable Areas',           'ETHICS',  null, 7),
  ('DUNAS',  'National Medicines Policy (DUNas) 4th Ed. 2022–2026','Five Components & Governance Structure',                  'ETHICS',  null, 8),
  ('TIPS',   'General Study Guidelines',                    'Study Strategies',                                        null,      null, 9);
