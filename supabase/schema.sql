-- =====================================================================
-- Nicole Guillemette — Espacio de Yoga
-- Esquema de base de datos para reservas de turnos
--
-- CÓMO USARLO:
-- 1. Entrá a tu proyecto en supabase.com
-- 2. Andá a "SQL Editor" (menú izquierdo)
-- 3. Pegá TODO este archivo y click en "Run"
-- 4. Después de crear tu primer usuario admin (Nicole) desde la app,
--    volvé a este editor y corré (reemplazando el email):
--
--    update public.profiles set role = 'admin'
--    where email = 'nicole@email.com';
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Perfiles (uno por usuario de auth.users)
-- ---------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  phone text,
  role text not null default 'student' check (role in ('student','admin')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

create policy "profiles_select_own_or_admin"
  on public.profiles for select
  using (id = auth.uid() or public.is_admin());

create policy "profiles_update_own_or_admin"
  on public.profiles for update
  using (id = auth.uid() or public.is_admin());

-- crea el perfil automáticamente cuando alguien se registra
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, phone)
  values (new.id, new.email, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Clases (plantilla semanal: día + horario fijo)
-- ---------------------------------------------------------------------
create table public.classes (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Hatha Yoga Terapéutico',
  day_of_week int not null check (day_of_week between 0 and 6), -- 0=domingo .. 6=sábado
  start_time time not null,
  teacher_name text,
  capacity int not null default 10,
  active boolean not null default true
);

alter table public.classes enable row level security;

create policy "classes_select_authenticated"
  on public.classes for select
  to authenticated
  using (true);

create policy "classes_admin_write"
  on public.classes for all
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- Sesiones (ocurrencia concreta de una clase en una fecha, reservable)
-- ---------------------------------------------------------------------
create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  session_date date not null,
  unique (class_id, session_date)
);

alter table public.sessions enable row level security;

create policy "sessions_select_authenticated"
  on public.sessions for select
  to authenticated
  using (true);

create policy "sessions_admin_write"
  on public.sessions for all
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- Packs (plan y créditos de cada alumna)
-- ---------------------------------------------------------------------
create table public.packs (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  plan_type text not null check (plan_type in ('pack6','libre')),
  credits_remaining int,
  price_paid numeric,
  purchased_at date not null default current_date,
  valid_until date not null,
  notes text
);

alter table public.packs enable row level security;

create policy "packs_select_own_or_admin"
  on public.packs for select
  using (student_id = auth.uid() or public.is_admin());

create policy "packs_admin_write"
  on public.packs for all
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- Reservas
-- ---------------------------------------------------------------------
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  pack_id uuid references public.packs(id),
  status text not null default 'reservado' check (status in ('reservado','cancelado','asistio','ausente')),
  created_at timestamptz not null default now(),
  unique (session_id, student_id)
);

alter table public.bookings enable row level security;

create policy "bookings_select_own_or_admin"
  on public.bookings for select
  using (student_id = auth.uid() or public.is_admin());

create policy "bookings_admin_write"
  on public.bookings for all
  using (public.is_admin())
  with check (public.is_admin());

create policy "bookings_cancel_own"
  on public.bookings for update
  using (student_id = auth.uid())
  with check (student_id = auth.uid());

-- ---------------------------------------------------------------------
-- Disponibilidad de horarios (sin exponer identidad de otras alumnas)
-- ---------------------------------------------------------------------
create or replace function public.get_upcoming_sessions(p_days int default 14)
returns table (
  session_id uuid,
  session_date date,
  start_time time,
  class_name text,
  teacher_name text,
  capacity int,
  booked_count bigint
)
language sql
security definer
set search_path = public
as $$
  select s.id, s.session_date, c.start_time, c.name, c.teacher_name, c.capacity,
    count(b.id) filter (where b.status = 'reservado') as booked_count
  from sessions s
  join classes c on c.id = s.class_id
  left join bookings b on b.session_id = s.id
  where s.session_date between current_date and current_date + p_days
  group by s.id, s.session_date, c.start_time, c.name, c.teacher_name, c.capacity
  order by s.session_date, c.start_time;
$$;

grant execute on function public.get_upcoming_sessions(int) to authenticated;

-- ---------------------------------------------------------------------
-- Reservar clase (chequea cupo y créditos de forma atómica)
-- ---------------------------------------------------------------------
create or replace function public.book_session(p_session_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_capacity int;
  v_booked_count int;
  v_pack record;
  v_booking public.bookings;
begin
  select c.capacity into v_capacity
  from sessions s join classes c on c.id = s.class_id
  where s.id = p_session_id;

  if v_capacity is null then
    raise exception 'Clase no encontrada';
  end if;

  select count(*) into v_booked_count
  from bookings
  where session_id = p_session_id and status = 'reservado';

  if v_booked_count >= v_capacity then
    raise exception 'Clase completa';
  end if;

  select * into v_pack
  from packs
  where student_id = auth.uid()
    and valid_until >= current_date
    and (plan_type = 'libre' or credits_remaining > 0)
  order by purchased_at desc
  limit 1;

  if not found then
    raise exception 'No tenés un pack activo con clases disponibles';
  end if;

  insert into bookings (session_id, student_id, pack_id)
  values (p_session_id, auth.uid(), v_pack.id)
  returning * into v_booking;

  if v_pack.plan_type = 'pack6' then
    update packs set credits_remaining = credits_remaining - 1
    where id = v_pack.id;
  end if;

  return v_booking;
end;
$$;

grant execute on function public.book_session(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Cancelar reserva (devuelve el crédito si era pack6)
-- ---------------------------------------------------------------------
create or replace function public.cancel_booking(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking record;
begin
  select * into v_booking from bookings
  where id = p_booking_id and student_id = auth.uid() and status = 'reservado';

  if not found then
    raise exception 'Reserva no encontrada';
  end if;

  update bookings set status = 'cancelado' where id = p_booking_id;

  if v_booking.pack_id is not null then
    update packs set credits_remaining = credits_remaining + 1
    where id = v_booking.pack_id and plan_type = 'pack6';
  end if;
end;
$$;

grant execute on function public.cancel_booking(uuid) to authenticated;
