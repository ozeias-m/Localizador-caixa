create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.localizador_lots (
  id text primary key,
  file_name text not null,
  boxes jsonb not null check (jsonb_typeof(boxes) = 'array'),
  pieces integer not null check (pieces >= 0),
  filter_version text not null,
  box_identity_version integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '4 months')
);

create table if not exists public.localizador_scans (
  lot_id text not null references public.localizador_lots(id) on delete cascade,
  barcode text not null,
  box_id text not null,
  scanned_at timestamptz not null default now(),
  primary key (lot_id, barcode)
);

create index if not exists localizador_scans_lot_box_idx
  on public.localizador_scans (lot_id, box_id);

create table if not exists public.localizador_backups (
  id uuid primary key default gen_random_uuid(),
  source_id text unique,
  file_name text not null,
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '4 months')
);

alter table public.localizador_lots enable row level security;
alter table public.localizador_scans enable row level security;
alter table public.localizador_backups enable row level security;

drop policy if exists "Authenticated users can read lots" on public.localizador_lots;
create policy "Authenticated users can read lots"
  on public.localizador_lots for select to authenticated
  using (auth.uid() is not null);

drop policy if exists "Authenticated users can add lots" on public.localizador_lots;
create policy "Authenticated users can add lots"
  on public.localizador_lots for insert to authenticated
  with check (auth.uid() is not null);

drop policy if exists "Authenticated users can read scans" on public.localizador_scans;
create policy "Authenticated users can read scans"
  on public.localizador_scans for select to authenticated
  using (auth.uid() is not null);

drop policy if exists "Authenticated users can read backups" on public.localizador_backups;
create policy "Authenticated users can read backups"
  on public.localizador_backups for select to authenticated
  using (auth.uid() is not null);

grant select, insert on public.localizador_lots to authenticated;
grant select on public.localizador_scans to authenticated;
grant select on public.localizador_backups to authenticated;

create or replace function public.record_localizador_scan(p_lot_id text, p_barcode text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_boxes jsonb;
  v_box_id text;
  v_box_number integer;
  v_quantity integer;
  v_inserted integer;
  v_scanned integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select boxes
    into v_boxes
    from public.localizador_lots
    where id = p_lot_id and expires_at > now()
    for update;

  if v_boxes is null then
    raise exception 'Lot not found or expired';
  end if;

  select
    box.value ->> 'id',
    (box.value ->> 'number')::integer,
    (box.value ->> 'quantity')::integer
    into v_box_id, v_box_number, v_quantity
    from jsonb_array_elements(v_boxes) as box(value)
    where exists (
      select 1
        from jsonb_array_elements(coalesce(box.value -> 'pieces', '[]'::jsonb)) as piece(value)
        where piece.value ->> 'barcode' = p_barcode
    )
    limit 1;

  if v_box_id is null then
    return jsonb_build_object('status', 'not_found');
  end if;

  insert into public.localizador_scans (lot_id, barcode, box_id)
    values (p_lot_id, p_barcode, v_box_id)
    on conflict (lot_id, barcode) do nothing;
  get diagnostics v_inserted = row_count;

  select count(*)
    into v_scanned
    from public.localizador_scans
    where lot_id = p_lot_id and box_id = v_box_id;

  update public.localizador_lots
    set updated_at = now()
    where id = p_lot_id;

  return jsonb_build_object(
    'status', case when v_inserted = 1 then 'scanned' else 'duplicate' end,
    'box_id', v_box_id,
    'box_number', v_box_number,
    'quantity', v_quantity,
    'scanned_count', v_scanned
  );
end;
$$;

create or replace function public.reset_localizador_lot(p_lot_id text, p_snapshot jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_backup_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  perform 1
    from public.localizador_lots
    where id = p_lot_id and expires_at > now()
    for update;

  if not found then
    raise exception 'Lot not found or expired';
  end if;

  insert into public.localizador_backups (file_name, snapshot)
    values (coalesce(p_snapshot ->> 'fileName', 'Lote'), p_snapshot)
    returning id into v_backup_id;

  delete from public.localizador_scans where lot_id = p_lot_id;
  update public.localizador_lots set updated_at = now() where id = p_lot_id;
  return v_backup_id;
end;
$$;

create or replace function public.restore_localizador_backup(p_backup_id uuid, p_new_lot_id text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_snapshot jsonb;
  v_file_name text;
  v_created_at timestamptz;
  v_boxes jsonb;
  v_codes jsonb;
  v_pieces integer;
  v_filter_version text;
  v_identity_version integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select snapshot, file_name, created_at
    into v_snapshot, v_file_name, v_created_at
    from public.localizador_backups
    where id = p_backup_id and expires_at > now()
    for update;

  if v_snapshot is null then
    raise exception 'Backup not found or expired';
  end if;

  v_boxes := coalesce(v_snapshot -> 'boxes', '[]'::jsonb);
  v_codes := coalesce(v_snapshot -> 'scannedCodes', '[]'::jsonb);
  v_pieces := coalesce((v_snapshot ->> 'pieces')::integer, 0);
  v_filter_version := coalesce(v_snapshot ->> 'filterVersion', '');
  v_identity_version := coalesce((v_snapshot ->> 'boxIdentityVersion')::integer, 0);

  insert into public.localizador_lots (
    id, file_name, boxes, pieces, filter_version, box_identity_version
  ) values (
    p_new_lot_id, v_file_name, v_boxes, v_pieces, v_filter_version, v_identity_version
  );

  insert into public.localizador_scans (lot_id, barcode, box_id)
  select p_new_lot_id, piece.value ->> 'barcode', box.value ->> 'id'
    from jsonb_array_elements(v_boxes) as box(value)
    cross join jsonb_array_elements(coalesce(box.value -> 'pieces', '[]'::jsonb)) as piece(value)
    where piece.value ->> 'barcode' in (
      select jsonb_array_elements_text(v_codes)
    )
    on conflict (lot_id, barcode) do nothing;

  return p_new_lot_id;
end;
$$;

create or replace function public.import_localizador_lot(p_lot jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_lot_id text;
  v_codes jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  v_lot_id := p_lot ->> 'id';
  if nullif(v_lot_id, '') is null then
    raise exception 'Lot ID is required';
  end if;

  insert into public.localizador_lots (
    id, file_name, boxes, pieces, filter_version, box_identity_version
  ) values (
    v_lot_id,
    coalesce(p_lot ->> 'fileName', 'Lote importado'),
    coalesce(p_lot -> 'boxes', '[]'::jsonb),
    coalesce((p_lot ->> 'pieces')::integer, 0),
    coalesce(p_lot ->> 'filterVersion', ''),
    coalesce((p_lot ->> 'boxIdentityVersion')::integer, 0)
  )
  on conflict (id) do nothing;

  if not found then
    return;
  end if;

  v_codes := coalesce(p_lot -> 'scannedCodes', '[]'::jsonb);
  insert into public.localizador_scans (lot_id, barcode, box_id)
  select distinct on (piece.value ->> 'barcode')
    v_lot_id, piece.value ->> 'barcode', box.value ->> 'id'
    from jsonb_array_elements(coalesce(p_lot -> 'boxes', '[]'::jsonb)) as box(value)
    cross join jsonb_array_elements(coalesce(box.value -> 'pieces', '[]'::jsonb)) as piece(value)
    where piece.value ->> 'barcode' in (
      select jsonb_array_elements_text(v_codes)
    )
    order by piece.value ->> 'barcode';
end;
$$;

create or replace function public.import_localizador_backup(p_snapshot jsonb, p_source_id text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_backup_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  insert into public.localizador_backups (source_id, file_name, snapshot)
    values (
      p_source_id,
      coalesce(p_snapshot ->> 'fileName', 'Backup importado'),
      p_snapshot
    )
    on conflict (source_id) do nothing
    returning id into v_backup_id;

  return v_backup_id;
end;
$$;

create or replace function public.delete_localizador_lot(p_lot_id text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  delete from public.localizador_lots where id = p_lot_id;
  get diagnostics v_deleted = row_count;

  if v_deleted = 0 then
    raise exception 'Lot not found or already deleted';
  end if;

  return true;
end;
$$;

create or replace function public.delete_localizador_backup(p_backup_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  delete from public.localizador_backups where id = p_backup_id;
  get diagnostics v_deleted = row_count;

  if v_deleted = 0 then
    raise exception 'Backup not found or already deleted';
  end if;

  return true;
end;
$$;

create or replace function public.cleanup_expired_localizador_data()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.localizador_backups where expires_at <= now();
  delete from public.localizador_lots where expires_at <= now();
end;
$$;

revoke all on function public.record_localizador_scan(text, text) from public;
revoke all on function public.reset_localizador_lot(text, jsonb) from public;
revoke all on function public.restore_localizador_backup(uuid, text) from public;
revoke all on function public.import_localizador_lot(jsonb) from public;
revoke all on function public.import_localizador_backup(jsonb, text) from public;
revoke all on function public.delete_localizador_lot(text) from public;
revoke all on function public.delete_localizador_backup(uuid) from public;
revoke all on function public.cleanup_expired_localizador_data() from public, anon, authenticated;

grant execute on function public.record_localizador_scan(text, text) to authenticated;
grant execute on function public.reset_localizador_lot(text, jsonb) to authenticated;
grant execute on function public.restore_localizador_backup(uuid, text) to authenticated;
grant execute on function public.import_localizador_lot(jsonb) to authenticated;
grant execute on function public.import_localizador_backup(jsonb, text) to authenticated;
grant execute on function public.delete_localizador_lot(text) to authenticated;
grant execute on function public.delete_localizador_backup(uuid) to authenticated;

do $$
declare
  v_job_id bigint;
begin
  for v_job_id in
    select jobid
      from cron.job
      where jobname = 'cleanup-expired-localizador-data'
  loop
    perform cron.unschedule(v_job_id);
  end loop;

  perform cron.schedule(
    'cleanup-expired-localizador-data',
    '15 3 * * *',
    'select public.cleanup_expired_localizador_data();'
  );
end;
$$;
