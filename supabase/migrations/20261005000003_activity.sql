-- PharmaLex v2 · migration 3/4 · activity: stats, attempts, exams, exam attempts, error reports, leaderboard, analytics
-- Principle: students cannot write scores. Correctness, XP, hearts and exam scores are computed in the database.

-- ───────────────────────── user_stats (xp / streak / hearts) ─────────────────────────
create table public.user_stats (
  user_id          uuid primary key references public.profiles (id) on delete cascade,
  xp               integer  not null default 0 check (xp >= 0),
  streak_days      integer  not null default 0,
  last_active_date date,
  hearts           smallint not null default 5 check (hearts between 0 and 5),
  heart_refill_at  timestamptz
);
create function private.create_user_stats() returns trigger
language plpgsql security definer set search_path = '' as $$
begin insert into public.user_stats (user_id) values (new.id); return new; end $$;
create trigger profiles_create_stats after insert on public.profiles
  for each row execute function private.create_user_stats();

-- ───────────────────────── attempts (one row per answered/skipped question) ─────────────────────────
create table public.attempts (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete cascade,  -- cascade = PDPA erasure
  session_id     uuid not null,                       -- groups one quiz run (client-generated) or an exam_attempt id
  question_id    uuid not null references public.questions (id) on delete cascade,
  act_code       text not null references public.acts (code),   -- filled by trigger
  mode           public.quiz_mode not null,
  selected_index smallint check (selected_index between 0 and 3),   -- null = skipped
  is_correct     boolean,                                           -- filled by trigger; null = skipped
  time_ms        integer check (time_ms >= 0),
  created_at     timestamptz not null default now(),
  unique (user_id, session_id, question_id)
);
create index attempts_user_idx     on public.attempts (user_id, created_at desc);
create index attempts_question_idx on public.attempts (question_id);
create index attempts_act_idx      on public.attempts (act_code);

create function private.attempts_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare q record; s record;
begin
  select id, act_code, correct_index, status into q from public.questions where id = new.question_id;
  -- Students may only answer verified questions (or ones drawn into their own exam attempt).
  if q.status <> 'verified' and not private.is_staff() and not exists (
       select 1 from public.exam_attempts ea
       where ea.id = new.session_id and ea.user_id = new.user_id and new.question_id = any (ea.question_ids)) then
    raise exception 'question not available';
  end if;
  new.act_code   := q.act_code;
  new.is_correct := case when new.selected_index is null or q.correct_index is null then null
                         else new.selected_index = q.correct_index end;
  if new.mode = 'casual' then
    select * into s from public.user_stats where user_id = new.user_id;
    if s.hearts = 0 and s.heart_refill_at > now() then raise exception 'no hearts left'; end if;
  end if;
  return new;
end $$;
create trigger attempts_before_insert before insert on public.attempts
  for each row execute function private.attempts_before_insert();

create function private.attempts_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  s record;
  today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  h smallint; refill timestamptz; streak int;
begin
  select * into s from public.user_stats where user_id = new.user_id for update;
  h := s.hearts; refill := s.heart_refill_at;
  if refill is not null and refill <= now() then h := 5; refill := null; end if;   -- refilled
  if new.mode = 'casual' and new.is_correct = false then
    h := greatest(h - 1, 0);
    if h = 0 and refill is null then refill := now() + interval '30 minutes'; end if;
  end if;
  streak := case when s.last_active_date = today then s.streak_days
                 when s.last_active_date = today - 1 then s.streak_days + 1
                 else 1 end;
  update public.user_stats set
    xp = xp + case when new.mode = 'casual' and new.is_correct then 10 else 0 end,   -- legacy rule: casual only
    hearts = h, heart_refill_at = refill, streak_days = streak, last_active_date = today
  where user_id = new.user_id;
  return new;
end $$;
create trigger attempts_after_insert after insert on public.attempts
  for each row execute function private.attempts_after_insert();

-- ───────────────────────── exams (lecturer-defined) ─────────────────────────
create table public.exams (
  id               uuid primary key default gen_random_uuid(),
  title            text not null,
  description      text,
  school_id        uuid references public.schools (id) on delete set null,   -- null = shared
  duration_minutes integer not null default 180 check (duration_minutes > 0),
  negative_mark    numeric(3,2) not null default 0.25 check (negative_mark >= 0),
  -- null = fixed list in exam_questions; else random draw, e.g. [{"act_group":"POISON","count":35}, ...]
  blueprint        jsonb check (blueprint is null or jsonb_typeof(blueprint) = 'array'),
  is_published     boolean not null default false,
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create trigger exams_touch before update on public.exams
  for each row execute function private.touch_updated_at();

create table public.exam_questions (
  exam_id     uuid not null references public.exams (id) on delete cascade,
  question_id uuid not null references public.questions (id) on delete restrict,
  position    smallint not null,
  primary key (exam_id, question_id)
);
create index exam_questions_pos_idx on public.exam_questions (exam_id, position);

-- A published fixed exam may contain only verified questions.
create function private.exam_publish_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare eid uuid; ex record;
begin
  if tg_table_name = 'exams' then eid := new.id; else eid := new.exam_id; end if;
  select * into ex from public.exams where id = eid;
  if ex.is_published and ex.blueprint is null and exists (
       select 1 from public.exam_questions eq join public.questions q on q.id = eq.question_id
       where eq.exam_id = eid and q.status <> 'verified') then
    raise exception 'a published exam may only contain verified questions';
  end if;
  return new;
end $$;
create constraint trigger exams_publish_guard after insert or update on public.exams
  deferrable initially deferred for each row execute function private.exam_publish_guard();
create constraint trigger exam_questions_publish_guard after insert or update on public.exam_questions
  deferrable initially deferred for each row execute function private.exam_publish_guard();

-- ───────────────────────── exam_attempts (server-drawn, server-graded) ─────────────────────────
create table public.exam_attempts (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete cascade,
  exam_id        uuid references public.exams (id) on delete set null,   -- null = self-generated practice mock
  mode           public.quiz_mode not null check (mode in ('act_mock', 'full_mock')),
  question_ids   uuid[] not null,                -- snapshot of the drawn questions
  started_at     timestamptz not null default now(),
  expires_at     timestamptz not null,
  submitted_at   timestamptz,
  submitted_late boolean,
  answers        jsonb,                          -- {question_id: selected_index | null}
  correct        integer,
  wrong          integer,
  skipped        integer,
  score          numeric(6,2),
  max_score      integer
);
create index exam_attempts_user_idx on public.exam_attempts (user_id, started_at desc);
create index exam_attempts_exam_idx on public.exam_attempts (exam_id);

-- Start an attempt: the server draws verified questions and sets the deadline.
-- p_exam_id: lecturer exam. Otherwise p_group null = full mock (acts.exam_quota per group, ~100 Qs);
-- p_group set = single-group simulator (all verified Qs of that group, optionally capped by p_count).
create function public.start_exam_attempt(p_exam_id uuid default null, p_group text default null, p_count integer default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  ex record; ids uuid[] := '{}'; part uuid[]; b jsonb; minutes integer; new_id uuid;
  m public.quiz_mode := case when p_group is null then 'full_mock' else 'act_mock' end;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if p_exam_id is not null then
    select * into ex from public.exams where id = p_exam_id and is_published and private.school_visible(school_id);
    if not found then raise exception 'exam not available'; end if;
    minutes := ex.duration_minutes;
    if ex.blueprint is null then
      select coalesce(array_agg(eq.question_id order by eq.position), '{}') into ids
        from public.exam_questions eq join public.questions q on q.id = eq.question_id
        where eq.exam_id = p_exam_id and q.status = 'verified';
    else
      for b in select * from jsonb_array_elements(ex.blueprint) loop
        select coalesce(array_agg(id), '{}') into part from (
          select q.id from public.questions q join public.acts a on a.code = q.act_code
          where q.status = 'verified' and private.school_visible(q.school_id) and a.exam_group = b->>'act_group'
          order by random() limit (b->>'count')::int) d;
        ids := ids || part;
      end loop;
    end if;
    m := 'full_mock';
  elsif p_group is null then
    for b in select to_jsonb(g) from (select exam_group, exam_quota from public.acts where exam_quota is not null) g loop
      select coalesce(array_agg(id), '{}') into part from (
        select q.id from public.questions q join public.acts a on a.code = q.act_code
        where q.status = 'verified' and private.school_visible(q.school_id) and a.exam_group = b->>'exam_group'
        order by random() limit (b->>'exam_quota')::int) d;
      ids := ids || part;
    end loop;
  else
    select coalesce(array_agg(id), '{}') into ids from (
      select q.id from public.questions q join public.acts a on a.code = q.act_code
      where q.status = 'verified' and private.school_visible(q.school_id) and a.exam_group = upper(p_group)
      order by random() limit coalesce(p_count, 1000)) d;
  end if;
  if coalesce(array_length(ids, 1), 0) = 0 then raise exception 'no verified questions available'; end if;
  minutes := coalesce(minutes, ceil(array_length(ids, 1) * 1.8)::int);   -- legacy: 1.8 min per question
  insert into public.exam_attempts (user_id, exam_id, mode, question_ids, expires_at, max_score)
    values (uid, p_exam_id, m, ids, now() + make_interval(mins => minutes), array_length(ids, 1))
    returning id into new_id;
  return new_id;
end $$;

-- Submit: grades in SQL. +1 correct, -negative_mark wrong, 0 unanswered. Also logs per-question attempts.
create function public.submit_exam_attempt(p_attempt_id uuid, p_answers jsonb)
returns public.exam_attempts language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  ea public.exam_attempts; neg numeric := 0.25; c int := 0; w int := 0; sk int := 0; qid uuid; sel smallint; key smallint;
begin
  select * into ea from public.exam_attempts where id = p_attempt_id and user_id = uid for update;
  if not found then raise exception 'attempt not found'; end if;
  if ea.submitted_at is not null then raise exception 'already submitted'; end if;
  if ea.exam_id is not null then select negative_mark into neg from public.exams where id = ea.exam_id; end if;
  foreach qid in array ea.question_ids loop
    sel := nullif(p_answers ->> qid::text, '')::smallint;
    select correct_index into key from public.questions where id = qid;
    if sel is null then sk := sk + 1; elsif sel = key then c := c + 1; else w := w + 1; end if;
    insert into public.attempts (user_id, session_id, question_id, mode, selected_index)
      values (uid, ea.id, qid, ea.mode, sel);
  end loop;
  update public.exam_attempts set
    submitted_at = now(), submitted_late = now() > expires_at + interval '60 seconds',
    answers = p_answers, correct = c, wrong = w, skipped = sk, score = c - w * neg
  where id = ea.id returning * into ea;
  return ea;
end $$;

-- ───────────────────────── error reports ─────────────────────────
create type public.report_category as enum ('wrong_answer', 'wrong_citation', 'outdated_law', 'typo', 'unclear', 'other');
create type public.report_status   as enum ('open', 'triaged', 'resolved', 'rejected');

create table public.error_reports (
  id              uuid primary key default gen_random_uuid(),
  reporter_id     uuid not null references public.profiles (id) on delete cascade,
  question_id     uuid references public.questions (id) on delete cascade,
  flashcard_id    uuid references public.flashcards (id) on delete cascade,
  law_text_id     uuid references public.law_texts (id) on delete cascade,
  note_id         uuid references public.lesson_notes (id) on delete cascade,
  category        public.report_category not null default 'other',
  message         text not null check (length(message) between 5 and 2000),
  status          public.report_status not null default 'open',
  resolved_by     uuid references public.profiles (id) on delete set null,
  resolved_at     timestamptz,
  resolution_note text,
  created_at      timestamptz not null default now(),
  constraint error_reports_one_target check (num_nonnulls(question_id, flashcard_id, law_text_id, note_id) = 1)
);
create index error_reports_status_idx   on public.error_reports (status, created_at desc);
create index error_reports_question_idx on public.error_reports (question_id);

-- Students can only create 'open' reports; staff move them along.
create function private.error_reports_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status and new.status in ('resolved', 'rejected') then
    new.resolved_by := (select auth.uid()); new.resolved_at := now();
  end if;
  return new;
end $$;
create trigger error_reports_guard before update on public.error_reports
  for each row execute function private.error_reports_guard();

-- ───────────────────────── leaderboard (nickname only, opt-in) ─────────────────────────
create function public.get_leaderboard(p_school_id uuid default null, p_limit integer default 50)
returns table (rank bigint, nickname text, school_code text, xp integer, streak_days integer)
language sql stable security definer set search_path = '' as $$
  select row_number() over (order by s.xp desc, p.nickname), p.nickname, sc.code, s.xp, s.streak_days
  from public.profiles p
  join public.user_stats s on s.user_id = p.id
  left join public.schools sc on sc.id = p.school_id
  where p.leaderboard_opt_in and p.nickname is not null
    and (p_school_id is null or p.school_id = p_school_id)
  order by s.xp desc, p.nickname
  limit least(greatest(p_limit, 1), 100)
$$;

-- ───────────────────────── class analytics (staff only) ─────────────────────────
-- v1 scope = school. Lecturers see their own school's students; admins see all.
create function public.class_question_stats(p_act_code text default null)
returns table (question_id uuid, act_code text, section text, attempts bigint, correct bigint, pct_correct numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_staff() then raise exception 'staff only'; end if;
  return query
    select q.id, q.act_code, q.section, count(a.id), count(a.id) filter (where a.is_correct),
           round(100.0 * count(a.id) filter (where a.is_correct) / nullif(count(a.id) filter (where a.is_correct is not null), 0), 1)
    from public.questions q
    join public.attempts a on a.question_id = q.id
    where (p_act_code is null or q.act_code = upper(p_act_code)) and private.same_school(a.user_id)
    group by q.id, q.act_code, q.section
    order by 6 nulls last;
end $$;
