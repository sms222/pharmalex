-- PharmaLex v2 · migration 2/4 · content: questions, lesson_notes, flashcards, law_texts
-- Every content table shares the verification columns and the same guard triggers.

-- ───────────────────────── shared guards ─────────────────────────
-- Rules (apply to every content table):
--  1. status='verified' can only be set by a lecturer/admin, who must be verified_by (set automatically).
--  2. Service role / import scripts (auth.uid() is null) can never create or set 'verified'.
--  3. Editing a verified row's content silently drops it back to 'needs_review'.
create function private.content_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  audit text[] := array['status','verified_by','verified_at','updated_at','created_at'];
begin
  if new.status = 'verified' then
    if tg_op = 'INSERT' or old.status is distinct from 'verified' then
      if (select auth.uid()) is null or not private.is_staff() then
        raise exception 'only a lecturer or admin can mark content verified';
      end if;
      new.verified_by := (select auth.uid());
      new.verified_at := now();
    elsif (to_jsonb(new) - audit) is distinct from (to_jsonb(old) - audit) then
      new.status := 'needs_review';          -- content changed after verification
      new.verified_by := null;
      new.verified_at := null;
    end if;
  else
    new.verified_by := null;
    new.verified_at := null;
  end if;
  return new;
end $$;

-- ───────────────────────── questions ─────────────────────────
create table public.questions (
  id            uuid primary key default gen_random_uuid(),
  act_code      text not null references public.acts (code),
  instrument    text,                    -- 'RPA 1951', 'Reg 2004', 'P(PS)R 1989' ... (split from legacy 'ROPA · s.17')
  section       text,                    -- 's.17', 'r.12', 'Appendix 4' (split from the same label)
  citation      text,                    -- full source citation; mandatory before verification
  stem          text not null,
  statements    jsonb check (statements is null or jsonb_typeof(statements) = 'array'),  -- i./ii./iii. items, letters stripped
  options       jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) = 4),  -- plain text, NO "A. " prefix
  correct_index smallint check (correct_index between 0 and 3),
  explanation   text,
  status        public.content_status not null default 'needs_review',
  verified_by   uuid references public.profiles (id) on delete set null,
  verified_at   timestamptz,
  school_id     uuid references public.schools (id) on delete set null,  -- null = shared bank
  legacy_ref    text unique,             -- e.g. 'ROPA_DATA[0]' → idempotent re-import
  import_flags  text[] not null default '{}',  -- e.g. {'hedged_explanation','no_matching_option'}
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- A verified question must be complete.
  constraint questions_verified_complete check (
    status <> 'verified' or (
      correct_index is not null and citation is not null and length(trim(citation)) > 0
      and section is not null and verified_by is not null and verified_at is not null
      and explanation is not null)
  )
);
create index questions_act_status_idx on public.questions (act_code, status);
create index questions_school_idx     on public.questions (school_id);
create trigger questions_guard before insert or update on public.questions
  for each row execute function private.content_guard();
create trigger questions_touch before update on public.questions
  for each row execute function private.touch_updated_at();

-- ───────────────────────── lesson_notes ─────────────────────────
-- Legacy shape: notes.act[] and notes.reg[] are sections of {title, items:[{t,d}]}; notes.warn[] are plain strings.
create type public.note_kind as enum ('act', 'reg', 'warn');
create table public.lesson_notes (
  id           uuid primary key default gen_random_uuid(),
  act_code     text not null references public.acts (code),
  kind         public.note_kind not null,
  title        text,                                   -- null for 'warn'
  items        jsonb not null default '[]' check (jsonb_typeof(items) = 'array'),  -- [{"t": term, "d": definition}]
  citation     text,
  sort_order   smallint not null default 0,
  status       public.content_status not null default 'needs_review',
  verified_by  uuid references public.profiles (id) on delete set null,
  verified_at  timestamptz,
  school_id    uuid references public.schools (id) on delete set null,
  legacy_ref   text unique,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint notes_verified_complete check (status <> 'verified' or (verified_by is not null and verified_at is not null))
);
create index lesson_notes_act_idx on public.lesson_notes (act_code, kind, sort_order);
create trigger lesson_notes_guard before insert or update on public.lesson_notes
  for each row execute function private.content_guard();
create trigger lesson_notes_touch before update on public.lesson_notes
  for each row execute function private.touch_updated_at();

-- ───────────────────────── flashcards ─────────────────────────
create table public.flashcards (
  id           uuid primary key default gen_random_uuid(),
  act_code     text not null references public.acts (code),
  question     text not null,
  answer       text not null,
  citation     text,                                   -- legacy 'ref'
  sort_order   smallint not null default 0,
  status       public.content_status not null default 'needs_review',
  verified_by  uuid references public.profiles (id) on delete set null,
  verified_at  timestamptz,
  school_id    uuid references public.schools (id) on delete set null,
  legacy_ref   text unique,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint flashcards_verified_complete check (status <> 'verified' or (citation is not null and verified_by is not null and verified_at is not null))
);
create index flashcards_act_idx on public.flashcards (act_code, sort_order);
create trigger flashcards_guard before insert or update on public.flashcards
  for each row execute function private.content_guard();
create trigger flashcards_touch before update on public.flashcards
  for each row execute function private.touch_updated_at();

-- ───────────────────────── law_texts ─────────────────────────
-- body_html: legacy markup uses <span class="lk|lh"> highlights. MUST be sanitised (allow-list) on write and render.
create table public.law_texts (
  id           uuid primary key default gen_random_uuid(),
  act_code     text not null references public.acts (code),
  section      text not null,                          -- legacy 'sec', e.g. 's.3(1)'
  title        text not null,
  body_html    text not null,
  sort_order   smallint not null default 0,
  status       public.content_status not null default 'needs_review',
  verified_by  uuid references public.profiles (id) on delete set null,
  verified_at  timestamptz,
  school_id    uuid references public.schools (id) on delete set null,
  legacy_ref   text unique,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint law_verified_complete check (status <> 'verified' or (verified_by is not null and verified_at is not null))
);
create index law_texts_act_idx on public.law_texts (act_code, sort_order);
create trigger law_texts_guard before insert or update on public.law_texts
  for each row execute function private.content_guard();
create trigger law_texts_touch before update on public.law_texts
  for each row execute function private.touch_updated_at();
